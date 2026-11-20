#!/bin/zsh
# Creates a local, self-signed code-signing identity so every build of Unremarkable.app has the same
# signature. macOS then keeps privacy permissions (microphone, system audio) across rebuilds instead of
# asking again after each one. The identity lives in its own keychain, not your login keychain.
# Safe to re-run: does nothing if the identity already exists.
set -euo pipefail

NAME="Unremarkable Local Signing"
DIR="$HOME/Library/Application Support/Unremarkable/signing"
KC="$DIR/signing.keychain-db"
mkdir -p "$DIR"
chmod 700 "$DIR"

add_to_search_list() {
  # codesign only finds identities in keychains on the user's search list.
  if ! security list-keychains -d user | grep -q "signing.keychain-db"; then
    security list-keychains -d user -s $(security list-keychains -d user | tr -d '"' | xargs) "$KC"
  fi
}

if [[ -f "$KC" ]] && security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$NAME"; then
  add_to_search_list
  echo "Signing identity already set up."
  exit 0
fi

PASS_FILE="$DIR/keychain-password"
[[ -f "$PASS_FILE" ]] || { openssl rand -hex 24 > "$PASS_FILE"; chmod 600 "$PASS_FILE"; }
PASS=$(cat "$PASS_FILE")

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout "pass:$PASS" 2>/dev/null

[[ -f "$KC" ]] || security create-keychain -p "$PASS" "$KC"
security unlock-keychain -p "$PASS" "$KC"
security set-keychain-settings "$KC"   # no auto-lock
security import "$TMP/id.p12" -k "$KC" -P "$PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" "$KC" >/dev/null
add_to_search_list
echo "Created signing identity \"$NAME\"."
