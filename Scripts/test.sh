#!/usr/bin/env bash
#
# Runs the test suite on the Command Line Tools toolchain — the same one
# build.sh uses, and for the same reason: its SDK is macOS 27, and QuillKit uses
# Speech APIs (AnalyzerInputConverter and friends) that do not exist in the
# macOS 26 SDK that Xcode 26.6 still ships.
#
# Getting there needs three flags, each earned the hard way:
#
#   -plugin-path .../plugins/testing
#       CLT ships libTestingMacros.dylib but does not put it on the default
#       plugin search path, so #expect fails to expand with "plugin for module
#       'TestingMacros' not found".
#
#   -rpath .../Library/Developer/Frameworks
#   -rpath .../Library/Developer/usr/lib
#       CLT keeps Testing.framework and lib_TestingInterop.dylib outside the
#       usual runtime search paths, so the built .xctest bundle cannot dlopen
#       itself. DYLD_FRAMEWORK_PATH does NOT work here — SIP strips DYLD_* from
#       the signed swiftpm-testing-helper — so the paths must be linked in.
#
# The obvious alternative, running tests under Xcode's toolchain, is a dead end:
# its 6.3.3 compiler refuses the 6.4 SDK ("this SDK is not supported by the
# compiler"), and without the 6.4 SDK the Speech code does not compile at all.
#
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CLT="/Library/Developer/CommandLineTools"
SCRATCH="${QUILL_TEST_SCRATCH:-$HOME/Library/Application Support/Quill/.build-test}"
PLUGINS="$CLT/usr/lib/swift/host/plugins/testing"
FRAMEWORKS="$CLT/Library/Developer/Frameworks"
INTEROP="$CLT/Library/Developer/usr/lib"

DEVELOPER_DIR="${DEVELOPER_DIR:-$CLT}" swift test \
    --scratch-path "$SCRATCH" \
    -Xswiftc -plugin-path -Xswiftc "$PLUGINS" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$INTEROP" \
    "$@"
