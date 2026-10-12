#!/bin/bash
# Export an existing archive using Apple's cloud-managed Developer ID signing.
# Invoking this script contacts Apple and can create managed signing assets.
# It does not upload to App Store Connect, notarize, or publish the app.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  macos/Scripts/export-cloud.sh --xcode-account ARCHIVE.xcarchive [OUTPUT_DIRECTORY]
  macos/Scripts/export-cloud.sh [--api-key] ARCHIVE.xcarchive [OUTPUT_DIRECTORY]

--xcode-account uses an account already signed in under Xcode > Settings >
Accounts. Sign in with the Account Holder or an account granted cloud Developer
ID access. No API key is required or passed in this mode.

--api-key (the default) requires ASC_RELEASE_KEY_PATH: an existing team API key
file with mode 600. Optional: ASC_RELEASE_KEY_ID and ASC_RELEASE_ISSUER_ID.
Both modes accept FB_DEVELOPMENT_TEAM; it defaults to 3288VRMQE7.

Defaults match the existing ios_app release account. The key is never copied
or printed. Export uses Apple's cloud Developer ID signing and may create
managed certificates/profiles. No App Store upload, notarization, publication,
certificate revocation, or user/role changes are performed by this script.
The API key must have cloud Developer ID signing permission; successful iOS
distribution signing alone does not establish that permission.
USAGE
}
auth_mode=api-key
case "${1:-}" in
  --xcode-account) auth_mode=xcode-account; shift ;;
  --api-key) shift ;;
esac
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  usage
  exit 0
fi
if [[ "$#" -lt 1 || "$#" -gt 2 ]]; then
  usage >&2
  exit 1
fi

mac_dir="$(cd "$(dirname "$0")/.." && pwd)"
archive_path="$1"
if [[ ! -d "$archive_path" || ! -f "$archive_path/Info.plist" ]]; then
  echo "Not an Xcode archive: $archive_path" >&2
  exit 1
fi
archive_path="$(cd "$archive_path" && pwd)"
output_dir="${2:-$mac_dir/.build/cloud-export/$(date +%Y%m%d-%H%M%S)}"
team_id="${FB_DEVELOPMENT_TEAM:-3288VRMQE7}"
auth_args=(-allowProvisioningUpdates)
if [[ "$auth_mode" == api-key ]]; then
  key_path="${ASC_RELEASE_KEY_PATH:-}"
  key_id="${ASC_RELEASE_KEY_ID:-6B7NTN43DS}"
  issuer_id="${ASC_RELEASE_ISSUER_ID:-69a6de77-b8d5-47e3-e053-5b8c7c11a4d1}"
  if [[ -z "$key_path" || ! -f "$key_path" || ! -r "$key_path" ]]; then
    echo 'Set ASC_RELEASE_KEY_PATH to an existing, readable team API key file, or select --xcode-account.' >&2
    exit 1
  fi
  key_path="$(cd "$(dirname "$key_path")" && pwd -P)/$(basename "$key_path")"
  if [[ "$(/usr/bin/stat -L -f '%Lp' "$key_path")" != 600 ]]; then
    echo 'The API key file must have mode 600.' >&2
    exit 1
  fi
  auth_args+=(
    -authenticationKeyPath "$key_path"
    -authenticationKeyID "$key_id"
    -authenticationKeyIssuerID "$issuer_id"
  )
fi
if [[ ! "$team_id" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "Invalid developer team ID: $team_id" >&2
  exit 1
fi
if [[ -e "$output_dir" ]]; then
  echo "Output already exists; choose a fresh directory: $output_dir" >&2
  exit 1
fi
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
options_path="$output_dir/ExportOptions.plist"
cat > "$options_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$team_id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST

echo 'Requesting cloud Developer ID signing; Xcode may create managed signing assets.' >&2
echo "Authentication mode: $auth_mode" >&2
if ! xcodebuild -exportArchive -archivePath "$archive_path" \
  -exportOptionsPlist "$options_path" -exportPath "$output_dir/export" \
  "${auth_args[@]}" \
  > "$output_dir/export.log" 2>&1; then
  /bin/cat "$output_dir/export.log" >&2
  echo 'Cloud Developer ID export failed. No distribution package was produced.' >&2
  if [[ "$auth_mode" == xcode-account ]]; then
    echo 'For "No Accounts" or authentication errors, sign into Xcode > Settings > Accounts with the Account Holder and retry.' >&2
    echo 'For a cloud-signing permission error, the selected account needs cloud Developer ID access for this team.' >&2
  else
    echo 'If Apple reports cloud-signing permission denied, this API key lacks the required Developer ID access.' >&2
    echo 'An authorized account signed into Xcode can instead be selected with --xcode-account.' >&2
  fi
  echo 'Do not replace/revoke credentials as a guessed fix; use an authorized cloud-signing account or an existing local Developer ID identity.' >&2
  exit 1
fi
/bin/cat "$output_dir/export.log"

app_path="$output_dir/export/fb.app"
if [[ ! -d "$app_path" ]]; then
  echo "Export did not produce the expected app: $app_path" >&2
  exit 1
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"

# Check nested Pandoc too: a successful export alone does not establish that
# Xcode replaced every development signature in custom copied executables.
requirement="anchor apple generic and certificate leaf[subject.OU] = \"$team_id\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
for code_path in "$app_path" "$app_path/Contents/Helpers/pandoc"; do
  if ! /usr/bin/codesign --verify --strict -R "=$requirement" "$code_path"; then
    echo "Exported code does not have this team's Developer ID signature: $code_path" >&2
    exit 1
  fi
  details="$(/usr/bin/codesign -d --verbose=4 "$code_path" 2>&1)"
  if [[ "$details" != *'(runtime)'* || "$details" != *'Timestamp='* ]]; then
    echo "Exported code lacks hardened runtime or secure timestamp: $code_path" >&2
    exit 1
  fi
done

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
zip_path="$output_dir/fb-$version-arm64-signed.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"
/usr/bin/shasum -a 256 "$zip_path" > "$zip_path.sha256"
echo "Developer ID signed app: $app_path"
echo "Signed ZIP (not yet notarized): $zip_path"
