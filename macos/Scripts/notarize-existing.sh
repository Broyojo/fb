#!/bin/bash
# Notarize an already Developer ID-signed app without a local signing key.
# Input is preserved; only a staged copy is submitted and stapled.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: macos/Scripts/notarize-existing.sh [--check-only] SIGNED.app|SIGNED.zip [OUTPUT_DIRECTORY]

Verify the app and bundled Pandoc have this team's Developer ID signatures,
hardened runtime, and secure timestamps. Submit a staged ZIP, save the result
and Apple developer log, staple/validate the app, check Gatekeeper, then create
fb-<version>-arm64-notarized.zip and its SHA-256 file. The input is unchanged.

Authentication (choose one):
  NOTARY_PROFILE                 An already stored notarytool Keychain profile
  ASC_RELEASE_KEY_PATH           An existing team API key file, mode 600
    ASC_RELEASE_KEY_ID           Defaults to 6B7NTN43DS
    ASC_RELEASE_ISSUER_ID        Defaults to the existing ios_app issuer

FB_DEVELOPMENT_TEAM defaults to 3288VRMQE7. NOTARY_TIMEOUT defaults to 30m.
--check-only performs local signature/architecture checks without auth or any
submission. Outputs normally go under macos/.build/distribution/notary-<time>.

The script does not sign code, create certificates, store credentials, build,
install, create a release/tag, or publish an app. A normal invocation uploads
the already signed app to Apple's notarization service.
USAGE
}

check_only=false
if [[ "${1:-}" == --check-only ]]; then
  check_only=true
  shift
fi
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  usage
  exit 0
fi
if [[ "$#" -lt 1 || "$#" -gt 2 ]]; then
  usage >&2
  exit 1
fi

