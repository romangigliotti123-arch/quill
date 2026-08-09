#!/usr/bin/env bash
#
# rig/verify_taps.sh — prove the two apps were fed identical audio.
#
# run_eval.sh records the loopback device while each clip plays, so every run
# carries an independent witness of what was actually sent. This script compares
# those witnesses across two runs, clip by clip.
#
# Without this, "we played the same files" is an assumption. A WER comparison
# built on an assumption about the audio path is not a measurement.
#
# Verdicts:
#   IDENTICAL   byte-identical over the onset-anchored window. Proven.
#   NEAR        correlation ≥ 0.999 — a dropped buffer or a resampler edge.
#               Usable, but reported, never hidden.
#   DIFFERENT   the two apps did not hear the same thing. The comparison is void.
#   MISSING     one run has no tap for that clip.
#
# usage:
#   rig/verify_taps.sh out/<runA> out/<runB>

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

[[ $# -eq 2 ]] || die "need exactly two run directories" \
    "usage: rig/verify_taps.sh out/<runA> out/<runB>" \
    "runs live in $OUT_DIR"

resolve() {
    local d="$1"
    [[ -d "$d" ]] && { (cd "$d" && pwd); return; }
    [[ -d "$RIG_DIR/$d" ]] && { (cd "$RIG_DIR/$d" && pwd); return; }
    [[ -d "$OUT_DIR/$d" ]] && { (cd "$OUT_DIR/$d" && pwd); return; }
    die "no such run directory: $d" "available runs:" "$(ls "$OUT_DIR" 2>/dev/null | tr '\n' ' ')"
}

A="$(resolve "$1")"
B="$(resolve "$2")"

for d in "$A" "$B"; do
    [[ -f "$d/tap_fingerprints.jsonl" ]] || die "no tap fingerprints in $d" \
        "That run was made with --no-tap, so there is no witness of what it heard." \
        "It cannot be verified. Re-run without --no-tap."
done

rule
say "${C_BLD}tap verification${C_RST}"
say "  A: $A"
say "  B: $B"
rule

python3 - "$A" "$B" <<'PY'
import array, json, math, subprocess, sys, os

A, B = sys.argv[1], sys.argv[2]

def load(run):
    out = {}
    with open(os.path.join(run, "tap_fingerprints.jsonl")) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            if d.get("clip_id"):
                out[d["clip_id"]] = d
    return out

fa, fb = load(A), load(B)

def decode(path):
    p = subprocess.run(["ffmpeg", "-hide_banner", "-nostdin", "-v", "error", "-i", path,
                        "-f", "s16le", "-ar", "48000", "-ac", "2", "-"], capture_output=True)
    a = array.array("h")
    if p.returncode == 0:
        a.frombytes(p.stdout[: len(p.stdout) // 2 * 2])
    return a

def correlate(run_a, run_b, clip, da, db):
    """Zero-lag normalised correlation over the onset-anchored window."""
    wa = os.path.join(run_a, "tap", clip + ".wav")
    wb = os.path.join(run_b, "tap", clip + ".wav")
    if not (os.path.exists(wa) and os.path.exists(wb)):
        return None
    xa, xb = decode(wa), decode(wb)
    oa, ob = da.get("onset_sample"), db.get("onset_sample")
    n = min(da.get("window_samples", 0), db.get("window_samples", 0))
    if oa is None or ob is None or n <= 0:
        return None
    ca, cb = xa[oa:oa + n], xb[ob:ob + n]
    n = min(len(ca), len(cb))
    if n == 0:
        return None
    ca, cb = ca[:n], cb[:n]
    num = sum(x * y for x, y in zip(ca, cb))
    da_ = math.sqrt(sum(x * x for x in ca))
    db_ = math.sqrt(sum(y * y for y in cb))
    return (num / (da_ * db_)) if da_ and db_ else None

clips = sorted(set(fa) | set(fb))
counts = {"IDENTICAL": 0, "NEAR": 0, "DIFFERENT": 0, "MISSING": 0, "NO_AUDIO": 0}
problems = []

for clip in clips:
    da, db = fa.get(clip), fb.get(clip)
    if not da or not db:
        counts["MISSING"] += 1
        problems.append((clip, "MISSING", "only one run has a tap for this clip"))
        continue
    if not da.get("ok") or not db.get("ok"):
        counts["NO_AUDIO"] += 1
        which = "A" if not da.get("ok") else "B"
        why = (da if not da.get("ok") else db).get("reason", "?")
        problems.append((clip, "NO_AUDIO", f"run {which}: {why}"))
        continue
    if da.get("core_md5") == db.get("core_md5") and da.get("window_samples") == db.get("window_samples"):
        counts["IDENTICAL"] += 1
        continue
    c = correlate(A, B, clip, da, db)
    if c is not None and c >= 0.999:
        counts["NEAR"] += 1
        problems.append((clip, "NEAR", f"correlation {c:.6f}"))
    else:
        counts["DIFFERENT"] += 1
        problems.append((clip, "DIFFERENT",
                         f"correlation {c:.6f}" if c is not None else "could not correlate"))

total = len(clips)
print(f"  clips compared : {total}")
for k in ("IDENTICAL", "NEAR", "DIFFERENT", "NO_AUDIO", "MISSING"):
    if counts[k]:
        print(f"  {k:<14} : {counts[k]}")
print()

if problems:
    print("  per-clip detail:")
    for clip, verdict, note in problems[:40]:
        print(f"    {verdict:<10} {clip:<22} {note}")
    if len(problems) > 40:
        print(f"    … and {len(problems) - 40} more")
    print()

bad = counts["DIFFERENT"] + counts["NO_AUDIO"] + counts["MISSING"]
if counts["DIFFERENT"] or counts["NO_AUDIO"]:
    print("  VERDICT: NOT COMPARABLE.")
    print("  The two runs did not receive the same audio, so any WER difference")
    print("  between them is partly or wholly an artefact of the audio path.")
    print("  Do not report a comparison from these runs. Re-run both.")
    sys.exit(1)
if counts["MISSING"]:
    print("  VERDICT: INCOMPLETE — some clips exist in only one run.")
    print("  Score only the intersection, or re-run.")
    sys.exit(1)
if counts["NEAR"]:
    print(f"  VERDICT: COMPARABLE, with {counts['NEAR']} clip(s) near-identical")
    print("  rather than byte-identical (buffer jitter). Fine to compare; the")
    print("  count is stated here so it is never silently absorbed.")
    sys.exit(0)
print("  VERDICT: COMPARABLE — every clip byte-identical across both runs.")
print("  Both apps provably received the same audio.")
sys.exit(0)
PY
