#!/bin/bash
# Redeploy means build the latest source and install it to ~/Applications.
set -euo pipefail

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  cat <<'USAGE'
Usage: macos/Scripts/deploy.sh [XCODEBUILD_ARGUMENTS...]
       macos/Scripts/deploy.sh --notarized-app PATH/TO/fb.app

Incrementally build Release, stage and verify the app, then replace
~/Applications/fb.app. Only a running copy at that installed path is asked to
quit; it reopens afterward. Other running Debug or development copies are left
alone. A failed replacement restores the prior installed app.

Signing follows build.sh (Apple Development by default, or FB_SIGN_IDENTITY).
This performs a local install, without cloud signing, notarization, or upload.

--notarized-app installs an already built release without rebuilding or changing
its signature. It must match the clean checkout's current Git revision and pass
Developer ID, stapled-ticket, and Gatekeeper verification.
USAGE
  exit 0
fi

mac_dir="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" == --notarized-app ]]; then
  if [[ "$#" != 2 ]]; then
    echo 'Supply one notarized fb.app path.' >&2
    exit 1
  fi
  app_path="$2"
  repo_dir="$(cd "$mac_dir/.." && pwd)"
  if [[ -n "$(git -C "$repo_dir" status --porcelain)" ]]; then
    echo 'Commit source changes before installing a prebuilt release.' >&2
    exit 1
  fi
  revision="$(/usr/libexec/PlistBuddy -c 'Print :FBBuildRevision' "$app_path/Contents/Info.plist")"
  if [[ "$revision" != "$(git -C "$repo_dir" rev-parse --short HEAD)" ]]; then
    echo 'The prebuilt release does not match the current source revision.' >&2
    exit 1
  fi
  "$mac_dir/Scripts/notarize-existing.sh" --check-only "$app_path"
  xcrun stapler validate "$app_path"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$app_path"
else
  CONFIGURATION=Release "$mac_dir/Scripts/build.sh" "$@"
  app_path="$mac_dir/.build/xcode/Build/Products/Release/fb.app"
fi
exec xcrun swift "$mac_dir/Scripts/deploy-app.swift" "$app_path" "$HOME/Applications/fb.app"
