#!/bin/sh
# Builds a release of Weaver:
#   build/release/Weaver-<version>.dmg   signed with Developer ID, notarized and stapled
#   build/release/Weaver.dmg             the same file, for the site's Download button
#   docs/appcast.xml                     a new <item> with Sparkle's EdDSA signature
#   docs/releases/<version>.html         release notes (created once, edit before committing)
# Then commit docs/, push, and attach both DMGs to a GitHub release tagged v<version>.
#
# One-time setup, in your Keychain, not the repo:
#   xcrun notarytool store-credentials weaver --apple-id <apple id> --team-id 4U5QVH3U6A --password <app-specific password>
#   (or reuse another app's profile: WEAVER_NOTARY_PROFILE=heron scripts/release.sh)
#   Sparkle's key pair: build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys; the public key goes
#   into project.yml as SPARKLE_PUBLIC_ED_KEY.
set -e
cd "$(dirname "$0")/.."

IDENTITY="${WEAVER_DEVELOPER_ID:-Developer ID Application: BATUHAN HAYMANA (4U5QVH3U6A)}"
PROFILE="${WEAVER_NOTARY_PROFILE:-weaver}"
VERSION=$(grep MARKETING_VERSION project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
BUILD=$(grep CURRENT_PROJECT_VERSION project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
OUT=build/release
APP="$OUT/Weaver.app"
DMG="$OUT/Weaver-$VERSION.dmg"
SPARKLE=build/SourcePackages/artifacts/sparkle/Sparkle/bin

echo "▸ Weaver $VERSION ($BUILD)"
if ! grep -q 'SPARKLE_PUBLIC_ED_KEY: ".\+"' project.yml; then
  echo "SPARKLE_PUBLIC_ED_KEY is empty in project.yml; run generate_keys first." >&2
  exit 1
fi

rm -rf "$OUT" && mkdir -p "$OUT"
xcodegen generate >/dev/null
xcodebuild -project Weaver.xcodeproj -scheme Weaver -configuration Release -derivedDataPath build \
  -archivePath "$OUT/Weaver.xcarchive" archive \
  CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=4U5QVH3U6A \
  OTHER_CODE_SIGN_FLAGS="--timestamp" | grep -E "error:|ARCHIVE" || true
cp -R "$OUT/Weaver.xcarchive/Products/Applications/Weaver.app" "$APP"

echo "▸ Signing"
# Sparkle's helpers must be signed before the app that contains them.
for part in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/$part"
done
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
  --entitlements Weaver/Resources/Weaver.entitlements "$APP"
codesign --verify --deep --strict "$APP"

echo "▸ DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE" && cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Weaver" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "▸ Notarizing (a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo "▸ Appcast"
SIG=$("$SPARKLE/sign_update" "$DMG" | sed 's/^sparkle:edSignature="\([^"]*\)" length="\([0-9]*\)".*/\1 \2/')
EDSIG=${SIG%% *}; LENGTH=${SIG##* }
ITEM="    <item>
      <title>Weaver $VERSION</title>
      <pubDate>$(date -R)</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://voxyfy.github.io/weaver/releases/$VERSION.html</sparkle:releaseNotesLink>
      <enclosure url=\"https://github.com/Voxyfy/weaver/releases/download/v$VERSION/Weaver-$VERSION.dmg\"
                 sparkle:edSignature=\"$EDSIG\" length=\"$LENGTH\" type=\"application/octet-stream\"/>
    </item>"
python3 - "$ITEM" <<'PY'
import sys, pathlib
p = pathlib.Path("docs/appcast.xml"); s = p.read_text()
marker = "    <!-- scripts/release.sh appends one <item> per release here. -->"
p.write_text(s.replace(marker, marker + "\n" + sys.argv[1], 1))
PY
mkdir -p docs/releases
[ -f "docs/releases/$VERSION.html" ] || cat > "docs/releases/$VERSION.html" <<HTML
<!DOCTYPE html><html><head><meta charset="utf-8"><style>body{font:15px/1.5 -apple-system,system-ui;padding:16px 20px;color:#222}</style></head>
<body><h2>Weaver $VERSION</h2><ul><li>…</li></ul></body></html>
HTML

cp "$DMG" "$OUT/Weaver.dmg"
echo
echo "Done: $DMG and $OUT/Weaver.dmg"
echo "Next: edit docs/releases/$VERSION.html, commit docs/, push, then create the GitHub release v$VERSION with both DMGs attached."
