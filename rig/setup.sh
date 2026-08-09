#!/usr/bin/env bash
#
# rig/setup.sh — check every prerequisite and say exactly how to fix each gap.
#
# This never "mostly passes". Anything that would let a run produce numbers
# without real audio is a BLOCKER and exits non-zero. Things that only reduce
# confidence are WARNINGs. The distinction is the whole point: a rig that
# proceeds on a broken audio path will happily transcribe silence and report a
# WER, and that number is indistinguishable from a real one unless something
# stopped you first.
#
# usage:  rig/setup.sh [--quick]     (--quick skips the corpus file verification)

set -uo pipefail    # deliberately NOT -e: we want to collect every failure, not stop at the first
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
set +e

QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1

BLOCKERS=(); WARNINGS=()
block() { BLOCKERS+=("$1"); printf '%sBLOCK%s %s\n' "$C_RED" "$C_RST" "$1" >&2; shift; for l in "$@"; do printf '      %s\n' "$l" >&2; done; }
soft()  { WARNINGS+=("$1"); printf '%s warn%s %s\n' "$C_YEL" "$C_RST" "$1" >&2; shift; for l in "$@"; do printf '      %s\n' "$l" >&2; done; }
pass()  { printf '%s   ok%s %s\n' "$C_GRN" "$C_RST" "$1" >&2; }
head2() { printf '\n%s%s%s\n' "$C_BLD" "$1" "$C_RST" >&2; }

rule
say "${C_BLD}quill comparison rig — preflight${C_RST}"
say "${C_DIM}$(sw_vers -productName) $(sw_vers -productVersion) · $(uname -m) · $(date)${C_RST}"
rule

# ── 1. command line tools ─────────────────────────────────────────────────────

head2 "1. tools"

if command -v brew >/dev/null; then pass "homebrew $(brew --version | head -1 | awk '{print $2}')"
else soft "homebrew not found" "Most fixes below are brew commands." \
          "fix: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""; fi

if command -v ffmpeg >/dev/null; then
    pass "ffmpeg $(ffmpeg -version | head -1 | awk '{print $3}')"
    if ffmpeg -hide_banner -h muxer=audiotoolbox 2>&1 | grep -q audio_device_index; then
        pass "ffmpeg audiotoolbox muxer supports -audio_device_index"
    else
        block "this ffmpeg's audiotoolbox muxer has no -audio_device_index" \
              "Without it the rig cannot play into BlackHole without hijacking the" \
              "system default output." "fix: brew install ffmpeg"
    fi
else
    block "ffmpeg not installed" "fix: brew install ffmpeg"
fi

if command -v SwitchAudioSource >/dev/null; then pass "SwitchAudioSource"
else block "SwitchAudioSource not installed" \
           "Needed to set AND verify the system input device." \
           "fix: brew install switchaudio-osx"; fi

if command -v uv >/dev/null; then pass "uv $(uv --version | awk '{print $2}')"
else block "uv not installed" \
           "Needed for jiwer + the Whisper normaliser. pip3 is blocked by PEP 668" \
           "on this machine, and a venv under ~/Documents breaks because iCloud" \
           "evicts the .pth files CPython needs." \
           "fix: curl -LsSf https://astral.sh/uv/install.sh | sh"; fi

if xcrun --find swiftc >/dev/null 2>&1; then pass "swiftc (for the push-to-talk helper)"
else block "swiftc not available" "fix: xcode-select --install"; fi

# ── 2. audio routing ──────────────────────────────────────────────────────────

head2 "2. audio routing  ${C_DIM}(the part that decides if numbers are real)${C_RST}"

BH_OK=0
if SwitchAudioSource -a -t input 2>/dev/null | grep -qi "$BLACKHOLE_MATCH"; then
    BH_NAME="$(SwitchAudioSource -a -t input | grep -i "$BLACKHOLE_MATCH" | head -1)"
    pass "BlackHole input device present: $BH_NAME"
    BH_OK=1
else
    block "BlackHole is NOT installed" \
          "This is the blocker that matters most. Without a loopback device the" \
          "clips play out of the speakers, the app records the room through the" \
          "built-in mic, and every WER the rig reports is fiction." \
          "" \
          "fix — YOU must run this, it needs an admin password and a reboot:" \
          "    brew install --cask blackhole-2ch" \
          "    sudo reboot" \
          "" \
          "then re-run rig/setup.sh"
fi

