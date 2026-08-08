#!/usr/bin/env bash
#
# Builds Quill and assembles a signed, launchable Quill.app.
#
# Usage:
#   Scripts/build.sh              # debug
#   Scripts/build.sh --release    # optimized
#   Scripts/build.sh --install    # optimized + copy to /Applications
#
# Two things here are load-bearing and must not be "cleaned up":
#
#  1. STABLE PATH, OUTSIDE iCLOUD. The .app is always written to
#     ~/Library/Application Support/Quill/build/Quill.app. TCC binds grants to a
#     path + designated requirement pair, so the path must not move; and it must
#     not be under ~/Documents, because iCloud's xattrs make codesign reject the
#     bundle outright. See the comment above APP_ROOT.
#
#  2. TOOLCHAIN ORDER. We try the Command Line Tools toolchain FIRST, because
#     its SDK is macOS 27 while Xcode 26.6 still carries the macOS 26 SDK — and
#     the Speech conveniences we want (CaptureInputSequenceProvider,
#     AnalyzerInputConverter) exist only in 27. If that build fails we fall back
#     to Xcode's toolchain, which ships libSwiftUIMacros.dylib that CLT lacks.
#     Set DEVELOPER_DIR yourself to pin either one.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Quill"
BUNDLE_ID="com.romangigliotti.quill"
IDENTITY="Quill Self-Signed"

CONFIG="debug"
INSTALL=false
case "${1:-}" in
    --release) CONFIG="release" ;;
    --install) CONFIG="release"; INSTALL=true ;;
esac

CLT="/Library/Developer/CommandLineTools"
XCODE="/Applications/Xcode.app/Contents/Developer"

build_with() {
    local dev_dir="$1"
    echo "==> swift build -c $CONFIG   (toolchain: $dev_dir)"
    DEVELOPER_DIR="$dev_dir" swift build -c "$CONFIG" --product "$APP_NAME"
}

if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    build_with "$DEVELOPER_DIR"
    CHOSEN="$DEVELOPER_DIR"
elif build_with "$CLT"; then
    CHOSEN="$CLT"
else
    echo "!! CLT toolchain failed — retrying with Xcode's (it has libSwiftUIMacros.dylib)." >&2
    build_with "$XCODE"
    CHOSEN="$XCODE"
fi

BIN_PATH="$(DEVELOPER_DIR="$CHOSEN" swift build -c "$CONFIG" --product "$APP_NAME" --show-bin-path)/$APP_NAME"
[[ -x "$BIN_PATH" ]] || { echo "!! No binary at $BIN_PATH" >&2; exit 1; }

# The bundle is assembled OUTSIDE ~/Documents on purpose. iCloud Drive stamps
# com.apple.fileprovider.fpfs#P and com.apple.FinderInfo onto everything it
# syncs, `xattr -cr` cannot remove the file-provider one, and codesign then
# refuses the bundle with "resource fork, Finder information, or similar
# detritus not allowed". Source stays in Documents (synced, backed up); build
# output lives here (stable path, so TCC grants stick, and no iCloud).
APP_ROOT="${QUILL_BUILD_DIR:-$HOME/Library/Application Support/Quill/build}"
APP_DIR="$APP_ROOT/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN_PATH" "$CONTENTS/MacOS/$APP_NAME"
cp "$ROOT/Packaging/Info.plist" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/"

SIGN_ID="-"
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    SIGN_ID="$IDENTITY"
    echo "==> Signing: $SIGN_ID (stable — TCC grants survive rebuilds)"
else
    echo "!! Signing ad-hoc. Permissions WILL drop on every rebuild." >&2
    echo "!! Fix once with: Scripts/make_cert.sh" >&2
fi

xattr -cr "$APP_DIR"
codesign --force --deep --sign "$SIGN_ID" \
         --entitlements "$ROOT/Packaging/$APP_NAME.entitlements" \
         --identifier "$BUNDLE_ID" \
         "$APP_DIR" 2>&1 | sed 's/^/    /'

codesign --verify --verbose=2 "$APP_DIR" 2>&1 | sed 's/^/    /'
echo "==> Designated requirement (must be identical across builds):"
codesign -d -r- "$APP_DIR" 2>&1 | grep -o 'designated => .*' | sed 's/^/    /'

if $INSTALL; then
    echo "==> Installing to /Applications"
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP_DIR" "/Applications/$APP_NAME.app"
fi

# Convenience symlink so the project dir still has a handle on the bundle.
ln -sfn "$APP_DIR" "$ROOT/Quill.app" 2>/dev/null || true

echo "✅ $APP_DIR"
echo "   Launch with:  open \"$APP_DIR\""
echo "   NEVER launch via Contents/MacOS/$APP_NAME directly — running it"
echo "   from a terminal inherits the terminal's Accessibility grant and reports"
echo "   false success. Every 'works on my machine' in this problem space is that."
