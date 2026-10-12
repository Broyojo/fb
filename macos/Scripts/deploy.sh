#!/bin/bash
# Redeploy means build the latest source and install it to ~/Applications.
set -euo pipefail

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  cat <<'USAGE'
Usage: macos/Scripts/deploy.sh [XCODEBUILD_ARGUMENTS...]

Incrementally build Release, stage and verify the app, then replace
~/Applications/fb.app. Only a running copy at that installed path is asked to
quit; it reopens afterward. Other running Debug or development copies are left
alone. A failed replacement restores the prior installed app.

Signing follows build.sh (Apple Development by default, or FB_SIGN_IDENTITY).
This performs a local install, without cloud signing, notarization, or upload.
USAGE
  exit 0
fi

mac_dir="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION=Release "$mac_dir/Scripts/build.sh" "$@"
app_path="$mac_dir/.build/xcode/Build/Products/Release/fb.app"
exec xcrun swift "$mac_dir/Scripts/deploy-app.swift" "$app_path" "$HOME/Applications/fb.app"
