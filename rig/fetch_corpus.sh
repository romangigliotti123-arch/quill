#!/usr/bin/env bash
#
# rig/fetch_corpus.sh — build the FROZEN 50-utterance evaluation set.
#
#   LibriSpeech test-clean (CC BY 4.0, Panayotov et al. 2015, openslr.org/12)
#   → a fixed 50-clip slice with ground truth
#   → 48kHz stereo pcm_s16le WAV, peak-normalised, 1s of leading silence
#
# The slice is frozen to rig/corpus_manifest.tsv and checked into git. Once that
# file exists this script will not re-select, because an eval set that quietly
# changes between runs makes every before/after comparison meaningless. Changing
# it is an explicit act: --refreeze.
#
# usage:
#   rig/fetch_corpus.sh              # download, extract, build clips from manifest
#   rig/fetch_corpus.sh --refreeze   # re-select the 50 utterances (breaks comparability)
#   rig/fetch_corpus.sh --verify     # check clips match the manifest, build nothing

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

CORPUS_URL="https://openslr.trmal.net/resources/12/test-clean.tar.gz"
TARBALL="$DOWNLOAD_DIR/test-clean.tar.gz"
# Both verified against a real download on 2026-08-09.
EXPECT_MD5="32fa31d27d2e1cad72775fee3f4849a9"
EXPECT_BYTES=346663984
LIBRI_ROOT="$AUDIO_DIR/LibriSpeech/test-clean"

TARGET_CLIPS=50
MIN_WORDS=12          # ≈4s of speech — long enough that a WER denominator means something
MAX_WORDS=35          # ≈13s — short enough to stay inside every app's utterance limit
LEAD_SILENCE=1.0      # apps clip the first fraction of a second of capture
TAIL_SILENCE=0.5      # gives the endpointer a clean edge to finalise on
RMS_TARGET_DBFS=-20.0 # typical speech level; VAD keys on RMS, not peak
PEAK_CEIL_DBFS=-1.0   # never clip, whatever the RMS target implies

REFREEZE=0
VERIFY_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --refreeze)  REFREEZE=1 ;;
        --verify)    VERIFY_ONLY=1 ;;
        -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
        *) die "unknown argument: $arg" "see: rig/fetch_corpus.sh --help" ;;
    esac
done

need_cmd curl "already present on macOS"
need_cmd ffmpeg "brew install ffmpeg"
need_cmd ffprobe "brew install ffmpeg"
need_cmd python3 "already present on macOS"

# ── 1. download ───────────────────────────────────────────────────────────────

download() {
    mkdir -p "$DOWNLOAD_DIR"
    if [[ -f "$TARBALL" ]]; then
        local have; have="$(md5 -q "$TARBALL")"
        if [[ "$have" == "$EXPECT_MD5" ]]; then
            ok "tarball already present and verified ($EXPECT_MD5)"
            return
        fi
        warn "tarball present but md5 is $have (expected $EXPECT_MD5) — resuming download"
    fi
    say ""
    info "downloading LibriSpeech test-clean (~331 MiB) from $CORPUS_URL"
    curl -fL -C - --retry 3 --retry-delay 2 -o "$TARBALL" "$CORPUS_URL" \
        || die "download failed" "check connectivity, then re-run rig/fetch_corpus.sh"

    local bytes have
    bytes="$(stat -f%z "$TARBALL")"
    have="$(md5 -q "$TARBALL")"
    [[ "$bytes" == "$EXPECT_BYTES" ]] || die "tarball is $bytes bytes, expected $EXPECT_BYTES" \
        "the mirror may have changed. delete $TARBALL and re-run."
    [[ "$have" == "$EXPECT_MD5" ]] || die "tarball md5 is $have, expected $EXPECT_MD5" \
        "refusing to build an eval set from an unverified corpus." \
        "delete $TARBALL and re-run."
    ok "downloaded and verified (md5 $have)"
}

extract() {
    if [[ -d "$LIBRI_ROOT" ]] && [[ -n "$(find "$LIBRI_ROOT" -name '*.flac' -print -quit 2>/dev/null)" ]]; then
        ok "corpus already extracted at $LIBRI_ROOT"
        return
    fi
    info "extracting…"
    mkdir -p "$AUDIO_DIR"
    tar xzf "$TARBALL" -C "$AUDIO_DIR" \
        || die "extract failed" "delete $TARBALL and re-run to redownload"
    [[ -d "$LIBRI_ROOT" ]] || die "expected $LIBRI_ROOT after extract, not found"
    ok "extracted to $LIBRI_ROOT"
}

