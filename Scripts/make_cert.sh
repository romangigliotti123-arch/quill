#!/usr/bin/env bash
#
# Creates a stable self-signed code-signing identity ("Quill Self-Signed").
#
# Why this exists, and why it runs before anything else:
# ad-hoc signing (`codesign -s -`) pins the app's Designated Requirement to a
# per-build cdhash. The cdhash changes on every rebuild, so macOS silently drops
# every TCC grant (Microphone, Speech Recognition, Accessibility, Input
# Monitoring) each time you build. The System Settings toggle keeps *reading*
# ON while being bound to a dead hash, so the app appears broken with no error
# anywhere. A stable certificate produces a DR of
#   identifier "com.romangigliotti.quill" and certificate leaf = H"<fixed>"
# which is byte-identical across rebuilds, so the grants survive.
#
# Run once, ever.
#
set -euo pipefail

IDENTITY="Quill Self-Signed"

if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✅ '$IDENTITY' already exists — nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cfg" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = Quill Self-Signed
[v3]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/k.key" -out "$TMP/k.crt" \
    -days 3650 -nodes -config "$TMP/cfg" >/dev/null 2>&1

# -legacy: macOS's `security` cannot read OpenSSL 3's default PKCS#12 MAC.
openssl pkcs12 -export -legacy -inkey "$TMP/k.key" -in "$TMP/k.crt" \
    -out "$TMP/k.p12" -passout pass:quill -name "$IDENTITY" >/dev/null 2>&1

# -A: allow codesign to use the key without a per-use keychain prompt.
security import "$TMP/k.p12" -k ~/Library/Keychains/login.keychain-db -P quill -A

echo "✅ Created '$IDENTITY'."
echo "   Next: Scripts/build.sh"
