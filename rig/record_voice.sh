#!/usr/bin/env bash
#
# rig/record_voice.sh — record the spoken corpus, one sentence at a time.
#
# LibriSpeech proves an app can transcribe 19th-century audiobook prose read by
# a stranger. It says nothing about Roman's voice saying "Firestore" or
# "Craigieburn". This builds the second corpus: same pipeline, same scoring, his
# words, his microphone, his room.
#
# The output is deliberately identical in shape to the LibriSpeech corpus —
# 48kHz stereo pcm_s16le, 1s silent lead, 0.5s tail, same loudness targets, and
# a manifest with the same columns — so run_eval.sh and score.py consume it with
# no special cases.
#
# HOW IT FEELS
#   A sentence appears. Press ENTER. Speak it. It stops on its own when you stop
#   talking. It plays back, you keep it or redo it. Next sentence.
#   Ctrl-C is safe at any point; finished clips are already written and the
#   session resumes where it left off.
#
# usage:
#   rig/record_voice.sh                       # start or resume the default session
#   rig/record_voice.sh --session roman-2     # a separate take
#   rig/record_voice.sh --manual              # press ENTER to stop instead of auto
#   rig/record_voice.sh --redo 7              # re-record just line 7
#   rig/record_voice.sh --verify              # check what has been recorded

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

SCRIPT_FILE="$RIG_DIR/sentences/roman_script.txt"
SESSION="roman"
MANUAL=0
REDO=""
VERIFY=0
TEST_FINALISE=0
TF_IN=""; TF_OUT=""
MAX_SEC=30
SILENCE_STOP=1.4        # seconds of quiet after speech before it cuts
LEAD_SILENCE=1.0
TAIL_SILENCE=0.5
RMS_TARGET_DBFS=-20.0
PEAK_CEIL_DBFS=-1.0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --session)  SESSION="${2:?}"; shift 2 ;;
        --script)   SCRIPT_FILE="${2:?}"; shift 2 ;;
        --manual)   MANUAL=1; shift ;;
        --redo)     REDO="${2:?}"; shift 2 ;;
        --verify)   VERIFY=1; shift ;;
        --max-sec)  MAX_SEC="${2:?}"; shift 2 ;;
        # Runs the raw→corpus-shaped conversion on a file instead of a live
        # recording, so the audio path can be tested without a microphone.
        --test-finalise) TEST_FINALISE=1; TF_IN="${2:?}"; TF_OUT="${3:?}"; shift 3 ;;
        -h|--help)  sed -n '2,28p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" "see: rig/record_voice.sh --help" ;;
    esac
done

need_cmd ffmpeg "brew install ffmpeg"
[[ -f "$SCRIPT_FILE" ]] || die "no sentence script at $SCRIPT_FILE"

VOICE_DIR="$AUDIO_DIR/voice/$SESSION"
CLIPS="$VOICE_DIR/clips"
VMANIFEST="$VOICE_DIR/manifest.tsv"
mkdir -p "$CLIPS"

# ── the sentences ─────────────────────────────────────────────────────────────

