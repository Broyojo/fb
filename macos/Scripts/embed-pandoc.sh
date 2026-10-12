#!/bin/bash
set -euo pipefail

mac_dir="$(cd "$(dirname "$0")/.." && pwd)"
manifest="$mac_dir/Dependencies/pandoc.json"
relative_binary="$(/usr/bin/plutil -extract executable raw -o - "$manifest")"
source_binary="$mac_dir/.build/dependencies/$relative_binary"
if [[ ! -x "$source_binary" ]]; then
  echo "Pinned Pandoc has not been prepared. Run macos/Scripts/build.sh first." >&2
  exit 1
fi

: "${TARGET_BUILD_DIR:?This script runs as an Xcode build phase}"
: "${CONTENTS_FOLDER_PATH:?This script runs as an Xcode build phase}"
helpers_dir="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
mkdir -p "$helpers_dir"
/usr/bin/install -m 755 "$source_binary" "$helpers_dir/pandoc"

# Sign nested code before Xcode signs the containing app.
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]]; then
  identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
  /usr/bin/codesign --force --sign "$identity" --options runtime \
    --timestamp=none "$helpers_dir/pandoc"
fi