# ── 2. freeze the slice ───────────────────────────────────────────────────────
#
# Selection is fully deterministic: eligible utterances (by word count, which is
# a stable proxy for duration and needs no probing), grouped by speaker, sorted,
# then round-robin one-per-speaker until we have 50. That spreads the set across
# ~40 test-clean speakers instead of over-sampling whoever sorts first, and it
# produces the same 50 on any machine.

freeze_manifest() {
    info "selecting $TARGET_CLIPS utterances (deterministic round-robin across speakers)…"
    python3 - "$LIBRI_ROOT" "$MANIFEST" "$TARGET_CLIPS" "$MIN_WORDS" "$MAX_WORDS" <<'PY'
import os, sys, subprocess, collections

libri, manifest, target, min_w, max_w = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])

by_speaker = collections.defaultdict(list)
for root, _dirs, files in os.walk(libri):
    for f in sorted(files):
        if not f.endswith(".trans.txt"):
            continue
        with open(os.path.join(root, f), encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                utt, _, text = line.partition(" ")
                n = len(text.split())
                if not (min_w <= n <= max_w):
                    continue
                flac = os.path.join(root, utt + ".flac")
                if not os.path.exists(flac):
                    continue
                by_speaker[utt.split("-")[0]].append((utt, flac, text, n))

if not by_speaker:
    sys.exit("no eligible utterances found — is the corpus extracted?")

for spk in by_speaker:
    by_speaker[spk].sort(key=lambda r: r[0])

speakers = sorted(by_speaker, key=lambda s: int(s))
chosen, ring = [], 0
while len(chosen) < target:
    added = False
    for spk in speakers:
        if len(chosen) >= target:
            break
        if ring < len(by_speaker[spk]):
            chosen.append(by_speaker[spk][ring]); added = True
    if not added:
        break
    ring += 1

if len(chosen) < target:
    sys.exit(f"only found {len(chosen)} eligible utterances, wanted {target}")

chosen.sort(key=lambda r: r[0])

rows = []
for utt, flac, text, n in chosen:
    dur = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=nw=1:nk=1", flac],
        capture_output=True, text=True, check=True).stdout.strip()
    # relative to rig/ — the manifest lives there and every consumer joins from RIG_DIR
    rows.append((utt, utt.split("-")[0], os.path.relpath(flac, os.path.dirname(manifest)), n, f"{float(dur):.3f}", text))

with open(manifest, "w", encoding="utf-8") as fh:
    fh.write("# quill eval corpus — FROZEN. Regenerate only with rig/fetch_corpus.sh --refreeze.\n")
    fh.write("# source: LibriSpeech test-clean (CC BY 4.0) — openslr.org/12\n")
    fh.write("# selection: word count in [%d,%d], round-robin one-per-speaker, sorted by utterance id\n" % (min_w, max_w))
    fh.write("clip_id\tspeaker\tsource_rel\twords\tduration_s\tground_truth\n")
    for r in rows:
        fh.write("\t".join(str(x) for x in r) + "\n")

spk_n = len({r[1] for r in rows})
tot = sum(float(r[4]) for r in rows)
print(f"froze {len(rows)} utterances from {spk_n} speakers, {tot:.1f}s of speech", file=sys.stderr)
PY
    ( cd "$RIG_DIR" && shasum -a 256 "$(basename "$MANIFEST")" > "$MANIFEST.sha256" )
    ok "manifest written: $MANIFEST"
}

assert_manifest_unmodified() {
    [[ -f "$MANIFEST.sha256" ]] || return 0
    ( cd "$RIG_DIR" && shasum -a 256 -c "$(basename "$MANIFEST").sha256" >/dev/null 2>&1 ) \
        || die "corpus_manifest.tsv has been edited since it was frozen." \
               "Comparisons across runs are only valid on an identical eval set." \
               "fix: restore it (git checkout rig/corpus_manifest.tsv)" \
               "  or accept the change deliberately: rig/fetch_corpus.sh --refreeze"
}

# ── 3. build the clips ────────────────────────────────────────────────────────
#
# One filtergraph per clip, applied identically to all 50 and to both apps:
#   flac → 48kHz → mono duplicated to stereo → gain → [1s silence][speech][0.5s silence]
#
# Two traps are deliberately avoided here.
#
# 1. `aformat=channel_layouts=stereo` on a mono source does NOT duplicate the
#    channel — it runs FFmpeg's power-preserving rematrix, which costs a silent
#    3.01 dB. `pan=stereo|c0=c0|c1=c0` copies the channel with unity gain, so the
#    level we measure is the level the app hears.
# 2. Gain is measured through the *same* resample+pan chain that writes the file,
#    not on the raw flac, so resampler overshoot is inside the measurement.
#
# RMS-targeting (not peak) is what matters: every app gates capture on an energy
# threshold, so equal RMS is what makes 50 clips behave alike. The peak ceiling
# only ever pulls the gain down, never up, so nothing clips.