SENTENCES=()
while IFS= read -r line; do
    [[ -z "${line// }" || "$line" == \#* ]] && continue
    SENTENCES+=("$line")
done < "$SCRIPT_FILE"
TOTAL=${#SENTENCES[@]}
(( TOTAL > 0 )) || die "no sentences in $SCRIPT_FILE"

clip_id_for() { printf 'voice-%s-%03d' "$SESSION" "$1"; }

if (( VERIFY )); then
    have=0
    for ((i = 1; i <= TOTAL; i++)); do
        [[ -f "$CLIPS/$(clip_id_for "$i").wav" ]] && have=$((have + 1))
    done
    say "session $SESSION: $have / $TOTAL recorded  ($VOICE_DIR)"
    [[ -f "$VMANIFEST" ]] && say "manifest: $VMANIFEST"
    exit 0
fi

# ── input device ──────────────────────────────────────────────────────────────
#
# The opposite rule from run_eval.sh applies here: this corpus is Roman's actual
# voice through an actual microphone, so BlackHole is WRONG. A loopback device
# selected here would record a silent session that looks fine until scoring.

CUR_IN="$(SwitchAudioSource -c -t input 2>/dev/null || echo "")"
if printf '%s' "$CUR_IN" | grep -qi "$BLACKHOLE_MATCH"; then
    die "the system input is $CUR_IN — a loopback device, not a microphone." \
        "You would record 30 sentences of silence." \
        "fix: System Settings › Sound › Input → choose your real microphone," \
        "     or: SwitchAudioSource -t input -s 'MacBook Air Microphone'"
fi

# `|| true`: ffmpeg always exits non-zero when listing devices, and under
# `set -euo pipefail` that would kill the script here with no message at all.
AV_IDX="$(ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 \
           | sed -n '/AVFoundation audio devices/,$p' \
           | sed -n 's/^\[AVFoundation indev @ [^]]*\] *\[\([0-9]\{1,\}\)\] *\(.*\)$/\1|\2/p' \
           | head -1 | cut -d'|' -f1 || true)"
[[ -n "$AV_IDX" ]] || die "ffmpeg cannot see any audio input device"

BYTES_PER_SEC=96000      # 48000 Hz × 1 channel × 2 bytes, the raw capture format

# ── noise calibration ─────────────────────────────────────────────────────────
#
# Thresholds are measured in Roman's room rather than hardcoded, because a fixed
# dBFS gate that works in a quiet room clips words in a noisy one and never
# triggers with a distant mic.

calibrate() {
    local raw="$VOICE_DIR/.noise.raw"
    ffmpeg -hide_banner -nostdin -v error -y -f avfoundation -i ":$AV_IDX" \
        -t 1.5 -ar 48000 -ac 1 -f s16le "$raw" >/dev/null 2>&1 || true
    python3 -c "
import array, math, sys
try:
    a = array.array('h'); a.frombytes(open('$raw','rb').read())
except Exception:
    print('300 900'); sys.exit()
if not len(a): print('300 900'); sys.exit()
rms = math.sqrt(sum(x*x for x in a)/len(a))
# speech gate well above the floor, silence gate just above it
print(f'{max(rms*3.5, 250):.0f} {max(rms*1.8, 120):.0f}')"
    rm -f "$raw"
}

# ── one recording ─────────────────────────────────────────────────────────────
#
# ffmpeg writes raw s16le at a constant byte rate, so "how loud were the last
# 1.2 seconds" is just a tail read at a fixed offset. That is what makes
# auto-stop possible without a VAD library.

record_one() {
    local raw="$1"
    rm -f "$raw"
    ffmpeg -hide_banner -nostdin -v error -y -f avfoundation -i ":$AV_IDX" \
        -t "$MAX_SEC" -ar 48000 -ac 1 -f s16le "$raw" >/dev/null 2>&1 &
    local pid=$!
    local started=0 quiet_since="" t0
    t0="$(python3 -c 'import time; print(time.time())')"

    while kill -0 "$pid" 2>/dev/null; do
        if (( MANUAL )); then
            if read -r -t 0.2 _ </dev/tty 2>/dev/null; then break; fi
        else
            # ENTER still works as an override in auto mode.
            if read -r -t 0.2 _ </dev/tty 2>/dev/null; then break; fi
        fi
        (( MANUAL )) && continue
        [[ -f "$raw" ]] || continue

        local state
        state="$(python3 - "$raw" "$SPEECH_GATE" "$SILENCE_GATE" "$BYTES_PER_SEC" <<'PY'
import array, math, os, sys
raw, speech_gate, silence_gate, bps = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4])
size = os.path.getsize(raw)
win = int(bps * 1.0)
if size < win:
    print("short 0"); raise SystemExit
with open(raw, "rb") as fh:
    fh.seek(size - win)
    a = array.array("h"); a.frombytes(fh.read(win // 2 * 2))
rms = math.sqrt(sum(x * x for x in a) / len(a)) if len(a) else 0.0
print(("loud" if rms >= speech_gate else ("quiet" if rms <= silence_gate else "mid")), f"{rms:.0f}")
PY
)"
        local level="${state%% *}"
        case "$level" in
            loud)  started=1; quiet_since="" ;;
            quiet)
                if (( started )); then
                    if [[ -z "$quiet_since" ]]; then
                        quiet_since="$(python3 -c 'import time; print(time.time())')"
                    else
                        local elapsed
                        elapsed="$(python3 -c "print(1 if $(python3 -c 'import time; print(time.time())') - $quiet_since >= $SILENCE_STOP else 0)")"
                        (( elapsed )) && break
                    fi
                fi ;;
        esac
    done

    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    [[ -s "$raw" ]] || return 1
    return 0
}

