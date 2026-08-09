# shellcheck shell=bash
# Shared plumbing for the quill comparison rig.
#
# Everything here exists to make one failure mode impossible: a run that looks
# like it worked but measured silence, or measured the wrong device, or scored
# a transcript that was already sitting in the database before we started.
# Every helper either proves its precondition or kills the run.

set -euo pipefail

RIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$RIG_DIR/.." && pwd)"
AUDIO_DIR="$RIG_DIR/audio"
CLIPS_DIR="$AUDIO_DIR/clips"
DOWNLOAD_DIR="$AUDIO_DIR/downloads"
OUT_DIR="$RIG_DIR/out"
BIN_DIR="$RIG_DIR/bin"
MANIFEST="$RIG_DIR/corpus_manifest.tsv"

FLOW_APP="/Applications/Wispr Flow.app"
QUILL_APP="$REPO_DIR/build/Quill.app"

# Overridable so the rig's own tests can run against fixtures. A harness must
# never write into a real app's data directory, not even for a "safe" read test.
FLOW_DB="${FLOW_DB:-$HOME/Library/Application Support/Wispr Flow/flow.sqlite}"
QUILL_HISTORY="${QUILL_HISTORY:-$HOME/Library/Application Support/Quill/history.json}"

# The loopback device. BlackHole 2ch is the default install; 16ch also works.
BLACKHOLE_MATCH="${BLACKHOLE_MATCH:-BlackHole}"

# ── output ────────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_DIM=$'\033[2m';  C_BLD=$'\033[1m';  C_RST=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_DIM=''; C_BLD=''; C_RST=''
fi

say()  { printf '%s\n' "$*" >&2; }
info() { printf '%s\n' "${C_DIM}$*${C_RST}" >&2; }
ok()   { printf '%s\n' "${C_GRN}  ok${C_RST}  $*" >&2; }
warn() { printf '%s\n' "${C_YEL}warn${C_RST}  $*" >&2; }

# die <message> [fix-line ...]
# Never exits 0. Always says what to do next — a rig that fails without a fix
# is a rig that gets bypassed.
die() {
    local msg="$1"; shift
    printf '%s\n' "${C_RED}FAIL${C_RST}  ${C_BLD}${msg}${C_RST}" >&2
    local line
    for line in "$@"; do printf '      %s\n' "$line" >&2; done
    exit 1
}

rule() { printf '%s\n' "${C_DIM}────────────────────────────────────────────────────────────${C_RST}" >&2; }

# ── preconditions ─────────────────────────────────────────────────────────────

need_cmd() {
    local cmd="$1" fix="${2:-}"
    command -v "$cmd" >/dev/null 2>&1 || die "\`$cmd\` is not installed." "fix: $fix"
}

# The single most important check in the rig. Without BlackHole every "run"
# plays audio out of the speakers and records the room, and the numbers are
# fiction. Nothing downstream may proceed without it.
require_blackhole() {
    if ! SwitchAudioSource -a -t input 2>/dev/null | grep -qi "$BLACKHOLE_MATCH"; then
        die "BlackHole is not installed (no input device matching '$BLACKHOLE_MATCH')." \
            "This is not optional. Without it, playback goes to the speakers," \
            "the app records the room, and every number the rig produces is fake." \
            "" \
            "fix (needs your admin password, then a REBOOT):" \
            "  brew install --cask blackhole-2ch" \
            "  sudo reboot" \
            "" \
            "after the reboot, confirm with:" \
            "  SwitchAudioSource -a -t input | grep BlackHole"
    fi
}

# ── device resolution ─────────────────────────────────────────────────────────

# Exact CoreAudio name of the BlackHole input, as SwitchAudioSource spells it.
blackhole_input_name() {
    local n
    n="$(SwitchAudioSource -a -t input 2>/dev/null | grep -i "$BLACKHOLE_MATCH" | head -1 || true)"
    [[ -n "$n" ]] || die "No input device matching '$BLACKHOLE_MATCH'." "run: rig/setup.sh"
    printf '%s' "$n"
}

