#!/bin/zsh
# Builds a universal Mirador.app and packs it into dist/Mirador-<version>.dmg (drag to Applications).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION)"
STAGE="$(mktemp -d)/Mirador"
mkdir -p "$STAGE" dist
./scripts/build-app.sh "$STAGE" --universal >/dev/null
ln -s /Applications "$STAGE/Applications"

DMG="dist/Mirador-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Mirador $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$(dirname "$STAGE")"

# With Apple credentials, sign the DMG and notarize it (the stapled ticket lets it open without warnings).
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  if [[ -n "${NOTARY_APPLE_ID:-}" ]]; then
    xcrun notarytool submit "$DMG" --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD" --wait
    xcrun stapler staple "$DMG"
  fi
fi
echo "$DMG ($(du -h "$DMG" | cut -f1))"
