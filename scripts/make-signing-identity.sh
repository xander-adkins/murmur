#!/bin/zsh
# Creates a self-signed code-signing certificate in the login keychain so rebuilds keep
# the same identity and macOS privacy grants (Accessibility, Input Monitoring) survive.
# build.sh picks it up automatically by name.
set -euo pipefail

NAME="${1:-Murmur Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Certificate \"$NAME\" already exists in the login keychain."
  exit 0
fi

cat > "$WORK/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -config "$WORK/openssl.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" >/dev/null 2>&1

P12_PASS="murmur-$(date +%s)"
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -out "$WORK/identity.p12" -passout "pass:$P12_PASS" \
  -legacy 2>/dev/null || \
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -out "$WORK/identity.p12" -passout "pass:$P12_PASS"

security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12_PASS" \
  -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productsign

# Trust it for code signing in the user's trust domain (macOS may ask for your login password).
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
security find-identity -v -p codesigning | grep -F "$NAME" || {
  echo "Identity imported but not yet listed as valid; try again after approving any prompt." >&2
  exit 1
}
echo "Created signing identity \"$NAME\"."
