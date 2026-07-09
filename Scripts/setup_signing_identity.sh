#!/bin/bash
# One-time setup: creates a local self-signed code-signing certificate and
# imports it into the login keychain, trusted for code signing.
#
# Why: ad-hoc signing (`codesign --sign -`) computes its signature over the
# binary's contents, so every rebuild produces a different signature and
# macOS silently invalidates prior Accessibility/Input Monitoring grants
# even though System Settings still shows the old entry as "on". Signing
# with a stable certificate identity instead means TCC keys off the
# certificate, not the binary hash, so grants survive rebuilds.
set -euo pipefail

cd "$(dirname "$0")/.."

IDENTITY_NAME="KeyboardLock Local Dev"
SIGNING_DIR="signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

mkdir -p "${SIGNING_DIR}"

if security find-identity -v -p codesigning "${KEYCHAIN}" | grep -q "${IDENTITY_NAME}"; then
    echo "Identity '${IDENTITY_NAME}' already present in login keychain. Nothing to do."
    exit 0
fi

CONFIG_FILE="${SIGNING_DIR}/codesign.cnf"
KEY_FILE="${SIGNING_DIR}/key.pem"
CERT_FILE="${SIGNING_DIR}/cert.pem"
P12_FILE="${SIGNING_DIR}/identity.p12"
P12_PASSWORD="$(openssl rand -base64 24)"

cat > "${CONFIG_FILE}" <<CONF
[req]
distinguished_name = dn
x509_extensions = v3_req
prompt = no

[dn]
CN = ${IDENTITY_NAME}

[v3_req]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONF

openssl req -x509 -newkey rsa:2048 -keyout "${KEY_FILE}" -out "${CERT_FILE}" \
    -days 3650 -nodes -config "${CONFIG_FILE}" -extensions v3_req

openssl pkcs12 -export -out "${P12_FILE}" -inkey "${KEY_FILE}" -in "${CERT_FILE}" \
    -passout "pass:${P12_PASSWORD}"

security import "${P12_FILE}" -k "${KEYCHAIN}" -P "${P12_PASSWORD}" \
    -T /usr/bin/codesign -T /usr/bin/security

echo
echo "Trusting the certificate for code signing — macOS may prompt you to"
echo "confirm/authenticate this step."
security add-trusted-cert -r trustRoot -p codeSign -k "${KEYCHAIN}" "${CERT_FILE}"

rm -f "${KEY_FILE}" "${P12_FILE}"

echo
echo "Done. Verify with: security find-identity -v -p codesigning"