# ── raw → corpus-shaped wav ───────────────────────────────────────────────────
#
# Same treatment as fetch_corpus.sh: trim the dead air the recording inevitably
# has at both ends, normalise to the same RMS target with the same peak ceiling,
# then pad to exactly 1s + 0.5s. Identical shape means identical handling later.

finalise() {
    local raw="$1" out="$2"
    local trimmed="$VOICE_DIR/.trim.wav"

    ffmpeg -hide_banner -nostdin -v error -y -f s16le -ar 48000 -ac 1 -i "$raw" \
        -af "silenceremove=start_periods=1:start_silence=0.1:start_threshold=-45dB:detection=rms,areverse,silenceremove=start_periods=1:start_silence=0.1:start_threshold=-45dB:detection=rms,areverse" \
        -c:a pcm_s16le "$trimmed" >/dev/null 2>&1 || return 1

    local dur
    dur="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$trimmed" 2>/dev/null || echo 0)"
    if (( $(python3 -c "print(1 if float('$dur') < 0.4 else 0)") )); then
        rm -f "$trimmed"; return 2      # nothing but silence was captured
    fi

    local chain="aformat=sample_fmts=fltp,aresample=48000,pan=stereo|c0=c0|c1=c0,aformat=sample_fmts=fltp"
    local stats rms peak gain
    stats="$(ffmpeg -hide_banner -nostdin -i "$trimmed" -af "${chain},astats=measure_perchannel=none" -f null - 2>&1)"
    rms="$(printf  '%s\n' "$stats" | sed -n 's/.*RMS level dB: *\(-*[0-9.]*\).*/\1/p'  | tail -1)"
    peak="$(printf '%s\n' "$stats" | sed -n 's/.*Peak level dB: *\(-*[0-9.]*\).*/\1/p' | tail -1)"
    [[ -n "$rms" && -n "$peak" ]] || { rm -f "$trimmed"; return 1; }
    gain="$(python3 -c "print(f'{min($RMS_TARGET_DBFS - ($rms), $PEAK_CEIL_DBFS - ($peak)):.2f}')")"

    ffmpeg -hide_banner -nostdin -v error -y \
        -f lavfi -t "$LEAD_SILENCE" -i "anullsrc=r=48000:cl=stereo" \
        -i "$trimmed" \
        -f lavfi -t "$TAIL_SILENCE" -i "anullsrc=r=48000:cl=stereo" \
        -filter_complex "\
[0:a]aformat=sample_fmts=fltp:channel_layouts=stereo,aresample=48000[lead];\
[1:a]${chain},volume=${gain}dB[sp];\
[2:a]aformat=sample_fmts=fltp:channel_layouts=stereo,aresample=48000[tail];\
[lead][sp][tail]concat=n=3:v=0:a=1[out]" \
        -map "[out]" -c:a pcm_s16le -ar 48000 -ac 2 "$out" >/dev/null 2>&1 || { rm -f "$trimmed"; return 1; }

    rm -f "$trimmed"
    return 0
}

write_manifest() {
    {
        printf '# spoken corpus — session %s, recorded %s\n' "$SESSION" "$(date '+%Y-%m-%d %H:%M')"
        printf '# ground truth is the script line; same columns as corpus_manifest.tsv\n'
        printf 'clip_id\tspeaker\tsource_rel\twords\tduration_s\tground_truth\n'
        for ((i = 1; i <= TOTAL; i++)); do
            local id; id="$(clip_id_for "$i")"
            local f="$CLIPS/$id.wav"
            [[ -f "$f" ]] || continue
            local d w
            d="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$f")"
            w="$(printf '%s' "${SENTENCES[$((i - 1))]}" | wc -w | tr -d ' ')"
            printf '%s\troman\taudio/voice/%s/clips/%s.wav\t%s\t%.3f\t%s\n' \
                "$id" "$SESSION" "$id" "$w" \
                "$(python3 -c "print(max(0.0, float('$d') - $LEAD_SILENCE - $TAIL_SILENCE))")" \
                "${SENTENCES[$((i - 1))]}"
        done
    } > "$VMANIFEST"
}

if (( TEST_FINALISE )); then
    set +e; finalise "$TF_IN" "$TF_OUT"; rc=$?; set -e
    case "$rc" in
        0) ok "finalised → $TF_OUT" ;;
        2) die "input was silent after trimming" ;;
        *) die "finalise failed (rc=$rc)" ;;
    esac
    exit 0
