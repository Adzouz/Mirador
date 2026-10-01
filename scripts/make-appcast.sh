#!/bin/zsh
# Writes dist/appcast.xml for one release, signed for Sparkle.
#   make-appcast.sh <dmg> <download-url> <release-page-url>
# Signing key: SPARKLE_PRIVATE_KEY (CI secret, from `generate_keys --account mirador -x key.txt`),
# otherwise the "mirador" key in the login Keychain.
set -euo pipefail
cd "$(dirname "$0")/.."

DMG="${1:?dmg}"; URL="${2:?download url}"; NOTES_URL="${3:?release page url}"
VERSION="$(cat VERSION)"
SIGN_UPDATE="$(find .build/artifacts -path '*Sparkle/bin/sign_update' | head -1)"
[[ -x "$SIGN_UPDATE" ]] || { echo "sign_update not found: run swift package resolve" >&2; exit 1; }

if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  KEY_FILE="$(mktemp)"
  print -rn -- "$SPARKLE_PRIVATE_KEY" > "$KEY_FILE"
  ATTRS="$("$SIGN_UPDATE" --ed-key-file "$KEY_FILE" "$DMG")"
  rm -f "$KEY_FILE"
else
  ATTRS="$("$SIGN_UPDATE" --account mirador "$DMG")"
fi
# ATTRS looks like: sparkle:edSignature="…" length="…"

cat > dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Mirador</title>
    <item>
      <title>Mirador $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$NOTES_URL</sparkle:fullReleaseNotesLink>
      <enclosure url="$URL" type="application/octet-stream" $ATTRS />
    </item>
  </channel>
</rss>
XML
echo dist/appcast.xml
