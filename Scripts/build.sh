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

# The one certificate every Quill is signed with, named by its SHA-1 rather
# than by its common name.
#
# macOS pins a TCC grant to the app's Designated Requirement, which for a
# self-signed app is `identifier "com.romangigliotti.quill" and certificate
# leaf = H"<this>"`. Change the certificate and every grant the user has —
# Microphone, Accessibility, Input Monitoring — silently stops applying: the
# System Settings toggle keeps reading ON while pointing at a dead hash, and
# the app looks broken with no error anywhere.
#
# That is what used to happen on every single release. The release workflow
# generated a throwaway certificate per run, so v1.0.1, v1.0.2 and v1.0.3 each
# shipped a different leaf and each update cost the user all three permissions.
# CI now imports this exact identity from the QUILL_SIGNING_P12 secret, so a
# locally built Quill and a downloaded one are the same app as far as TCC is
# concerned, forever.
#
# By hash and not by name because two certificates can share a common name —
# an older "Quill Self-Signed" is still sitting in this Mac's login keychain —
# and `codesign -s <name>` fails with "ambiguous" when they do.
IDENTITY_SHA="E500962447AD091332F21CA6C28286B30E284C4F"

CONFIG="debug"
INSTALL=false
case "${1:-}" in
    --release) CONFIG="release" ;;
    --install) CONFIG="release"; INSTALL=true ;;
esac

CLT="/Library/Developer/CommandLineTools"
XCODE="/Applications/Xcode.app/Contents/Developer"

# SwiftPM's scratch dir must live outside ~/Documents too. iCloud stamps
# com.apple.fileprovider xattrs on intermediate products, and codesign then
# refuses to sign the test bundle ("resource fork ... not allowed"). Keeping it
# here also stops every incremental build from fighting the sync daemon.
SCRATCH="${QUILL_SCRATCH:-$HOME/Library/Application Support/Quill/.build}"
export QUILL_SCRATCH="$SCRATCH"

build_with() {
    local dev_dir="$1"
    echo "==> swift build -c $CONFIG   (toolchain: $dev_dir)"
    DEVELOPER_DIR="$dev_dir" swift build -c "$CONFIG" --product "$APP_NAME" --scratch-path "$SCRATCH"
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

BIN_PATH="$(DEVELOPER_DIR="$CHOSEN" swift build -c "$CONFIG" --product "$APP_NAME" --scratch-path "$SCRATCH" --show-bin-path)/$APP_NAME"
[[ -x "$BIN_PATH" ]] || { echo "!! No binary at $BIN_PATH" >&2; exit 1; }

# QuillMCP ships inside the bundle so the connection instructions on the
# Account tab can point at a real path — "build it yourself from source" is
# not a setup step anyone doing this from Claude Desktop should have to take.
echo "==> swift build -c $CONFIG   (QuillMCP, same toolchain: $CHOSEN)"
DEVELOPER_DIR="$CHOSEN" swift build -c "$CONFIG" --product QuillMCP --scratch-path "$SCRATCH"
MCP_BIN_PATH="$(DEVELOPER_DIR="$CHOSEN" swift build -c "$CONFIG" --product QuillMCP --scratch-path "$SCRATCH" --show-bin-path)/QuillMCP"
[[ -x "$MCP_BIN_PATH" ]] || { echo "!! No binary at $MCP_BIN_PATH" >&2; exit 1; }

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
cp "$MCP_BIN_PATH" "$CONTENTS/MacOS/QuillMCP"
cp "$ROOT/Packaging/Info.plist" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/"

# Every `.bundle` SwiftPM built alongside the binary — QuillKit's own
# (GoogleService-Info.plist) and, since Firebase, a dozen more that its own
# dependency tree carries (grpc, abseil, leveldb, nanopb...). `Bundle.module`
# looks relative to the running binary's location, which after this script
# reassembles a plain `swift build` product into an .app is
# Contents/Resources — nowhere else. Skipped silently for as long as this
# stayed true only of QuillKit's own resource, because nothing had reached
# for `Bundle.module` yet; the first thing that did crashed at launch with
# "unable to find bundle named Quill_QuillKit" and no clue that the fix was
# here rather than in the code that asked for it.
shopt -s nullglob
for bundle in "$(dirname "$BIN_PATH")"/*.bundle; do
    cp -R "$bundle" "$CONTENTS/Resources/"
done
shopt -u nullglob

# The app has to be able to FIND its resources once it is assembled.
#
# `Bundle.module` is generated code and its failure path is `fatalError`. The
# accessor SwiftPM generates for the release build looks in exactly two places:
# `Bundle.main.bundleURL/<name>.bundle` — the .app root, not Contents/Resources
# where the loop above just put it — and the absolute path of the build
# directory on the machine that compiled it. v1.0.0 shipped that way and every
# sign-in crashed on every Mac except the one that built it, where the baked
# build path still existed.
#
# The app no longer calls `Bundle.module` (see AccountStore.plistURL). This
# check is the packaging half: assert the file the app looks for is actually
# reachable in the assembled bundle, in whichever shape SwiftPM emitted, so a
# broken package fails here instead of in front of a user.
found_config=false
for bundle in "$CONTENTS/Resources"/*.bundle; do
    [[ -e "$bundle" ]] || continue
    if [[ -f "$bundle/GoogleService-Info.plist" ]] \
    || [[ -f "$bundle/Contents/Resources/GoogleService-Info.plist" ]]; then
        found_config=true
    fi
done
if ! $found_config; then
    echo "!! No GoogleService-Info.plist reachable under $CONTENTS/Resources/*.bundle." >&2
    echo "!! Accounts, sync and MCP would all be unavailable. Refusing to package." >&2
    exit 1
fi

SIGN_ID="-"
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY_SHA"; then
    SIGN_ID="$IDENTITY_SHA"
    echo "==> Signing: Quill Self-Signed ($IDENTITY_SHA)"
    echo "    Stable across builds and releases, so TCC grants survive both."
else
    echo "!! The shared signing identity is not in this keychain." >&2
    echo "!! Signing ad-hoc: permissions will drop on every rebuild, and this" >&2
    echo "!! build will not match a downloaded Quill either." >&2
    echo "!! Restore it with: Scripts/make_cert.sh" >&2
fi

xattr -cr "$APP_DIR"
# `| sed` made this always succeed: codesign's exit status was the pipeline's
# first command and was discarded, so a signing failure printed and carried on.
set -o pipefail
codesign --force --deep --sign "$SIGN_ID" \
         --entitlements "$ROOT/Packaging/$APP_NAME.entitlements" \
         --identifier "$BUNDLE_ID" \
         "$APP_DIR" 2>&1 | sed 's/^/    /'

codesign --verify --verbose=2 "$APP_DIR" 2>&1 | sed 's/^/    /'
echo "==> Designated requirement (must be identical across builds):"
DR="$(codesign -d -r- "$APP_DIR" 2>&1 | grep -o 'designated => .*')"
echo "    $DR"

# Checked rather than printed. A wrong leaf here is the whole difference
# between an update that keeps the user's permissions and one that quietly
# takes them away, and it is invisible in a wall of build output.
if [ "$SIGN_ID" != "-" ]; then
    EXPECTED_LEAF="$(echo "$IDENTITY_SHA" | tr 'A-Z' 'a-z')"
    if ! echo "$DR" | tr 'A-Z' 'a-z' | grep -q "$EXPECTED_LEAF"; then
        echo "!! Signed with the wrong certificate. Every user's TCC grants would drop." >&2
        echo "!! Expected leaf H\"$EXPECTED_LEAF\"." >&2
        exit 1
    fi
fi

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
