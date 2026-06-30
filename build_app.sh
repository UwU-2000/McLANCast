#!/usr/bin/env bash
#
# Builds LANCast and assembles a proper macOS .app bundle so it has a stable
# identity for the Screen Recording TCC permission, then ad-hoc code-signs it.
#
# Usage:
#   ./build_app.sh            # release build -> ./LANCast.app
#   ./build_app.sh debug      # debug build

set -euo pipefail

CONFIG="${1:-release}"
APP_NAME="LANCast"
APP_DIR="${APP_NAME}.app"
ROOT="$(cd "$(dirname "$0")" && pwd)"

cd "$ROOT"

echo "==> Building ($CONFIG)..."
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
EXEC="$BIN_PATH/$APP_NAME"

if [[ ! -f "$EXEC" ]]; then
  echo "error: built executable not found at $EXEC" >&2
  exit 1
fi

echo "==> Assembling ${APP_DIR}..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$EXEC" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "bundle/Info.plist" "$APP_DIR/Contents/Info.plist"

# Prefer the stable self-signed identity (see setup_signing.sh) so macOS keeps
# the Screen Recording permission across rebuilds. Fall back to ad-hoc if it
# isn't set up.
SIGN_KC="$HOME/Library/Keychains/lancast-signing.keychain-db"
SIGN_ID="$(security find-identity -p codesigning 2>/dev/null | grep 'LANCast Code Signing' | head -1 | awk '{print $2}')"

if [[ -n "$SIGN_ID" ]]; then
  echo "==> Code signing with stable identity ($SIGN_ID)..."
  [[ -f "$SIGN_KC" ]] && security unlock-keychain -p lancast "$SIGN_KC" >/dev/null 2>&1 || true
  codesign --force --options runtime \
    --entitlements "bundle/LANCast.entitlements" \
    -s "$SIGN_ID" "$APP_DIR"
else
  echo "==> Code signing (ad-hoc; run ./setup_signing.sh for a stable identity)..."
  codesign --force --sign - \
    --entitlements "bundle/LANCast.entitlements" \
    --options runtime \
    "$APP_DIR" 2>/dev/null || \
  codesign --force --sign - "$APP_DIR"
fi

echo "==> Done: $ROOT/$APP_DIR"
echo
echo "Next steps:"
echo "  1. open $APP_DIR              # launch the menu-bar app"
echo "  2. Click the menu-bar icon -> Grant Screen Recording Permission, then approve in System Settings."
echo "  3. Click Start Streaming and open the shown URL on another device on the same network."
