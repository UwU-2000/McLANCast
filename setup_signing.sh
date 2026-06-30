#!/usr/bin/env bash
#
# Creates a stable, self-signed code-signing identity for LANCast in a dedicated
# keychain. Signing with a stable certificate (instead of ad-hoc) means macOS
# keeps the Screen Recording permission across rebuilds, instead of treating each
# new build as a different app.
#
# Run once. Safe to re-run (it recreates the keychain/cert).

set -euo pipefail

KC_NAME="lancast-signing.keychain-db"
KC_PASS="lancast"
CN="LANCast Code Signing"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Generating self-signed code-signing certificate..."
cat > "$WORK/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = $CN
[ v3 ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days 3650 -nodes -config "$WORK/cert.cnf" >/dev/null 2>&1

openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout pass:"$KC_PASS" -name "$CN" >/dev/null 2>&1

echo "==> Creating dedicated keychain..."
security delete-keychain "$KC_NAME" 2>/dev/null || true
security create-keychain -p "$KC_PASS" "$KC_NAME"
security set-keychain-settings "$KC_NAME"          # disable auto-lock timeout
security unlock-keychain -p "$KC_PASS" "$KC_NAME"

echo "==> Importing identity..."
security import "$WORK/identity.p12" -k "$KC_NAME" -P "$KC_PASS" -A -T /usr/bin/codesign >/dev/null 2>&1
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KC_NAME" >/dev/null 2>&1

# Add to the user's keychain search list so codesign can find the identity.
EXISTING=$(security list-keychains -d user | sed 's/[" ]//g')
if ! echo "$EXISTING" | grep -q "$KC_NAME"; then
  security list-keychains -d user -s login.keychain-db "$KC_NAME"
fi

HASH=$(security find-identity -p codesigning "$KC_NAME" | grep "$CN" | head -1 | awk '{print $2}')
echo "==> Done. Signing identity: $HASH ($CN)"
echo "    Keychain: $HOME/Library/Keychains/$KC_NAME"