# ffmpeg's audiotoolbox OUTPUT muxer indexes the *whole* CoreAudio device list
# (inputs and outputs interleaved), so the index is never guessable and must be
# read back from ffmpeg itself. A wrong-but-valid index plays to the speakers
# and produces a silent, plausible-looking run — hence the hard failure.
#
# 50ms of silence is pushed to the default device as a side effect of listing;
# that is the cheapest way to make ffmpeg emit the table.
at_output_index() {
    local match="${1:-$BLACKHOLE_MATCH}" listing idx
    listing="$(ffmpeg -hide_banner -loglevel info \
                 -f lavfi -i "anullsrc=r=48000:cl=stereo" -t 0.05 \
                 -f audiotoolbox -list_devices true - 2>&1 || true)"
    # `|| true` is load-bearing. Under `set -euo pipefail` a grep that matches
    # nothing makes this assignment non-zero, which aborts the script INSTANTLY
    # — before the die() below can explain what went wrong. Silent exit is the
    # one failure mode this rig must never have.
    idx="$(printf '%s\n' "$listing" \
            | sed -n 's/^\[AudioToolbox @ [^]]*\] *\[\([0-9]\{1,\}\)\] *\(.*\)$/\1|\2/p' \
            | grep -i "$match" | head -1 | cut -d'|' -f1 || true)"
    if [[ -z "$idx" ]]; then
        die "ffmpeg's audiotoolbox muxer cannot see a device matching '$match'." \
            "devices ffmpeg can see:" \
            "$(printf '%s\n' "$listing" | sed -n 's/^\[AudioToolbox @ [^]]*\] *\(\[[0-9]\)/  \1/p' | tr '\n' '~' | sed 's/~/ | /g')" \
            "fix: install BlackHole (see rig/setup.sh) and re-run."
    fi
    printf '%s' "$idx"
}

# avfoundation INPUT indices are a different, shorter list than the audiotoolbox
# output list. Never reuse one for the other.
av_input_index() {
    local match="${1:-$BLACKHOLE_MATCH}" listing idx
    listing="$(ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 || true)"
    idx="$(printf '%s\n' "$listing" \
            | sed -n '/AVFoundation audio devices/,$p' \
            | sed -n 's/^\[AVFoundation indev @ [^]]*\] *\[\([0-9]\{1,\}\)\] *\(.*\)$/\1|\2/p' \
            | grep -i "$match" | head -1 | cut -d'|' -f1 || true)"   # see note in at_output_index
    [[ -n "$idx" ]] || die "avfoundation cannot see an audio input matching '$match'." \
                           "fix: install BlackHole (see rig/setup.sh) and re-run."
    printf '%s' "$idx"
}

# Set the system input and *prove it took*. SwitchAudioSource exits 0 even when
# CoreAudio silently refuses, so the read-back is the only real check.
set_input_device_or_die() {
    local want="$1" got
    SwitchAudioSource -t input -s "$want" >/dev/null 2>&1 || true
    got="$(SwitchAudioSource -c -t input 2>/dev/null || true)"
    [[ "$got" == "$want" ]] || die "Input device did not switch." \
        "wanted: $want" "got:    ${got:-<none>}" \
        "fix: open System Settings › Sound › Input and pick $want by hand, then re-run."
}

assert_input_is_blackhole() {
    local got
    got="$(SwitchAudioSource -c -t input 2>/dev/null || true)"
    printf '%s' "$got" | grep -qi "$BLACKHOLE_MATCH" \
        || die "System input is '${got:-<none>}', not $BLACKHOLE_MATCH — this run would record the room." \
               "fix: rig/run_eval.sh sets this automatically; if it drifted mid-run, something else changed it."
}

# ── misc ──────────────────────────────────────────────────────────────────────

app_pid() { pgrep -x "$1" 2>/dev/null | head -1; }

require_running() {
    local proc="$1" human="$2" howto="$3"
    app_pid "$proc" >/dev/null || die "$human is not running." "fix: $howto"
}

timestamp_slug() { date +%Y%m%d-%H%M%S; }

# uv keeps its caches in ~/.cache/uv, deliberately outside ~/Documents:
# iCloud evicts files inside Documents and CPython then skips the .pth files
# that make an environment importable, which breaks venvs there in ways that
# look like missing packages.
uv_run_script() {
    local script="$1"; shift
    need_cmd uv "curl -LsSf https://astral.sh/uv/install.sh | sh"
    uv run --quiet --script "$script" "$@"
}
