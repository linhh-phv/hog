#!/bin/bash
# Builds and installs hog for the current user:
#   ~/Applications/Hog.app      menu bar app (also contains the CLI)
#   ~/.local/bin/hog            symlink to Hog.app/Contents/MacOS/hog
# Replaces a previous install of hog (quits the running app first). Touches nothing else.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh

DEST="$HOME/Applications"
mkdir -p "$DEST" "$HOME/.local/bin"
if pgrep -x HogBar >/dev/null; then osascript -e 'tell application id "io.github.linhh-phv.hog" to quit' || true; sleep 1; fi
rm -rf "$DEST/Hog.app"
cp -R dist/Hog.app "$DEST/Hog.app"
ln -sf "$DEST/Hog.app/Contents/MacOS/hog" "$HOME/.local/bin/hog"
echo "installed $DEST/Hog.app and ~/.local/bin/hog"
echo "start the menu bar app: open \"$DEST/Hog.app\""
