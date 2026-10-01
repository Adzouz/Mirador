#!/bin/zsh
# Builds Mirador.app into ~/Applications and links the CLI as ~/.local/bin/mirador.
set -euo pipefail
cd "$(dirname "$0")/.."

osascript -e 'quit app "Mirador"' 2>/dev/null || true
mkdir -p .build/app "$HOME/Applications" "$HOME/.local/bin"
BUILT="$(./scripts/build-app.sh .build/app)"
APP="$HOME/Applications/Mirador.app"
rm -rf "$APP"
cp -R "$BUILT" "$APP"

ln -sf "$APP/Contents/Helpers/mirador" "$HOME/.local/bin/mirador"

echo "Installed $APP"
echo "CLI: $HOME/.local/bin/mirador"
