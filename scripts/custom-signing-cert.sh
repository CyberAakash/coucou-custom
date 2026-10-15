#!/bin/bash
# Creates the self-signed "Coucou Custom Local Signing" code-signing identity in the login keychain,
# once per Mac. custom-install.sh signs with it so macOS permissions survive rebuilds.
# The private key never leaves this Mac and is only allowed for /usr/bin/codesign.
set -euo pipefail

NAME="Coucou Custom Local Signing"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists; nothing to do."; exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
umask 077
cat > "$TMP/cfg" <<EOF
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
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cfg" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASS="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout "pass:$PASS" 2>/dev/null
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
# "CSSMERR_TP_NOT_TRUSTED" in this listing is expected for a self-signed identity; codesign still uses it.
security find-identity -p codesigning | grep "\"$NAME\""
