#!/usr/bin/env bash
#
# rig/run_eval.sh — play the frozen corpus into an app and collect its transcripts.
#
# ONE CLIP, START TO FINISH
#
#   assert system input is BlackHole      ← or the app is hearing the room
#   mark the app's transcript store       ← so "newest row" can be proven fresh
#   start the verification tap recording  ← independent witness of what was sent
#   press and HOLD the app's hotkey
#   play the clip into BlackHole by device index
#   release the hotkey, wait for the app to settle
#   read back exactly one new transcript, asserting the device again
#   fingerprint the tap
#
# Playback uses ffmpeg's audiotoolbox muxer with -audio_device_index, which
# targets a chosen CoreAudio device WITHOUT touching the system default output.
# That matters: changing the default output mid-run would silence the machine and
# would also be a global side effect the rig has no business causing.
#
# usage:
#   rig/run_eval.sh --app quill
#   rig/run_eval.sh --app flow --clips 5
#   rig/run_eval.sh --app flow --only 1089-134686-0000
#   rig/run_eval.sh --preflight --app quill     # one clip, verify the path, stop

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

APP=""
LIMIT=0
ONLY=""
PTT_KEY=""
LEAD=0.4            # hotkey down → playback starts (app must be capturing by then)
TAIL=0.8            # playback ends → hotkey up (don't clip the last word)
SETTLE=""           # hotkey up → read transcript (cloud round trip for Flow)
GAP=1.5             # between clips, so the app fully resets
TAP=1
PREFLIGHT=0
MAX_FAILURES=5
EXPECT_DEVICE=""
RUN_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)            APP="${2:?}"; shift 2 ;;
        --clips)          LIMIT="${2:?}"; shift 2 ;;
        --only)           ONLY="${2:?}"; shift 2 ;;
        --ptt-key)        PTT_KEY="${2:?}"; shift 2 ;;
        --lead)           LEAD="${2:?}"; shift 2 ;;
        --tail)           TAIL="${2:?}"; shift 2 ;;
        --settle)         SETTLE="${2:?}"; shift 2 ;;
        --gap)            GAP="${2:?}"; shift 2 ;;
        --no-tap)         TAP=0; shift ;;
        --preflight)      PREFLIGHT=1; shift ;;
        --max-failures)   MAX_FAILURES="${2:?}"; shift 2 ;;
        --expect-device)  EXPECT_DEVICE="${2:?}"; shift 2 ;;
        --run-id)         RUN_ID="${2:?}"; shift 2 ;;
        -h|--help)        sed -n '2,28p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" "see: rig/run_eval.sh --help" ;;
    esac
done

case "$APP" in
    flow|quill) ;;
    "") die "--app is required" "usage: rig/run_eval.sh --app flow|quill" ;;
    *)  die "--app must be 'flow' or 'quill', got '$APP'" ;;
esac

# ── per-app knobs ─────────────────────────────────────────────────────────────
#
# Quill's push-to-talk is Right Option (keycode 61) — see HotkeyBinding.rightOption
# in Sources/QuillKit/Hotkey/HotkeyBinding.swift.
#
# Flow ships on Fn, which is the one modifier macOS handles below the event-tap
# layer and therefore the one this rig cannot reliably synthesise. Rebind Flow to
# a right-hand modifier and pass --ptt-key. This is called out in rig/README.md.

if [[ "$APP" == "quill" ]]; then
    PTT_KEY="${PTT_KEY:-61}"
    SETTLE="${SETTLE:-4}"
    PROC="Quill"
    PROC_FIX="open $QUILL_APP"
    READER="$RIG_DIR/read_quill.sh"
