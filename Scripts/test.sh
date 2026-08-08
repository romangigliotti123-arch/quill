#!/usr/bin/env bash
#
# Runs the test suite.
#
# Note the toolchain differs from build.sh on purpose. The Command Line Tools
# do not ship libTestingMacros.dylib, so swift-testing's #expect cannot expand
# there; Xcode's toolchain has it. build.sh keeps CLT because its SDK is macOS 27.
# If a test ever fails to compile with a missing macOS 27 symbol, that is this
# split showing up — guard the 27-only API behind #if canImport / @available and
# keep the tested logic SDK-agnostic.
#
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
SCRATCH="${QUILL_SCRATCH:-$HOME/Library/Application Support/Quill/.build-test}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
    swift test --scratch-path "$SCRATCH" "$@"
