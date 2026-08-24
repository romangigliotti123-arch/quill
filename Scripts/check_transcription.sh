#!/usr/bin/env bash
#
# Does the app that was just built actually turn audio into words?
#
# This exists because the answer was "no" for every release ever published, and
# nothing noticed for eight of them.
#
# `AnalyzerFeed` chose between two audio paths with `#if compiler(>=6.4)` — a
# decision made by whichever machine ran the compiler. GitHub's runner had a
# newer Xcode than the developer's Mac, so every published build took the macOS
# 27 `AnalyzerInputConverter` branch and every local build took the hand-rolled
# one. The published branch produced zero partial results and an empty
# transcript, and the local branch produced a perfect one, from identical
# source. There was no commit to review and no diff to look at.
#
# Unit tests could not catch it: they run on the developer's Mac, which compiles
# the other branch. The only check that could was this one — run the artefact
# that is about to be uploaded against real audio and read what comes out.
#
# Usage: Scripts/check_transcription.sh [path/to/Quill.app]
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$HOME/Library/Application Support/Quill/build/Quill.app}"
BIN="$APP/Contents/MacOS/Quill"
CLIP="$ROOT/Tests/Fixtures/speech-check.wav"

[ -x "$BIN" ] || { echo "!! No executable at $BIN" >&2; exit 1; }
[ -f "$CLIP" ] || { echo "!! No fixture at $CLIP" >&2; exit 1; }

# Never the real folder. A check that writes into someone's dictation history is
# a check that changes the thing it is measuring.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

echo "==> Transcribing a 3-second clip through $(basename "$APP")"
OUT="$(QUILL_DATA_DIR="$SCRATCH" \
       QUILL_TRANSCRIBE_FILE="$CLIP" \
       QUILL_TRANSCRIBE_BATCH=1 \
       "$BIN" 2>&1)" || true
echo "$OUT" | grep -E "results|peak input|errors|transcript" | sed 's/^/    /'

TRANSCRIPT="$(echo "$OUT" | sed -n 's/^transcript *: *//p')"

if [ -z "${TRANSCRIPT// /}" ]; then
    echo "!! The app transcribed nothing at all." >&2
    echo "!! Audio went in — check the peak input level above — and no words came out." >&2
    echo "!! This is what shipped in every release up to v1.0.8. Do not publish it." >&2
    exit 1
fi

# One known word, not the whole sentence: the check is "speech became words",
# and pinning the exact string would fail on a recogniser improvement, which is
# not a regression.
if ! echo "$TRANSCRIPT" | grep -qi "country"; then
    echo "!! Transcribed something, but not the words in the clip:" >&2
    echo "!!   $TRANSCRIPT" >&2
    echo "!! Expected it to contain \"country\"." >&2
    exit 1
fi

echo "✅ \"$TRANSCRIPT\""
