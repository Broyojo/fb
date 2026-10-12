#!/bin/bash
set -euo pipefail

mac_dir="$(cd "$(dirname "$0")/.." && pwd)"
deps_dir="$mac_dir/.build/dependencies"
manifest="$mac_dir/Dependencies/pandoc.json"
mkdir -p "$deps_dir"

read_manifest() {
  /usr/bin/plutil -extract "$1" raw -o - "$manifest"
}

version="$(read_manifest version)"
archive_name="$(read_manifest archive)"
archive_path="$deps_dir/$archive_name"
binary_path="$deps_dir/$(read_manifest executable)"
expected_sha="$(read_manifest sha256)"

if [[ ! -f "$archive_path" ]]; then
  echo "Downloading pinned Pandoc $version for arm64…" >&2
  temp_archive="$(mktemp "$deps_dir/pandoc-download.XXXXXX")"
  trap 'rm -f "$temp_archive"' EXIT
  /usr/bin/curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
    "$(read_manifest url)" -o "$temp_archive"
  actual_sha="$(/usr/bin/shasum -a 256 "$temp_archive" | /usr/bin/awk '{print $1}')"
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    echo "Pandoc archive checksum mismatch; downloaded artifact was not used." >&2
    exit 1
  fi
  mv "$temp_archive" "$archive_path"
  trap - EXIT
fi

actual_sha="$(/usr/bin/shasum -a 256 "$archive_path" | /usr/bin/awk '{print $1}')"
if [[ "$actual_sha" != "$expected_sha" ]]; then
  echo "Cached Pandoc archive checksum mismatch: $archive_path" >&2
  echo "Remove that archive and run this script again." >&2
  exit 1
fi

# Re-extract from the verified archive so a stale/modified executable cannot be used.
/usr/bin/unzip -oq "$archive_path" -d "$deps_dir"
if [[ ! -x "$binary_path" ]]; then
  echo "Pandoc archive did not contain the expected executable: $binary_path" >&2
  exit 1
fi
/usr/bin/codesign --verify --strict "$binary_path"
/usr/bin/lipo -verify_arch arm64 "$binary_path"

# A standalone bundle must not retain dependencies on Homebrew or other local paths.
while IFS= read -r dependency; do
  case "$dependency" in
    /usr/lib/*|/System/Library/*) ;;
    *) echo "Pandoc has an unexpected external library dependency: $dependency" >&2; exit 1 ;;
  esac
done < <(/usr/bin/otool -L "$binary_path" | /usr/bin/tail -n +2 | /usr/bin/awk '{print $1}')

actual_version="$("$binary_path" --version | /usr/bin/head -n 1)"
if [[ "$actual_version" != "pandoc $version" ]]; then
  echo "Unexpected Pandoc version: $actual_version" >&2
  exit 1
fi
echo "Verified $actual_version: $binary_path" >&2