else
    PTT_KEY="${PTT_KEY:-63}"
    SETTLE="${SETTLE:-8}"
    PROC="Wispr Flow"
    PROC_FIX="open -a 'Wispr Flow'  (and sign in — it is cloud-only)"
    READER="$RIG_DIR/read_flow.sh"
    if [[ "$PTT_KEY" == "63" ]]; then
        warn "Flow's push-to-talk is set to Fn (keycode 63)."
        warn "macOS handles Fn below the layer this rig can post to, so a synthetic"
        warn "hold usually does NOT reach Flow. If the preflight produces no"
        warn "transcript, rebind Flow to Right Command in its settings and re-run"
        warn "with:  --ptt-key 54"
    fi
fi

PTT="$BIN_DIR/ptt"
EXPECT_DEVICE="${EXPECT_DEVICE:-$BLACKHOLE_MATCH}"

# ── preconditions ─────────────────────────────────────────────────────────────

need_cmd ffmpeg "brew install ffmpeg"
need_cmd SwitchAudioSource "brew install switchaudio-osx"
[[ -f "$MANIFEST" ]] || die "no frozen corpus manifest" "fix: rig/fetch_corpus.sh"
[[ -d "$CLIPS_DIR" ]] || die "no clips built" "fix: rig/fetch_corpus.sh"

if [[ ! -x "$PTT" ]]; then
    info "building the push-to-talk helper…"
    mkdir -p "$BIN_DIR"
    xcrun swiftc -O -o "$PTT" "$RIG_DIR/tools/ptt.swift" \
        || die "could not build rig/tools/ptt.swift" "fix: xcode-select --install"
fi
"$PTT" check >/dev/null || exit 1

require_blackhole
require_running "$PROC" "$([[ $APP == flow ]] && echo 'Wispr Flow' || echo Quill)" "$PROC_FIX"

BH_NAME="$(blackhole_input_name)"
set_input_device_or_die "$BH_NAME"
AT_INDEX="$(at_output_index "$BLACKHOLE_MATCH")"
if (( TAP )); then AV_INDEX="$(av_input_index "$BLACKHOLE_MATCH")"; fi

ok "input device      : $BH_NAME"
ok "playback index    : $AT_INDEX (ffmpeg audiotoolbox output)"
(( TAP )) && ok "tap input index   : $AV_INDEX (ffmpeg avfoundation input)"
ok "push-to-talk      : keycode $PTT_KEY"

# ── run directory ─────────────────────────────────────────────────────────────

RUN_ID="${RUN_ID:-$(timestamp_slug)-$APP}"
RUN_DIR="$OUT_DIR/$RUN_ID"
mkdir -p "$RUN_DIR/tap"
RESULTS="$RUN_DIR/results.jsonl"
FPRINTS="$RUN_DIR/tap_fingerprints.jsonl"
: > "$RESULTS"; : > "$FPRINTS"

python3 - "$RUN_DIR/meta.json" "$APP" "$RUN_ID" "$BH_NAME" "$AT_INDEX" "$PTT_KEY" \
         "$LEAD" "$TAIL" "$SETTLE" <<'PY'
import json, platform, subprocess, sys, datetime
p = sys.argv
def ver(cmd):
    try: return subprocess.run(cmd, capture_output=True, text=True).stdout.splitlines()[0]
    except Exception: return "unknown"
json.dump({
    "meta_path": p[1], "app": p[2], "run_id": p[3], "input_device": p[4],
    "playback_device_index": int(p[5]),
    # A chord like "control+shift+d" is a valid trigger, not just a bare keycode.
    "ptt_keycode": int(p[6]) if p[6].isdigit() else p[6],
    "lead_sec": float(p[7]), "tail_sec": float(p[8]), "settle_sec": float(p[9]),
    "started_utc": datetime.datetime.now(datetime.UTC).isoformat(),
    "host": platform.node(), "macos": platform.mac_ver()[0], "arch": platform.machine(),
    "ffmpeg": ver(["ffmpeg", "-version"]),
}, open(p[1], "w"), indent=2)
PY

