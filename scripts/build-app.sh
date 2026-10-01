#!/bin/zsh
# Builds Mirador.app into the given folder. `--universal` makes an arm64 + x86_64 build (for sharing).
#
# Optional environment:
#   SIGN_IDENTITY      "Developer ID Application: …" certificate in the keychain → distributable, hardened build
#   SPARKLE_FEED_URL   appcast for auto-updates; defaults to <origin repo>/releases/latest/download/appcast.xml
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:?usage: build-app.sh <output-dir> [--universal]}"
VERSION="$(cat VERSION)"
if [[ "${2:-}" == "--universal" ]]; then
  swift build -c release --arch arm64 --arch x86_64 >&2
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
else
  swift build -c release >&2
  BIN="$(swift build -c release --show-bin-path)"
fi

# Auto-update feed: GitHub "latest release" asset of the origin repository.
if [[ -z "${SPARKLE_FEED_URL:-}" ]]; then
  ORIGIN="$(git remote get-url origin 2>/dev/null || true)"
  SLUG="$(echo "$ORIGIN" | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
  [[ "$ORIGIN" == *github.com* && -n "$SLUG" ]] && SPARKLE_FEED_URL="https://github.com/$SLUG/releases/latest/download/appcast.xml"
fi
FEED_XML=""
[[ -n "${SPARKLE_FEED_URL:-}" ]] && FEED_XML="<key>SUFeedURL</key><string>$SPARKLE_FEED_URL</string>"

APP="$OUT/Mirador.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/MiradorApp" "$APP/Contents/MacOS/Mirador"
cp "$BIN/mirador" "$APP/Contents/Helpers/mirador"
cp -R "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The Claude Code skill is generated from the agent guide built into the CLI (single source).
"$BIN/mirador" guide --skill > "$APP/Contents/Resources/mirador-skill.md"
cp "$APP/Contents/Resources/mirador-skill.md" claude/skills/mirador/SKILL.md

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Mirador</string>
  <key>CFBundleDisplayName</key><string>Mirador</string>
  <key>CFBundleIdentifier</key><string>dev.mirador.app</string>
  <key>CFBundleExecutable</key><string>Mirador</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>SUPublicEDKey</key><string>$(cat Resources/sparkle-public-key)</string>
  <key>SUEnableAutomaticChecks</key><true/>
  $FEED_XML
</dict>
</plist>
PLIST

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  # Inside-out, hardened runtime, as Sparkle documents for Developer ID apps.
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  sign() { codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$@"; }
  sign "$SPARKLE/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
  sign "$SPARKLE/Autoupdate"
  sign "$SPARKLE/Updater.app"
  sign "$APP/Contents/Frameworks/Sparkle.framework"
  sign "$APP/Contents/Helpers/mirador"
  sign "$APP"
else
  # Ad-hoc: fine locally; other Macs need right-click → Open once.
  codesign --force --deep --sign - "$APP" >/dev/null
fi
echo "$APP"
