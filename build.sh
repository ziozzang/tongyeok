#!/bin/zsh
# Builds build/Tongyeok.app with plain swiftc (no Xcode project needed). macOS 26+, Apple Silicon.
#   ./build.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Tongyeok.app"
OPT=(-O); [[ "${1:-release}" == "debug" ]] && OPT=(-Onone -g)
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc "${OPT[@]}" -swift-version 5 -target arm64-apple-macosx26.0 -parse-as-library \
  -o "$APP/Contents/MacOS/Tongyeok" Sources/App/*.swift Sources/Shared/*.swift
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Fixed certificate -> stable designated requirement (bundle id + cert), so macOS keeps microphone /
# screen-recording / Keychain permissions across updates. Without it: ad-hoc (cdhash changes every build).
SIGN_ID="${TONGYEOK_SIGN_ID:-Tongyeok Signing}"
if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$SIGN_ID\""; then
  codesign --force --sign "$SIGN_ID" --timestamp=none --entitlements Resources/Tongyeok.entitlements "$APP"
else
  echo "⚠ code-signing identity '$SIGN_ID' not found — ad-hoc signing (permissions reset on every update)" >&2
  codesign --force --sign - --entitlements Resources/Tongyeok.entitlements "$APP"
fi
codesign -d -r- "$APP" 2>&1 | sed -n 's/^#* *designated => /  requirement: /p'
echo "Built $APP (v$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist))"
