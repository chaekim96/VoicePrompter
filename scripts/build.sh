#!/bin/bash
# Builds build/VoicePrompter.app. Set SIGN_ID to a codesigning identity to keep
# macOS privacy permissions across rebuilds. Ad-hoc signing ("-") re-prompts after each rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/VoicePrompter"
APP=build/VoicePrompter.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VoicePrompter"
cp Sources/VoicePrompter/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --options runtime --entitlements Sources/VoicePrompter/VoicePrompter.entitlements \
  --sign "${SIGN_ID:--}" "$APP"
echo "Built $APP (signed with ${SIGN_ID:-ad-hoc})"
