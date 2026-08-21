#!/usr/bin/env bash
#
# Scripts/test.sh — run the test suite.
#
# `swift test` on its own does not work in this project, and the reason is worth
# writing down because it wastes an evening otherwise.
#
#   1. TOOLCHAIN. The library uses AnalyzerInputConverter, which exists only in
#      the macOS 27 SDK. Command Line Tools carries that SDK; Xcode 26.6 still
#      carries macOS 26. `swift test` defaults to Xcode's, so the QuillKit module
#      fails to emit — "cannot find type 'AnalyzerInputConverter' in scope" —
#      and takes every test down with it. Scripts/build.sh already prefers CLT
#      for the same reason; this does the same.
#
#   2. TEST RUNTIME. CLT compiles the bundle but its Testing.framework is not on
#      any path dyld searches, and the framework itself then cannot find
#      lib_TestingInterop.dylib, which lives one directory away in
#      Library/Developer/usr/lib. Both get symlinked into the products directory,
#      which IS on the loader's search list. They are symlinks into CLT, so they
#      track whatever CLT has rather than pinning a copy.
#
#   3. SCRATCH PATH. Same as the build: SwiftPM's scratch dir must live outside
#      ~/Documents or iCloud stamps fileprovider xattrs on the products and
#      codesign refuses the test bundle.
#
# A note on "plugin for module 'TestingMacros' not found", because it will come
# back and it is a red herring. It shows up on a cold or half-populated build
# directory and stops once the plugin has been loaded once — the plugin is there
# the whole time, at CLT/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib.
# If you hit it, run the script again rather than going looking for a missing file.
#
# Takes the same arguments as `swift test`:
#
#     Scripts/test.sh --filter repairsCompoundNames
#
# Full suite is 457 tests in 3 suites, about 25 seconds. The NIM live tests talk
# to the real endpoint, so a run needs network and a key.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CLT="/Library/Developer/CommandLineTools"
SCRATCH="${QUILL_SCRATCH:-$HOME/Library/Application Support/Quill/.build}"
PRODUCTS="$SCRATCH/out/Products/Debug"

# 4. THE TESTING MACRO PLUGIN. SwiftPM intermittently omits libTestingMacros from
#    the compiler's -load-resolved-plugin list, and every #Test and #expect in the
#    suite then fails to expand: "external macro implementation type
#    'TestingMacros.TestDeclarationMacro' could not be found". It looks like a
#    missing file and is not — the dylib is where it has always been.
#
#    The old note said rerunning clears it. It does not: one sequence failed four
#    runs in a row, in fresh scratch directories, on full runs as well as
#    --filter ones. Naming the plugin explicitly fixes it every time, and costs
#    nothing when SwiftPM was going to find it anyway.
TESTING_PLUGIN="$CLT/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
PLUGIN=()
[[ -f "$TESTING_PLUGIN" ]] && PLUGIN=(-Xswiftc -load-plugin-library -Xswiftc "$TESTING_PLUGIN")

# The symlinks have to exist before the bundle is loaded, and the products
# directory has to exist before they can be made. `swift test` does both halves
# — build then run — so it is run twice: once allowed to fail while it lays the
# directory down, then again for real once dyld can find the framework.
#
# `|| true` on the first pass is not sloppiness. That pass is EXPECTED to fail,
# on exactly the dlopen error the symlinks then fix.
DEVELOPER_DIR="$CLT" swift test --scratch-path "$SCRATCH" "${PLUGIN[@]}" "$@" >/dev/null 2>&1 || true

mkdir -p "$PRODUCTS/PackageFrameworks"
ln -sfn "$CLT/Library/Developer/Frameworks/Testing.framework" \
        "$PRODUCTS/PackageFrameworks/Testing.framework"
ln -sfn "$CLT/Library/Developer/usr/lib/lib_TestingInterop.dylib" \
        "$PRODUCTS/lib_TestingInterop.dylib"

exec env DEVELOPER_DIR="$CLT" swift test --scratch-path "$SCRATCH" "${PLUGIN[@]}" "$@"
