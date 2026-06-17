#!/bin/bash
# Creates a stable self-signed "Panes Dev" code-signing identity so TCC
# permission grants survive rebuilds (ad-hoc signing changes identity every
# build; a fixed cert does not). Idempotent — safe to re-run.
#
# Uses a DEDICATED keychain with a known password so the key's partition list
# can be set non-interactively (no "codesign wants to use your keychain" GUI
# prompt). The login keychain is left untouched and kept in the search list.
set -euo pipefail

IDENTITY="Panes Dev"
KEYCHAIN="panes-signing.keychain"
KEYCHAIN_PW="panes-local-signing"

if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✓ '$IDENTITY' already exists — nothing to do"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = Panes Dev
[v3]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

echo "→ generating self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/openssl.cnf"
# Legacy PBE/MAC algorithms — macOS's `security import` can't read the
# AES/SHA-2 defaults of modern openssl. Non-empty password is also more
# reliable than an empty one.
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout pass:panes \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

echo "→ creating dedicated signing keychain"
security delete-keychain "$KEYCHAIN" 2>/dev/null || true
security create-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"            # no auto-lock timeout
security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
# Add ours to the search list WITHOUT dropping the login keychain.
security list-keychains -d user -s "$KEYCHAIN" login.keychain-db

echo "→ importing identity"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "panes" -T /usr/bin/codesign -A
security set-key-partition-list -S apple-tool:,apple:,unsigned: -s -k "$KEYCHAIN_PW" "$KEYCHAIN" >/dev/null

echo "→ verifying"
security find-identity -p codesigning | grep "$IDENTITY"
echo "✓ created '$IDENTITY' — rebuilds will now keep their permission grants"
