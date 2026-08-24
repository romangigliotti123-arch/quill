#!/usr/bin/env bash
#
# Download a published release and check it actually works, on a Mac that can.
#
# **This is the gate, not the CI job.** The release workflow builds the artefact
# and cannot test it: GitHub's macOS runners have no on-device speech model, so
# `check_transcription.sh` there answers "cannot tell" and says so. That is the
# whole reason dictation shipped broken in eight consecutive releases — the only
# machine that could have caught it was never asked.
#
# Run this after the release publishes and before bumping the Homebrew cask or
# telling anybody it is out.
#
# Usage: Scripts/verify_release.sh v1.0.9
#
set -euo pipefail

VERSION="${1:?usage: Scripts/verify_release.sh v1.0.9}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED_LEAF="e500962447ad091332f21ca6c28286b30e284c4f"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
URL="https://github.com/romangigliotti123-arch/quill/releases/download/$VERSION/Quill-macOS.zip"

echo "==> Downloading $VERSION"
curl -fsSL -o "$WORK/q.zip" "$URL"
ditto -x -k "$WORK/q.zip" "$WORK/app"
APP="$WORK/app/Quill.app"

echo "==> Version and signature"
GOT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
echo "    version $GOT"
DR="$(codesign -d -r- "$APP" 2>&1 | grep -o 'designated => .*' | tr 'A-Z' 'a-z')"
echo "    $DR"
if ! echo "$DR" | grep -q "$EXPECTED_LEAF"; then
    echo "!! Wrong signing certificate — every user's permissions would drop." >&2
    exit 1
fi

echo "==> The part CI cannot do"
QUILL_REQUIRE_TRANSCRIPTION=1 "$ROOT/Scripts/check_transcription.sh" "$APP"

echo
echo "✅ $VERSION is signed correctly and turns speech into words."
