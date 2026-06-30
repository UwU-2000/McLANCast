#!/usr/bin/env bash
#
# Builds LANCast, installs it into /Applications, and launches it.
#
# Usage: ./install.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP="LANCast.app"
DEST_DIR="/Applications"

# 1. Build + sign the app bundle.
"$ROOT/build_app.sh" release

# 2. Quit any running instance so we can replace it.
if pkill -x LANCast 2>/dev/null; then
  echo "==> Quit running LANCast instance"
  sleep 1
fi

# 3. Install into /Applications (falls back to ~/Applications if needed).
if [[ ! -w "$DEST_DIR" ]]; then
  DEST_DIR="$HOME/Applications"
  mkdir -p "$DEST_DIR"
  echo "==> /Applications not writable; installing to $DEST_DIR"
fi

echo "==> Installing to $DEST_DIR/$APP"
rm -rf "$DEST_DIR/$APP"
cp -R "$APP" "$DEST_DIR/"

# 4. Strip any quarantine attribute (built locally, but just in case).
xattr -dr com.apple.quarantine "$DEST_DIR/$APP" 2>/dev/null || true

# 5. Launch.
echo "==> Launching"
open "$DEST_DIR/$APP"

echo
echo "Installed: $DEST_DIR/$APP"
echo "Look for the LANCast icon in your menu bar (top-right)."
echo "First time: menu -> Grant Screen Recording Permission, approve in System Settings, then Start Streaming."
