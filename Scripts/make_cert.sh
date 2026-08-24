#!/usr/bin/env bash
#
# Puts the ONE Quill code-signing identity into this Mac's login keychain.
#
# It used to generate a fresh certificate. That was the bug.
#
# macOS pins every TCC grant — Microphone, Accessibility, Input Monitoring — to
# the app's Designated Requirement, which for a self-signed app is
#
#     identifier "com.romangigliotti.quill" and certificate leaf = H"<hash>"
#
# so the certificate IS the app's identity as far as permissions are concerned.
# Sign with a different one and every grant stops applying, silently: the System
# Settings toggle keeps reading ON while bound to a hash that no longer exists,
# and Quill appears broken with no error anywhere to explain it.
#
# A script that made a new certificate on each machine — and a release workflow
# that made a new one on each run — meant that every update took all three
# permissions away from every user. Releases v1.0.1, v1.0.2 and v1.0.3 each
# shipped a different leaf; you can still see it with `codesign -d -r-` on any
# of them. v1.0.4 onward is signed with the identity this script installs.
#
# So this restores a specific key. It never creates one. If the key is missing
# it says so and stops, because generating a replacement is precisely the
# failure it exists to prevent.
#
set -euo pipefail

IDENTITY_SHA="E500962447AD091332F21CA6C28286B30E284C4F"
VAULT="$HOME/Documents/Work/romans vault/romans vault/Security/Credentials"

if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY_SHA"; then
    echo "✅ Quill's signing identity is already in this keychain."
    echo "   $IDENTITY_SHA"
    exit 0
fi

# In order: an explicit path, the vault copy, the CI secret's shape.
P12="${QUILL_SIGNING_P12_FILE:-$VAULT/quill-signing.p12}"

if [ ! -f "$P12" ]; then
    cat >&2 <<EOF
!! Quill's signing key is not on this Mac.

   Looked for: $P12

   It is also stored as the GitHub Actions secret QUILL_SIGNING_P12 on
   romangigliotti123-arch/quill, and documented in the vault note
   "quill-code-signing.md".

   Do NOT generate a new certificate to get past this. A different certificate
   means every existing user loses Microphone, Accessibility and Input
   Monitoring on their next update, with no error to tell them why.

   Point this at the real key instead:
       QUILL_SIGNING_P12_FILE=/path/to/quill-signing.p12 Scripts/make_cert.sh
EOF
    exit 1
fi

# The password lives with the key, in the vault note. Prompted for rather than
# stored here: this file is public, the repository is public.
if [ -n "${QUILL_SIGNING_P12_PASSWORD:-}" ]; then
    PASSWORD="$QUILL_SIGNING_P12_PASSWORD"
else
    printf "Password for %s: " "$(basename "$P12")" >&2
    read -rs PASSWORD
    echo >&2
fi

# -A: let codesign use the key without a per-use keychain prompt.
security import "$P12" -k ~/Library/Keychains/login.keychain-db -P "$PASSWORD" -A

if ! security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY_SHA"; then
    echo "!! Imported, but $IDENTITY_SHA is still not present." >&2
    echo "!! That is the wrong key — signing with it would drop every user's permissions." >&2
    exit 1
fi

echo "✅ Installed Quill's signing identity."
echo "   $IDENTITY_SHA"
echo "   Next: Scripts/build.sh"