fi

# ── the session ───────────────────────────────────────────────────────────────

clear
say ""
say "  ${C_BLD}quill spoken corpus${C_RST}   session: $SESSION"
say "  ${C_DIM}input: ${CUR_IN}   →   $VOICE_DIR${C_RST}"
say ""
say "  Read each line exactly as written. Speak normally, at the pace you'd"
say "  actually dictate at. Short pause before and after each sentence."
say ""
if (( MANUAL )); then
    say "  ENTER to start, ENTER again to stop."
else
    say "  ENTER to start. It stops on its own ~${SILENCE_STOP}s after you finish"
    say "  (or press ENTER to cut it early)."
fi
say ""
printf '  calibrating your room… ' >&2
read -r SPEECH_GATE SILENCE_GATE <<<"$(calibrate)"
printf 'speech gate %s, silence gate %s\n' "$SPEECH_GATE" "$SILENCE_GATE" >&2
say ""
printf '  press ENTER when ready' >&2; read -r _ </dev/tty || true

START=1; END=$TOTAL
if [[ -n "$REDO" ]]; then START="$REDO"; END="$REDO"; fi

for ((i = START; i <= END; i++)); do
    ID="$(clip_id_for "$i")"
    OUT="$CLIPS/$ID.wav"
    SENTENCE="${SENTENCES[$((i - 1))]}"

    if [[ -f "$OUT" && -z "$REDO" ]]; then continue; fi

    while :; do
        clear
        DONE_N=0
        for ((k = 1; k <= TOTAL; k++)); do [[ -f "$CLIPS/$(clip_id_for "$k").wav" ]] && DONE_N=$((DONE_N + 1)); done
        say ""
        say "  ${C_DIM}sentence $i of $TOTAL   ·   $DONE_N recorded   ·   $((TOTAL - DONE_N)) to go${C_RST}"
        say ""
        say "  ${C_BLD}$SENTENCE${C_RST}"
        say ""
        printf '  ENTER to record  ·  s to skip  ·  q to stop for now: ' >&2
        read -r key </dev/tty || key="q"
        case "$key" in
            q|Q) say ""; write_manifest; ok "stopped. $DONE_N of $TOTAL recorded — re-run to resume."; exit 0 ;;
            s|S) break ;;
        esac

        say ""
        printf '  %s● recording…%s speak now' "$C_RED" "$C_RST" >&2
        RAW="$VOICE_DIR/.take.raw"
        if ! record_one "$RAW"; then
            printf '\r  %swarn%s nothing was captured. Try again.\n' "$C_YEL" "$C_RST" >&2
            sleep 1.2; continue
        fi
        printf '\r  %sprocessing…%s                    \n' "$C_DIM" "$C_RST" >&2

        set +e; finalise "$RAW" "$OUT"; RC=$?; set -e
        rm -f "$RAW"
        if (( RC == 2 )); then
            warn "that take was silent — check the mic and try again."
            sleep 1.2; continue
        elif (( RC != 0 )); then
            warn "could not process that take. Try again."
            sleep 1.2; continue
        fi

        DUR="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT")"
        say ""
        ok "recorded ${DUR}s — playing it back"
        afplay "$OUT" >/dev/null 2>&1 || true
        printf '  ENTER to keep  ·  r to redo: ' >&2
        read -r verdict </dev/tty || verdict=""
        case "$verdict" in
            r|R) rm -f "$OUT"; continue ;;
            *)   break ;;
        esac
    done
    [[ -n "$REDO" ]] && break
done

write_manifest
clear
DONE_N=0
for ((k = 1; k <= TOTAL; k++)); do [[ -f "$CLIPS/$(clip_id_for "$k").wav" ]] && DONE_N=$((DONE_N + 1)); done
rule
ok "spoken corpus: $DONE_N of $TOTAL clips"
say "  clips    : $CLIPS"
say "  manifest : $VMANIFEST"
say ""
say "  score a run against this corpus with:"
say "    rig/score.py --run out/<run> --manifest $VMANIFEST"
say ""
say "  note: for THIS corpus the mic is a real microphone, so pass"
say "    --expect-device 'Built-in'   to run_eval.sh / read_flow.sh"
say "  (the BlackHole assertion is correct to relax here and ONLY here)"
rule
