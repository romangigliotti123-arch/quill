#!/usr/bin/env bash
#
# Regenerates Resources/AppIcon.icns from the same nib geometry the in-app mark
# uses, so the icon and the app cannot drift apart. Run after changing the mark.
#
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}" \
    swiftc -O "$ROOT/Scripts/make_icon.swift" -o "$TMP/mkicon"
"$TMP/mkicon" "$TMP/AppIcon.iconset"
iconutil -c icns "$TMP/AppIcon.iconset" -o "$ROOT/Resources/AppIcon.icns"
echo "✅ Resources/AppIcon.icns"