# The one filter chain used for BOTH measuring and building. It must be byte
# identical in both places and it must be explicitly float.
#
# Why float is not optional: if the graph is left to negotiate its own sample
# format, `astats` is happy in s16 while `volume` pulls the graph into float.
# The resampler then clamps in the measuring chain but not in the building one,
# so a 16k→48k overshoot reads as "peak 0.0 dB" when measured and is really
# +5.0 dB when built. Gains computed that way are wrong, and on this corpus one
# clip clipped 48 samples. Pinning fltp up front makes both chains agree.
#
# Both ends must be pinned. Pinning only the head is not enough: ffmpeg
# negotiates formats backwards as well, so a downstream filter that accepts s16
# pulls the resampler back to s16 and the clamp returns. Measured on
# 2094-142345-0001: head-only pinning reports peak 0.000265 dB, head+tail
# pinning reports the truth, 5.037 dB.
CHAIN_PRE="aformat=sample_fmts=fltp,aresample=48000,pan=stereo|c0=c0|c1=c0,aformat=sample_fmts=fltp"

# Echoes "<gain_db>" for a source, measured through the exact output chain.
measure_gain() {
    local src="$1" stats rms peak
    stats="$(ffmpeg -hide_banner -nostdin -i "$src" \
               -af "${CHAIN_PRE},astats=measure_perchannel=none" \
               -f null - 2>&1 || true)"
    rms="$(printf  '%s\n' "$stats" | sed -n 's/.*RMS level dB: *\(-*[0-9.]*\).*/\1/p'  | tail -1)"
    peak="$(printf '%s\n' "$stats" | sed -n 's/.*Peak level dB: *\(-*[0-9.]*\).*/\1/p' | tail -1)"
    [[ -n "$rms" && -n "$peak" ]] || die "could not measure levels of $src"
    python3 -c "
rms, peak = float('$rms'), float('$peak')
print(f'{min($RMS_TARGET_DBFS - rms, $PEAK_CEIL_DBFS - peak):.2f}')"
}

