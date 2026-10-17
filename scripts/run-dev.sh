#!/bin/sh
# Builds Weaver and runs it, signed with your Apple Development certificate so the
# Accessibility permission sticks between builds (ad-hoc signatures change every build).
set -e
cd "$(dirname "$0")/.."
IDENTITY="${WEAVER_SIGN_IDENTITY:-Apple Development: Batuhan Haymana (NTY23AH2S9)}"
xcodegen generate >/dev/null
xcodebuild -project Weaver.xcodeproj -scheme Weaver -configuration Debug -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build | grep -E "error:|BUILD" || true
APP=build/Build/Products/Debug/Weaver.app
codesign --force --deep --options runtime --sign "$IDENTITY" \
  --entitlements Weaver/Resources/Weaver.entitlements "$APP"
# Run from /Applications: the Accessibility entry is tied to the app's identity and a stable
# location keeps System Settings showing one Weaver, not one per build folder.
pkill -x Weaver 2>/dev/null || true
rm -rf /Applications/Weaver.app && cp -R "$APP" /Applications/Weaver.app
open /Applications/Weaver.app