# A stuck modifier is the worst thing this script could leave behind — the user
# would find every keystroke silently modified. Release on ANY exit path.
cleanup() {
    "$PTT" up "$PTT_KEY" 2>/dev/null || true
    [[ -n "${TAP_PID:-}" ]] && kill "$TAP_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── the loop ──────────────────────────────────────────────────────────────────

MARK="$RUN_DIR/.mark"
n=0; done_n=0; failed_n=0

run_clip() {
    local clip_id="$1" dur="$2"
    local wav="$CLIPS_DIR/$clip_id.wav"
    [[ -f "$wav" ]] || die "clip missing: $wav" "fix: rig/fetch_corpus.sh"

    # Guard 1 of 2: the device must be right going in.
    assert_input_is_blackhole

    "$READER" --mark "$MARK" >/dev/null 2>&1 </dev/null \
        || die "could not snapshot $APP's transcript store before the clip" \
               "Without a marker there is no way to prove the transcript is new."

    TAP_PID=""
    local tap_wav="$RUN_DIR/tap/$clip_id.wav"
    if (( TAP )); then
        local tap_dur
        tap_dur="$(python3 -c "print(f'{$dur + $LEAD + $TAIL + 1.0:.2f}')")"
        ffmpeg -hide_banner -nostdin -v error -y \
            -f avfoundation -i ":$AV_INDEX" -t "$tap_dur" \
            -ar 48000 -ac 2 -c:a pcm_s16le "$tap_wav" >/dev/null 2>&1 &
        TAP_PID=$!
        sleep 0.5   # let CoreAudio actually open the input before anything plays
    fi

    local t0 t1
    t0="$(python3 -c 'import time; print(time.time())')"

    "$PTT" down "$PTT_KEY" </dev/null
    sleep "$LEAD"

    # Re-resolve by NAME every clip. CoreAudio indices are positional, so a pair
    # of Bluetooth earbuds connecting mid-run renumbers the list and playback
    # silently goes to the wrong device. That killed a 50-clip run at clip 20
    # after 17 good clips, and the cached index was the whole cause.
    local index
    index="$(at_output_index "$BLACKHOLE_MATCH")"
    if [[ -z "$index" ]]; then
        "$PTT" up "$PTT_KEY"
        die "the loopback device disappeared from the audio device list" \
            "Playing into the wrong device produces a plausible WER from silence." \
            "fix: reconnect BlackHole, or disconnect whatever hardware displaced it."
    fi
    if [[ "$index" != "$AT_INDEX" ]]; then
        warn "loopback device moved from index $AT_INDEX to $index — following it"
        AT_INDEX="$index"
    fi

    ffmpeg -hide_banner -nostdin -v error -i "$wav" \
        -f audiotoolbox -audio_device_index "$index" - >/dev/null 2>&1 \
        || { "$PTT" up "$PTT_KEY"; die "playback to device index $index failed" \
                "The device exists but would not accept audio." \
                "fix: check nothing else has exclusive use of it."; }

    sleep "$TAIL"
    "$PTT" up "$PTT_KEY" </dev/null
    t1="$(python3 -c 'import time; print(time.time())')"

    if [[ -n "$TAP_PID" ]]; then wait "$TAP_PID" 2>/dev/null || true; TAP_PID=""; fi

    # Poll for the transcript rather than sleeping a fixed time and looking once.
    #
    # A fixed settle has to be wrong in one direction or the other: too short and
    # a slow finalisation is scored as "the app produced nothing", too long and
    # every one of fifty clips pays for the worst case. It was too short — six
    # clips in thirty-five were declared failures while their transcripts were
    # sitting in Quill's history, written a moment after the reader gave up.
    #
    # SETTLE is now a floor for the first look and a deadline for giving up, and
    # a fast app finishes early instead of waiting to be asked again.
    local deadline waited
    deadline="$(python3 -c "print($SETTLE * 4)")"
    waited=0
    while :; do
        sleep 0.25
        waited="$(python3 -c "print(round($waited + 0.25, 2))")"
        "$READER" --since "$MARK" --json --expect-device "$EXPECT_DEVICE" \
            >/dev/null 2>/dev/null </dev/null && break
        if (( $(python3 -c "print(1 if $waited >= $deadline else 0)") )); then break; fi
    done

    # Guard 2 of 2: nothing changed the device while we were playing.
    assert_input_is_blackhole

    local rec fp_json="{}" fp_ok=1
    if (( TAP )); then
        if ! fp_json="$(python3 "$RIG_DIR/tools/fingerprint.py" "$tap_wav" --json 2>/dev/null)"; then
            fp_ok=0
        fi
        # Values go in as argv, never interpolated into the program text — a
        # transcript containing a quote should not be able to rewrite this script.
        python3 -c '
import json, sys
raw, clip = sys.argv[1], sys.argv[2]
try:
    d = json.loads(raw) if raw.strip() else {}
except Exception:
    d = {"ok": False, "reason": "unparsable_fingerprint"}
d["clip_id"] = clip
print(json.dumps(d))' "$fp_json" "$clip_id" >> "$FPRINTS"

        if (( ! fp_ok )); then
            die "the verification tap for $clip_id contains no audio." \
                "Nothing reached BlackHole, so the app heard nothing — whatever" \
                "transcript appears now did not come from this clip." \
                "This invalidates the run. Do not continue and do not score it." \
                "fix: rig/setup.sh, then confirm BlackHole is both the system input" \
                "     AND ffmpeg's playback target."
        fi
    fi

    if ! rec="$("$READER" --since "$MARK" --json --expect-device "$EXPECT_DEVICE" 2>"$RUN_DIR/.err" </dev/null)"; then
        warn "$clip_id: no valid transcript"
        sed 's/^/      /' "$RUN_DIR/.err" >&2
        python3 -c "
import json,sys
print(json.dumps({'clip_id':'$clip_id','app':'$APP','ok':False,
                  'error':open('$RUN_DIR/.err').read().strip()[:500]}))" >> "$RESULTS"
        return 1
    fi

    # `python3 - <<PY` takes the PROGRAM from stdin, so sys.stdin is already
    # consumed by the time the program runs — the transcript has to arrive as an
    # argument, not on a pipe.
    python3 - "$clip_id" "$APP" "$t0" "$t1" "$fp_json" "$rec" <<'PY' >> "$RESULTS"
import json, sys
clip_id, app = sys.argv[1], sys.argv[2]
t0, t1 = float(sys.argv[3]), float(sys.argv[4])
fp, rec = sys.argv[5], sys.argv[6]
d = json.loads(rec)
if app == "flow":
    raw, formatted = d.get("asrText") or "", d.get("formattedText") or ""
    latency = d.get("e2eLatency")
    extra = {"mic_device": d.get("micDevice"), "flow_duration": d.get("duration"),
             "num_words": d.get("numWords")}
else:
    # rawText ↔ Flow's asrText (accuracy), insertedText ↔ formattedText
    # (post-cleanup). Pairing them the other way round would put a cleaned
    # transcript in the accuracy column for one app and a raw one for the other.
    raw, formatted = d.get("text") or "", d.get("text_inserted") or ""
    latency = d.get("latency_ms")
    extra = {"time_to_first_word_ms": d.get("time_to_first_word_ms"),
             "final_to_inserted_ms": d.get("final_to_inserted_ms"),
             "used_thorough_cleanup": d.get("used_thorough_cleanup"),
             "quill_record_id": d.get("id"), "quill_date": d.get("date")}
try:
    extra["tap"] = json.loads(fp) if fp.strip() else None
except Exception:
    extra["tap"] = None
out = {"clip_id": clip_id, "app": app, "ok": True,
       "text_raw": raw, "text_formatted": formatted,
       "latency_ms": latency, "wall_hold_sec": round(t1 - t0, 3)}
out.update(extra)
print(json.dumps(out))
PY
    return 0
}

rule
say "${C_BLD}run${C_RST} $RUN_ID   app=${C_BLD}$APP${C_RST}   → $RUN_DIR"
rule

# The manifest is read on descriptor 3, and every child in `run_clip` is denied
# stdin, because this loop spawns processes that read it.
#
# On stdin, the symptom is not a clean failure. Clip one runs, some child
# swallows a byte or a line, and clip two arrives as "089-134686-0002" — the
# leading 1 eaten — which then fails as a missing file. Every clip after the
# first is either corrupted or skipped, and a 50-clip run silently becomes a
# 25-clip run that still prints "ok". That is the worst shape a measurement bug
# can take: it does not look like a bug, it looks like a result.
while IFS=$'\t' read -r clip_id speaker source_rel words duration text <&3; do
    [[ "$clip_id" == "clip_id" || "$clip_id" == \#* || -z "$clip_id" ]] && continue
    [[ -n "$ONLY" && "$clip_id" != "$ONLY" ]] && continue
    n=$((n + 1))
    (( LIMIT > 0 && n > LIMIT )) && break

    printf '%s[%2d] %-22s %5ss %s' "$C_DIM" "$n" "$clip_id" "$duration" "$C_RST" >&2
    if run_clip "$clip_id" "$duration"; then
        done_n=$((done_n + 1))
        printf '%s ok%s\n' "$C_GRN" "$C_RST" >&2
    else
        failed_n=$((failed_n + 1))
        # The first clip failing is never bad luck — it is a broken setup, and
        # continuing would just produce 50 identical failures.
        if (( n == 1 )); then
            # One retry before declaring the setup broken. An app launched
            # moments ago is running but not yet listening: Quill's event tap is
            # installed on a retry timer, so a run started four seconds after
            # `open` loses its first clip and then reports a permissions problem
            # that does not exist. Everything after the first clip is real
            # flakiness and still counts against MAX_FAILURES.
            warn "first clip produced nothing — waiting 5s and trying once more"
            sleep 5
            if run_clip "$clip_id" "$duration"; then
                failed_n=$((failed_n - 1))
                done_n=$((done_n + 1))
                printf '%s ok (on retry)%s\n' "$C_GRN" "$C_RST" >&2
                (( PREFLIGHT )) && break
                sleep "$GAP"
                continue
            fi
            die "the FIRST clip produced no transcript — this is a setup problem, not flakiness." \
                "Nothing further would succeed. Diagnose with:" \
                "  rig/setup.sh" \
                "  rig/run_eval.sh --app $APP --preflight" \
                "and check the app's push-to-talk key really is keycode $PTT_KEY."
        fi
        if (( failed_n > MAX_FAILURES )); then
            die "$failed_n clips failed (limit $MAX_FAILURES) — stopping." \
                "Partial results are in $RESULTS but the run is not comparable."
        fi
    fi

    (( PREFLIGHT )) && break
    sleep "$GAP"
done 3< "$MANIFEST"

# A run that quietly covered less of the corpus than it claims is the failure
# this whole script exists to prevent, and it has happened: a child reading stdin
# ate manifest lines and a 50-clip run scored 25 while printing "ok" for every
# one of them. The fd-3 read above stops that particular cause; this stops any
# other cause from being silent.
if (( LIMIT == 0 )) && [[ -z "$ONLY" ]] && (( ! PREFLIGHT )); then
    expected="$(grep -cvE '^\s*(#|clip_id|$)' "$MANIFEST")"
    if (( n != expected )); then
        die "the loop saw $n clips but the manifest holds $expected." \
            "A partial run is not comparable to a full one, and the numbers in" \
            "$RESULTS must not be reported as a corpus score." \
            "This usually means a child process consumed the manifest on stdin."
    fi
fi

rm -f "$RUN_DIR/.mark" "$RUN_DIR/.err"

rule
ok "$done_n transcript(s) captured, $failed_n failed → $RUN_DIR"
if (( PREFLIGHT )); then
    say ""
    say "preflight only. The audio path and the hotkey both work for ${C_BLD}$APP${C_RST}."
    say "next: rig/run_eval.sh --app $APP"
else
    say ""
    say "next: rig/score.py --run out/$RUN_ID"
fi