build_clips() {
    mkdir -p "$CLIPS_DIR"
    local built=0 skipped=0 total
    total="$(grep -vc '^#\|^clip_id' "$MANIFEST" | tr -d ' ')"

    while IFS=$'\t' read -r clip_id speaker source_rel words duration text; do
        [[ "$clip_id" == "clip_id" || "$clip_id" == \#* || -z "$clip_id" ]] && continue
        local src="$RIG_DIR/$source_rel" dst="$CLIPS_DIR/$clip_id.wav"
        [[ -f "$src" ]] || die "source flac missing: $src" "fix: rig/fetch_corpus.sh (re-extract)"

        if [[ -f "$dst" ]]; then skipped=$((skipped + 1)); continue; fi

        local ch; ch="$(ffprobe -v error -select_streams a:0 -show_entries stream=channels \
                          -of default=nw=1:nk=1 "$src")"
        [[ "$ch" == "1" ]] || die "$clip_id source has $ch channels, expected mono" \
            "the pan filter below assumes mono LibriSpeech input; a stereo source would be half-dropped."

        local gain; gain="$(measure_gain "$src")"

        ffmpeg -hide_banner -nostdin -loglevel error -y \
            -f lavfi -t "$LEAD_SILENCE" -i "anullsrc=r=48000:cl=stereo" \
            -i "$src" \
            -f lavfi -t "$TAIL_SILENCE" -i "anullsrc=r=48000:cl=stereo" \
            -filter_complex "\
[0:a]aformat=sample_fmts=fltp:channel_layouts=stereo,aresample=48000[lead];\
[1:a]${CHAIN_PRE},volume=${gain}dB[sp];\
[2:a]aformat=sample_fmts=fltp:channel_layouts=stereo,aresample=48000[tail];\
[lead][sp][tail]concat=n=3:v=0:a=1[out]" \
            -map "[out]" -c:a pcm_s16le -ar 48000 -ac 2 "$dst" \
            || die "ffmpeg failed building $clip_id"
        built=$((built + 1))
        printf '\r%s  built %d/%d…%s' "$C_DIM" "$((built + skipped))" "$total" "$C_RST" >&2
    done < "$MANIFEST"
    printf '\r%*s\r' 60 '' >&2
    ok "clips ready: $built built, $skipped already present, in $CLIPS_DIR"
}

verify_clips() {
    local bad=0 n=0
    while IFS=$'\t' read -r clip_id _speaker _src _words duration _text; do
        [[ "$clip_id" == "clip_id" || "$clip_id" == \#* || -z "$clip_id" ]] && continue
        n=$((n + 1))
        local f="$CLIPS_DIR/$clip_id.wav"
        if [[ ! -f "$f" ]]; then warn "missing clip: $clip_id"; bad=$((bad + 1)); continue; fi
        local probe
        probe="$(ffprobe -v error -select_streams a:0 \
                   -show_entries stream=sample_rate,channels,codec_name \
                   -show_entries format=duration -of default=nw=1:nk=1 "$f" | tr '\n' ' ')"
        read -r codec rate ch dur <<<"$probe"
        local want; want="$(python3 -c "print(f'{$duration + $LEAD_SILENCE + $TAIL_SILENCE:.2f}')")"
        local delta; delta="$(python3 -c "print(f'{abs($dur - $want):.3f}')")"
        if [[ "$codec" != "pcm_s16le" || "$rate" != "48000" || "$ch" != "2" ]]; then
            warn "$clip_id: got $codec ${rate}Hz ${ch}ch, wanted pcm_s16le 48000Hz 2ch"; bad=$((bad + 1))
            continue
        fi
        if (( $(python3 -c "print(1 if $delta > 0.06 else 0)") )); then
            warn "$clip_id: duration ${dur}s, expected ~${want}s (delta ${delta}s)"; bad=$((bad + 1))
            continue
        fi

        # A clip that is technically well-formed but silent is the exact failure
        # this whole rig exists to catch, so levels are checked from the decoded
        # samples rather than from astats' dB strings — astats prints "-inf" for
        # true silence, which is precisely the case that must not be misparsed.
        local verdict
        verdict="$(ffmpeg -hide_banner -nostdin -v error -i "$f" -f s16le - 2>/dev/null \
                    | python3 -c "
import sys, array, math
d = sys.stdin.buffer.read()
a = array.array('h'); a.frombytes(d[: len(d) // 2 * 2])
lead = int($LEAD_SILENCE * 48000) * 2 - 480          # 5ms of slack at the boundary
lead_max  = max((abs(x) for x in a[:lead]), default=0)
speech    = a[lead:]
peak      = max((abs(x) for x in speech), default=0)
rms       = math.sqrt(sum(x * x for x in speech) / len(speech)) if len(speech) else 0
db        = lambda v: 20 * math.log10(v / 32768) if v > 0 else -999
print(f'{lead_max} {db(peak):.2f} {db(rms):.2f}')")"
        read -r lead_max peak_db _rms_db <<<"$verdict"
        if [[ "$lead_max" != "0" ]]; then
            warn "$clip_id: leading ${LEAD_SILENCE}s is not digital silence (max |sample| = $lead_max)"
            bad=$((bad + 1)); continue
        fi
        if (( $(python3 -c "print(1 if not (-30 <= $peak_db <= -0.9) else 0)") )); then
            warn "$clip_id: peak ${peak_db} dBFS outside [-30,-0.9] — silent or clipping"
            bad=$((bad + 1)); continue
        fi
    done < "$MANIFEST"
    if (( bad > 0 )); then
        die "$bad of $n clips failed verification" "fix: rm -rf $CLIPS_DIR && rig/fetch_corpus.sh"
    fi
    ok "all $n clips verified: pcm_s16le / 48kHz / stereo / ${LEAD_SILENCE}s silent lead + ${TAIL_SILENCE}s tail / peak ≤ ${PEAK_CEIL_DBFS} dBFS / audible"
}

# ── main ──────────────────────────────────────────────────────────────────────

rule
say "${C_BLD}quill eval corpus${C_RST}  ${C_DIM}LibriSpeech test-clean → $TARGET_CLIPS frozen clips${C_RST}"
rule

if (( VERIFY_ONLY )); then
    [[ -f "$MANIFEST" ]] || die "no manifest at $MANIFEST" "fix: rig/fetch_corpus.sh"
    assert_manifest_unmodified
    verify_clips
    exit 0
fi

download
extract

if (( REFREEZE )); then
    if [[ -f "$MANIFEST" ]]; then
        cp "$MANIFEST" "$MANIFEST.bak.$(timestamp_slug)"
        warn "re-freezing. previous manifest backed up. Results from before this point are NOT comparable to results after it."
    fi
    freeze_manifest
elif [[ -f "$MANIFEST" ]]; then
    assert_manifest_unmodified
    ok "using frozen manifest ($(grep -vc '^#\|^clip_id' "$MANIFEST" | tr -d ' ') clips)"
else
    freeze_manifest
fi

build_clips
verify_clips

rule
say "corpus ready. next: ${C_BLD}rig/setup.sh${C_RST}"
