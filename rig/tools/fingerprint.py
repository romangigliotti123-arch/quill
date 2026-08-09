#!/usr/bin/env python3
"""
rig/tools/fingerprint.py — turn a verification-tap recording into a comparable
fingerprint, and hard-fail when the tap heard nothing.

WHY THIS EXISTS

The rig's claim is "both apps were fed the same audio". The only way to know that
is to record the loopback device at the same moment the app is listening to it,
and compare the two recordings. BlackHole is a bit-exact loopback, so the same
clip played twice should land in the tap as byte-identical samples — which makes
a hash the right instrument, not a similarity score.

Recordings never start at the same offset, so the hash is taken over a window
anchored to the FIRST AUDIBLE SAMPLE, not to the start of the file. Everything
before onset is transport jitter and must not enter the hash.

A tap that is entirely silent is the single most important failure this rig can
detect: it means nothing reached BlackHole, the app heard nothing, and any
transcript that appears alongside it came from somewhere else.

usage:
  fingerprint.py <tap.wav> [--window-sec 3.0] [--json]
"""

from __future__ import annotations

import argparse
import array
import hashlib
import json
import math
import subprocess
import sys

SAMPLE_RATE = 48000
CHANNELS = 2
ONSET_THRESHOLD = 64          # |sample| out of 32768 ≈ -54 dBFS; above dither, below speech
ONSET_RUN = 48                # consecutive frames required, so a single tick is not "onset"

# 3.0s, not 5.0s: the shortest clip in the frozen corpus carries 4.315s of speech,
# and a window that runs past the end of the audio gets truncated to whatever the
# recording happened to contain. Two runs truncated to different lengths would
# hash differently and read as "the apps got different audio" when they did not.
# Every clip in the corpus clears 3.0s with margin.
DEFAULT_WINDOW_SEC = 3.0


def decode(path: str) -> array.array:
    p = subprocess.run(
        ["ffmpeg", "-hide_banner", "-nostdin", "-v", "error", "-i", path,
         "-f", "s16le", "-acodec", "pcm_s16le", "-ar", str(SAMPLE_RATE),
         "-ac", str(CHANNELS), "-"],
        capture_output=True,
    )
    if p.returncode != 0:
        sys.exit(f"FAIL  ffmpeg could not decode {path}\n      {p.stderr.decode()[:400]}")
    a = array.array("h")
    a.frombytes(p.stdout[: len(p.stdout) // 2 * 2])
    return a


def find_onset(a: array.array) -> int | None:
    """Index of the first of ONSET_RUN consecutive loud samples, or None."""
    run = 0
    for i, s in enumerate(a):
        if abs(s) >= ONSET_THRESHOLD:
            run += 1
            if run >= ONSET_RUN:
                return i - run + 1
        else:
            run = 0
    return None


def fingerprint(path: str, window_sec: float = DEFAULT_WINDOW_SEC) -> dict:
    a = decode(path)
    total = len(a)
    if total == 0:
        return {"path": path, "ok": False, "reason": "empty_recording", "samples": 0}

    peak = max(abs(s) for s in a)
    if peak == 0:
        return {"path": path, "ok": False, "reason": "digital_silence",
                "samples": total, "peak": 0}

    onset = find_onset(a)
    if onset is None:
        return {"path": path, "ok": False, "reason": "no_audible_onset",
                "samples": total, "peak": peak,
                "peak_dbfs": round(20 * math.log10(peak / 32768), 2)}

    window = int(window_sec * SAMPLE_RATE) * CHANNELS
    core = a[onset: onset + window]
    if len(core) < window:
        # Short tap: still hashable, but the window length becomes part of the
        # identity so two different lengths can never collide into "identical".
        window = len(core)

    rms = math.sqrt(sum(s * s for s in core) / len(core)) if core else 0.0

    return {
        "path": path,
        "ok": True,
        "samples": total,
        "duration_sec": round(total / CHANNELS / SAMPLE_RATE, 3),
        "onset_sample": onset,
        "onset_sec": round(onset / CHANNELS / SAMPLE_RATE, 3),
        "window_samples": window,
        "core_md5": hashlib.md5(core.tobytes()).hexdigest(),
        "peak": peak,
        "peak_dbfs": round(20 * math.log10(peak / 32768), 2),
        "core_rms_dbfs": round(20 * math.log10(rms / 32768), 2) if rms > 0 else -999.0,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("wav")
    ap.add_argument("--window-sec", type=float, default=DEFAULT_WINDOW_SEC)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    fp = fingerprint(args.wav, args.window_sec)
    if args.json:
        print(json.dumps(fp))
    else:
        for k, v in fp.items():
            print(f"  {k:16} {v}")

    if not fp["ok"]:
        reason = fp["reason"]
        print(f"\nFAIL  verification tap contains no audio ({reason}).", file=sys.stderr)
        print("      Nothing reached BlackHole during this clip, so the app under test", file=sys.stderr)
        print("      heard nothing. Any transcript recorded alongside this tap did NOT", file=sys.stderr)
        print("      come from this clip and must not be scored.", file=sys.stderr)
        print("      fix: check that ffmpeg's -audio_device_index still points at", file=sys.stderr)
        print("           BlackHole (rig/setup.sh re-resolves it).", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
