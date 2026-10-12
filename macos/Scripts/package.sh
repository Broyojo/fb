#!/bin/bash
set -euo pipefail

mac_dir="$(cd "$(dirname "$0")/.." && pwd)"
identity="${DEVELOPER_ID_IDENTITY:-}"
if [[ -z "$identity" || "$identity" != 'Developer ID Application:'* ]]; then
  echo 'Set DEVELOPER_ID_IDENTITY to the full name of an installed Developer ID Application identity.' >&2
  echo 'Apple Development and ad-hoc signatures are for local builds only.' >&2
  exit 1
fi
if ! /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -F -- "\"$identity\"" >/dev/null; then
  echo "Developer ID identity and private key are not available: $identity" >&2
  exit 1
fi

CONFIGURATION=Release FB_SIGN_IDENTITY="$identity" "$mac_dir/Scripts/build.sh" "$@"
source_app="$mac_dir/.build/xcode/Build/Products/Release/fb.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$source_app/Contents/Info.plist")"
package_dir="$mac_dir/.build/distribution/fb-$version-arm64"
app_path="$package_dir/fb.app"
mkdir -p "$package_dir"
if [[ -e "$app_path" ]]; then
  echo "Package output already exists: $app_path; move or remove it before packaging." >&2
  exit 1
fi
/usr/bin/ditto "$source_app" "$app_path"

# Timestamp both nested executable and outer app for a distributable signature.
/usr/bin/codesign --force --sign "$identity" --options runtime --timestamp \
  "$app_path/Contents/Helpers/pandoc"
/usr/bin/codesign --force --sign "$identity" --options runtime --timestamp "$app_path"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"

zip_path="$package_dir/fb-$version-arm64-signed.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  # This is the only submission step, explicitly enabled by a supplied profile.
  xcrun notarytool submit "$zip_path" --keychain-profile "$NOTARY_PROFILE" \
    --wait --output-format json > "$package_dir/notarization.json"
  status="$(/usr/bin/plutil -extract status raw -o - "$package_dir/notarization.json")"
  if [[ "$status" != Accepted ]]; then
    echo "Notarization did not succeed; see $package_dir/notarization.json" >&2
    exit 1
  fi
  xcrun stapler staple "$app_path"
  xcrun stapler validate "$app_path"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$app_path"
  zip_path="$package_dir/fb-$version-arm64-notarized.zip"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"
else
  echo 'Signed package created without notarization. Supply NOTARY_PROFILE to notarize and staple.' >&2
fi

/bin/cp "$mac_dir/Dependencies/pandoc.json" "$package_dir/pandoc.json"
/bin/cp "$mac_dir/Dependencies/Pandoc-COPYING.md" "$package_dir/Pandoc-COPYING.md"
/bin/cp "$mac_dir/Dependencies/NOTICE.md" "$package_dir/NOTICE.md"
/usr/bin/shasum -a 256 "$zip_path" > "$zip_path.sha256"
echo "Package: $zip_path"