mac_dir="$(cd "$(dirname "$0")/.." && pwd)"
source_path="$1"
output_dir="${2:-$mac_dir/.build/distribution/notary-$(date +%Y%m%d-%H%M%S)}"
team_id="${FB_DEVELOPMENT_TEAM:-3288VRMQE7}"
if [[ ! "$team_id" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "Invalid developer team ID: $team_id" >&2
  exit 1
fi
if [[ ! -d "$source_path" && ! -f "$source_path" ]]; then
  echo "Signed app or ZIP does not exist: $source_path" >&2
  exit 1
fi
if [[ -e "$output_dir" ]]; then
  echo "Output already exists; choose a fresh directory: $output_dir" >&2
  exit 1
fi

mkdir -p "$mac_dir/.build/distribution"
inspection_dir="$(mktemp -d "$mac_dir/.build/distribution/.notary-preflight.XXXXXX")"
trap 'rm -rf "$inspection_dir"' EXIT
app_path="$inspection_dir/fb.app"
if [[ -d "$source_path" && "$source_path" == *.app ]]; then
  /usr/bin/ditto "$source_path" "$app_path"
elif [[ -f "$source_path" && "$source_path" == *.zip ]]; then
  /usr/bin/unzip -Z1 "$source_path" > "$inspection_dir/entries.txt"
  while IFS= read -r entry; do
    case "$entry" in
      /*|../*|*/../*|*/..|*\\*) echo "Unsafe ZIP entry: $entry" >&2; exit 1 ;;
      fb.app/|fb.app/*|__MACOSX/|__MACOSX/*) ;;
      *) echo "Unexpected ZIP payload (expected fb.app): $entry" >&2; exit 1 ;;
    esac
  done < "$inspection_dir/entries.txt"
  /usr/bin/ditto -x -k "$source_path" "$inspection_dir"
else
  echo 'Supply an existing .app bundle or .zip containing fb.app.' >&2
  exit 1
fi

plist="$app_path/Contents/Info.plist"
if [[ ! -f "$plist" || -L "$app_path" ]]; then
  echo 'Input did not contain the expected fb.app bundle.' >&2
  exit 1
fi
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
if [[ "$bundle_id" != com.xoba.fb.app || ! "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo 'Input must be com.xoba.fb.app with a numeric release version.' >&2
  exit 1
fi
/usr/bin/codesign --verify --deep --strict "$app_path"
requirement="anchor apple generic and certificate leaf[subject.OU] = \"$team_id\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
for code_path in "$app_path" "$app_path/Contents/Helpers/pandoc"; do
  if ! /usr/bin/codesign --verify --strict -R "=$requirement" "$code_path"; then
    echo "Expected this team's Developer ID signature: $code_path" >&2
    echo 'Development or ad-hoc signatures cannot be submitted through this release workflow.' >&2
    exit 1
  fi
  details="$(/usr/bin/codesign -d --verbose=4 "$code_path" 2>&1)"
  if [[ "$details" != *'(runtime)'* || "$details" != *'Timestamp='* ]]; then
    echo "Code lacks hardened runtime or secure timestamp: $code_path" >&2
    exit 1
  fi
done
for executable in "$app_path/Contents/MacOS/fb" "$app_path/Contents/Helpers/pandoc"; do
  if [[ "$(/usr/bin/lipo -archs "$executable")" != arm64 ]]; then
    echo "Expected an arm64-only executable: $executable" >&2
    exit 1
  fi
done
echo "Verified Developer ID signatures and arm64 executables for fb $version."
if "$check_only"; then
  echo 'Check-only complete; no submission or output package was created.'
  exit 0
fi

auth_args=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  if [[ -n "${ASC_RELEASE_KEY_PATH:-}" ]]; then
    echo 'Choose one authentication method: NOTARY_PROFILE or ASC_RELEASE_KEY_PATH.' >&2
    exit 1
  fi
  auth_args=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${ASC_RELEASE_KEY_PATH:-}" ]]; then
  key_path="$ASC_RELEASE_KEY_PATH"
  if [[ ! -f "$key_path" || ! -r "$key_path" ]]; then
    echo 'ASC_RELEASE_KEY_PATH must name an existing, readable team API key.' >&2
    exit 1
  fi
  key_path="$(cd "$(dirname "$key_path")" && pwd -P)/$(basename "$key_path")"
  if [[ "$(/usr/bin/stat -L -f '%Lp' "$key_path")" != 600 ]]; then
    echo 'The API key file must have mode 600.' >&2
    exit 1
  fi
  auth_args=(
    --key "$key_path"
    --key-id "${ASC_RELEASE_KEY_ID:-6B7NTN43DS}"
    --issuer "${ASC_RELEASE_ISSUER_ID:-69a6de77-b8d5-47e3-e053-5b8c7c11a4d1}"
  )
else
  echo 'Set an existing NOTARY_PROFILE or ASC_RELEASE_KEY_PATH for notarization.' >&2
  exit 1
fi

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
/bin/mv "$app_path" "$output_dir/fb.app"
app_path="$output_dir/fb.app"
signed_zip="$output_dir/fb-$version-arm64-signed.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$signed_zip"
echo "Submitting fb $version to Apple's notarization service…"
submission_exit=0
xcrun notarytool submit "$signed_zip" "${auth_args[@]}" --wait \
  --timeout "${NOTARY_TIMEOUT:-30m}" --output-format json \
  > "$output_dir/notarization.json" 2> "$output_dir/notarization-stderr.log" || submission_exit=$?
submission_id="$(/usr/bin/plutil -extract id raw -o - "$output_dir/notarization.json" 2>/dev/null || true)"
status="$(/usr/bin/plutil -extract status raw -o - "$output_dir/notarization.json" 2>/dev/null || true)"

if [[ "$submission_id" =~ ^[A-Fa-f0-9-]{36}$ ]]; then
  echo "Notarization submission: $submission_id (${status:-status unavailable})"
  # Retrieve Apple's detailed report for completed accepted or rejected jobs.
  if [[ "$status" == Accepted || "$status" == Invalid || "$status" == Rejected ]]; then
    if ! xcrun notarytool log "$submission_id" "$output_dir/notarization-log.json" \
      "${auth_args[@]}" > "$output_dir/notarization-log-stdout.log" \
      2> "$output_dir/notarization-log-stderr.log"; then
      echo "Could not retrieve the developer log; see $output_dir/notarization-log-stderr.log" >&2
    fi
  fi
fi
if [[ "$submission_exit" != 0 || "$status" != Accepted ]]; then
  /bin/cat "$output_dir/notarization-stderr.log" >&2
  echo "Notarization did not finish as Accepted; see $output_dir/notarization.json and notarization-log.json when available." >&2
  echo 'The signed package and submission details were preserved; no notarized ZIP was produced.' >&2
  exit 1
fi

xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
/usr/bin/codesign --verify --deep --strict "$app_path"
/usr/sbin/spctl --assess --type execute --verbose=2 "$app_path"
notarized_filename="fb-$version-arm64-notarized.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$output_dir/$notarized_filename"
(cd "$output_dir" && /usr/bin/shasum -a 256 "$notarized_filename" > "$notarized_filename.sha256")
if [[ -d "$app_path/Contents/Resources/Dependencies" ]]; then
  /usr/bin/ditto "$app_path/Contents/Resources/Dependencies" "$output_dir/Dependencies"
fi
echo "Notarized app: $app_path"
echo "Notarized ZIP: $output_dir/$notarized_filename"
echo "Checksum: $output_dir/$notarized_filename.sha256"
