#!/usr/bin/env bash
# Create a stable, self-signed code-signing identity in your login keychain.
#
# Why: Screen Recording (TCC) permission is bound to an app's code signature.
# Ad-hoc signing changes every rebuild, so macOS forgets the grant each time.
# A stable identity keeps the permission across rebuilds.
#
# This is a local dev cert only — it does NOT let you distribute the app.
# Remove it any time in Keychain Access (login keychain → "Vectorscope Dev").
set -euo pipefail

NAME="Vectorscope Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "✓ Identity \"$NAME\" already exists — nothing to do."
    exit 0
fi

DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT

cat > "$DIR/cert.cnf" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[ dn ]
CN = Vectorscope Dev
[ ext ]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
EOF

echo "▸ Generating key + self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$DIR/key.pem" -out "$DIR/cert.pem" \
    -days 3650 -config "$DIR/cert.cnf" >/dev/null 2>&1

# A non-empty transient password avoids the empty-password PKCS12 MAC
# ambiguity that makes `security import` fail. The p12 is deleted right after.
P12PASS="vectorscope-transient"
openssl pkcs12 -export -inkey "$DIR/key.pem" -in "$DIR/cert.pem" \
    -out "$DIR/id.p12" -name "$NAME" -passout "pass:$P12PASS" >/dev/null 2>&1

echo "▸ Importing into login keychain (allowing codesign to use it)…"
security import "$DIR/id.p12" -k "$KEYCHAIN" -P "$P12PASS" -A -T /usr/bin/codesign

echo ""
echo "✓ Created code-signing identity: \"$NAME\""
security find-identity -v -p codesigning | grep "$NAME" || true