if (( BH_OK )); then
    AT_LIST="$(ffmpeg -hide_banner -loglevel info -f lavfi -i "anullsrc=r=48000:cl=stereo" \
                -t 0.05 -f audiotoolbox -list_devices true - 2>&1)"
    AT_IDX="$(printf '%s\n' "$AT_LIST" \
               | sed -n 's/^\[AudioToolbox @ [^]]*\] *\[\([0-9]\{1,\}\)\] *\(.*\)$/\1|\2/p' \
               | grep -i "$BLACKHOLE_MATCH" | head -1 | cut -d'|' -f1)"
    if [[ -n "$AT_IDX" ]]; then pass "ffmpeg playback index for BlackHole: $AT_IDX"
    else block "ffmpeg's audiotoolbox muxer cannot see BlackHole" \
               "It is installed but ffmpeg does not list it. A reboot after install" \
               "is usually what is missing." "fix: sudo reboot"; fi

    AV_IDX="$(ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 \
               | sed -n '/AVFoundation audio devices/,$p' \
               | sed -n 's/^\[AVFoundation indev @ [^]]*\] *\[\([0-9]\{1,\}\)\] *\(.*\)$/\1|\2/p' \
               | grep -i "$BLACKHOLE_MATCH" | head -1 | cut -d'|' -f1)"
    if [[ -n "$AV_IDX" ]]; then pass "ffmpeg verification-tap index for BlackHole: $AV_IDX"
    else soft "avfoundation cannot see BlackHole as an input" \
              "The verification tap will not work; runs would be unwitnessed." \
              "fix: sudo reboot, then re-run rig/setup.sh"; fi
fi

CUR_IN="$(SwitchAudioSource -c -t input 2>/dev/null)"
printf '%s      current system input: %s%s\n' "$C_DIM" "${CUR_IN:-unknown}" "$C_RST" >&2
printf '%s      (run_eval.sh sets and re-asserts this itself — no action needed)%s\n' "$C_DIM" "$C_RST" >&2

# ── 3. permissions ────────────────────────────────────────────────────────────

head2 "3. permissions  ${C_DIM}(granted to your TERMINAL, not to the scripts)${C_RST}"

PTT="$BIN_DIR/ptt"
if [[ ! -x "$PTT" ]]; then
    mkdir -p "$BIN_DIR"
    if xcrun swiftc -O -o "$PTT" "$RIG_DIR/tools/ptt.swift" 2>/dev/null; then
        pass "built the push-to-talk helper (rig/bin/ptt)"
    else
        block "could not build rig/tools/ptt.swift" "fix: xcode-select --install"
    fi
else
    pass "push-to-talk helper present (rig/bin/ptt)"
fi

if [[ -x "$PTT" ]]; then
    if "$PTT" check >/dev/null 2>&1; then
        pass "Accessibility granted (this terminal can post key events)"
        if "$PTT" selftest >/dev/null 2>&1; then
            pass "synthetic push-to-talk verified end to end (posted and observed)"
        else
            block "synthetic key events are not being delivered" \
                  "The rig cannot hold either app's hotkey, so no clip would record." \
                  "Usual cause: Secure Input is on (a focused password field, or a" \
                  "terminal with Secure Keyboard Entry enabled)." \
                  "fix: close password prompts; in Terminal.app uncheck" \
                  "     Terminal › Secure Keyboard Entry. Then: rig/bin/ptt selftest"
        fi
    else
        block "Accessibility is NOT granted to this terminal" \
              "Without it the rig cannot press either app's push-to-talk key." \
              "fix: System Settings › Privacy & Security › Accessibility" \
              "     → add your terminal (Ghostty), enable it," \
              "     → then FULLY QUIT and reopen the terminal (the grant is read at launch)."
    fi
fi

TAPTEST="$(mktemp -t taptest).wav"
if ffmpeg -hide_banner -nostdin -v error -y -f avfoundation -i ":${AV_IDX:-0}" -t 0.4 \
        -ar 48000 -ac 2 -c:a pcm_s16le "$TAPTEST" >/dev/null 2>&1 && [[ -s "$TAPTEST" ]]; then
    pass "Microphone permission granted (this terminal can record)"
else
    block "this terminal cannot record audio" \
          "The verification tap needs it — without the tap there is no proof the" \
          "apps received the clips." \
          "fix: System Settings › Privacy & Security › Microphone → enable your terminal."
fi
rm -f "$TAPTEST"

# ── 4. scoring stack ──────────────────────────────────────────────────────────

head2 "4. scoring"

if command -v uv >/dev/null; then
    if "$RIG_DIR/score.py" selftest >/dev/null 2>&1; then
        pass "jiwer + EnglishTextNormalizer working (score.py selftest passes)"
    else
        block "score.py selftest FAILED" \
              "Either the deps will not resolve or the normaliser is missing." \
              "Scoring without the normaliser measures punctuation, not accuracy." \
              "fix: rig/score.py selftest    (read the error it prints)"
    fi
fi

# ── 5. the apps ───────────────────────────────────────────────────────────────

head2 "5. apps under test"

if [[ -d "$FLOW_APP" ]]; then
    FV="$(defaults read "$FLOW_APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?')"
    pass "Wispr Flow installed (v$FV)"
    if pgrep -x "Wispr Flow" >/dev/null; then pass "Wispr Flow is running"
    else soft "Wispr Flow is not running" "fix: open -a 'Wispr Flow'"; fi

    if [[ -f "$FLOW_DB" ]]; then
        NF="$(sqlite3 "$FLOW_DB" "SELECT COUNT(*) FROM History WHERE status='formatted';" 2>/dev/null || echo 0)"
        LAST="$(sqlite3 "$FLOW_DB" "SELECT COALESCE(timestamp,'') FROM History WHERE status IS NOT NULL AND TRIM(status)!='' ORDER BY timestamp DESC LIMIT 1;" 2>/dev/null)"
        LASTTXT="$(sqlite3 "$FLOW_DB" "SELECT COALESCE(LENGTH(asrText),0) FROM History WHERE status IS NOT NULL AND TRIM(status)!='' ORDER BY timestamp DESC LIMIT 1;" 2>/dev/null || echo 0)"
        pass "flow.sqlite readable ($NF completed transcripts, newest $LAST)"
        if [[ "${LASTTXT:-0}" -eq 0 ]]; then
            soft "Flow's most recent dictation produced NO text" \
                 "That is what a signed-OUT Flow looks like: it captures audio and" \
                 "stores an empty row. Flow is cloud-only and transcribes nothing" \
                 "while signed out." \
                 "fix — YOU must do this, it needs your account:" \
                 "  1. open Wispr Flow and sign in" \
                 "  2. dictate one sentence by hand" \
                 "  3. confirm with: rig/read_flow.sh --latest --expect-device ''" \
                 "     if it shows your words, Flow is ready."
        else
            pass "Flow's most recent dictation produced text (looks signed in)"
        fi
    else
        soft "no flow.sqlite yet" "fix: open Flow, sign in, dictate once."
    fi
else
    block "Wispr Flow is not installed at $FLOW_APP" \
          "fix: download it from wisprflow.ai and sign in (it is cloud-only)."
fi

if [[ -d "$QUILL_APP" ]]; then
    pass "Quill built at $QUILL_APP"
    if pgrep -x "Quill" >/dev/null; then pass "Quill is running"
    else soft "Quill is not running" "fix: open $QUILL_APP"; fi
    if [[ -f "$QUILL_HISTORY" ]]; then
        pass "Quill history present ($QUILL_HISTORY)"
    else
        soft "Quill has no history.json yet" \
             "The rig assumes ~/Library/Application Support/Quill/history.json:" \
             "a newest-first array of records with .text and .timeline." \
             "fix: dictate once in Quill, then: rig/read_quill.sh --probe"
    fi
else
    soft "Quill is not built yet at $QUILL_APP" \
         "Expected while Quill is still being written." \
         "fix: Scripts/build.sh"
fi

# ── 6. corpus ─────────────────────────────────────────────────────────────────

head2 "6. corpus"

if [[ -f "$MANIFEST" ]]; then
    NC="$(grep -vc '^#\|^clip_id' "$MANIFEST" | tr -d ' ')"
    pass "frozen manifest present ($NC utterances)"
    if [[ -f "$MANIFEST.sha256" ]]; then
        if ( cd "$RIG_DIR" && shasum -a 256 -c "$(basename "$MANIFEST").sha256" >/dev/null 2>&1 ); then
            pass "manifest matches its checksum (eval set unchanged)"
        else
            block "corpus_manifest.tsv has changed since it was frozen" \
                  "Results from before and after this change are not comparable." \
                  "fix: git checkout rig/corpus_manifest.tsv" \
                  "  or: rig/fetch_corpus.sh --refreeze   (deliberately re-baselining)"
        fi
    fi
    NW="$(ls "$CLIPS_DIR"/*.wav 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$NW" == "$NC" ]]; then
        pass "$NW normalised clips built"
        if (( ! QUICK )); then
            if "$RIG_DIR/fetch_corpus.sh" --verify >/dev/null 2>&1; then
                pass "all clips verified (48kHz stereo s16, silent 1s lead, audible, no clipping)"
            else
                block "clip verification FAILED" "fix: rm -rf rig/audio/clips && rig/fetch_corpus.sh"
            fi
        fi
    else
        block "expected $NC clips, found $NW" "fix: rig/fetch_corpus.sh"
    fi
else
    block "no corpus" "fix: rig/fetch_corpus.sh"
fi

# ── verdict ───────────────────────────────────────────────────────────────────

rule
if (( ${#BLOCKERS[@]} )); then
    say "${C_RED}${C_BLD}NOT READY${C_RST} — ${#BLOCKERS[@]} blocker(s):"
    for b in "${BLOCKERS[@]}"; do say "  ✗ $b"; done
    (( ${#WARNINGS[@]} )) && { say ""; say "plus ${#WARNINGS[@]} warning(s):"; for w in "${WARNINGS[@]}"; do say "  · $w"; done; }
    say ""
    say "Fix the blockers above. Do NOT run rig/run_eval.sh until this passes —"
    say "a run on a broken audio path still produces a number, and that number is a lie."
    rule
    exit 1
fi

if (( ${#WARNINGS[@]} )); then
    say "${C_YEL}${C_BLD}READY, with ${#WARNINGS[@]} warning(s)${C_RST}"
    for w in "${WARNINGS[@]}"; do say "  · $w"; done
    say ""
    say "The audio path and permissions are sound. The warnings above are things"
    say "you still have to do by hand (sign in, launch an app) — run_eval.sh will"
    say "stop with a clear message if any of them actually bite."
else
    say "${C_GRN}${C_BLD}READY${C_RST} — every check passed."
fi
say ""
say "next:  rig/run_eval.sh --app quill --preflight"
rule
exit 0
