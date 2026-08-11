#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["jiwer==4.0.0", "whisper-normalizer==0.1.15"]
# ///
"""
rig/headtohead.py — Quill against Wispr Flow on identical audio.

WHY THIS EXISTS SEPARATELY FROM score.py
----------------------------------------
score.py scores runs. This scores the *comparison*, and the comparison has one
property that has to be enforced rather than assumed: both apps must have been
fed the same clip. Flow's transcripts live in its own sqlite and are captured by
run_eval.sh into a run directory keyed by clip_id; Quill's can come either from a
run directory or straight from disk via QUILL_TRANSCRIBE_DIR. Only clips present
on BOTH sides are scored, and the count is printed, so a partial run cannot
quietly become a better-looking average.

RAW AGAINST RAW IS THE ACCURACY NUMBER
--------------------------------------
Both apps keep the recogniser's output separately from what they finally insert.
Scoring cleaned text against a ground truth that has no punctuation measures
formatting, not hearing. So this prints both, labelled, and the raw pair is the
one that answers "which one hears better".

Measured 2026-08-11 on the frozen 50-clip LibriSpeech corpus, 1138 reference
words, same audio through the same loopback:

    raw          Quill 2.81%  (32 errors)   Flow 2.11%  (24 errors)
    after cleanup Quill 2.81% (32 errors)   Flow 2.55%  (29 errors)
    Flow e2e latency, its own column: median 807ms, p90 1013ms

Two things worth keeping in mind before reading those as a verdict.

Flow's own formatting pass COSTS it five errors (2.11 -> 2.55). Quill's costs it
none, because the vocabulary corrector has nothing to correct in 19th-century
American prose — on Roman's own voice the same pass fixes fourteen.

And this corpus is not the target. Quill runs en_AU; the corpus is American, and
its ground truth spells accordingly. Re-running the whole corpus with
QUILL_TRANSCRIBE_LOCALE=en_US moves Quill from 32 errors to 31, so the locale
accounts for one error and no more — worth knowing precisely rather than
assuming, which is why the flag is documented here.

What is left of the gap is mostly homophones the audio genuinely does not
disambiguate (flour/flower, hay/hey, dews/dues, formally/formerly), compounding
conventions in old text (down stairs / downstairs, sailorman / sailor man), and
Apple's recogniser rewriting "the sixth of April eighteen thirty" as
"6 April 1830" — which is a defensible rendering of a date and still drops three
words the speaker said.

usage:
    rig/headtohead.py --flow out/20260809-180355-flow \\
                      --quill-jsonl /tmp/quill.jsonl \\
                      [--manifest corpus_manifest.tsv]

    # Quill side from a transcribe-from-disk sweep:
    QUILL_TRANSCRIBE_DIR=rig/audio/clips .build/debug/Quill > /tmp/quill.jsonl
"""
import argparse
import json
import pathlib
import sys

import jiwer
from whisper_normalizer.english import EnglishTextNormalizer

RIG = pathlib.Path(__file__).resolve().parent


def load_manifest(path):
    truth = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.startswith("#") or line.startswith("clip_id"):
            continue
        parts = line.split("\t")
        if len(parts) >= 6:
            truth[parts[0]] = parts[5]
    return truth


def load_flow(run_dir):
    """clip_id -> (raw, formatted, latency_ms) from a run_eval.sh --app flow run."""
    out = {}
    results = run_dir / "results.jsonl"
    if not results.exists():
        sys.exit(f"no results.jsonl in {run_dir}")
    for line in results.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        d = json.loads(line)
        # A row that did not complete is not a result. Scoring it as an empty
        # string would credit the other app with a win it did not earn.
        if not d.get("ok"):
            continue
        out[d["clip_id"]] = (d.get("text_raw") or "",
                             d.get("text_formatted") or "",
                             d.get("latency_ms"))
    return out


def load_quill_jsonl(path):
    """clip_id -> raw, from QUILL_TRANSCRIBE_DIR output."""
    out = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        d = json.loads(line)
        if "clip" in d and "text" in d:
            out[d["clip"]] = d["text"].replace("\n", " ")
    return out


def load_quill_run(run_dir):
    out = {}
    for line in (run_dir / "results.jsonl").read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        d = json.loads(line)
        if d.get("ok"):
            out[d["clip_id"]] = (d.get("text_raw") or "", d.get("text_formatted") or "")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--flow", required=True, help="Flow run directory")
    ap.add_argument("--quill-jsonl", help="QUILL_TRANSCRIBE_DIR output")
    ap.add_argument("--quill-run", help="Quill run directory from run_eval.sh")
    ap.add_argument("--manifest", default=str(RIG / "corpus_manifest.tsv"))
    args = ap.parse_args()

    truth = load_manifest(pathlib.Path(args.manifest))
    flow = load_flow(pathlib.Path(args.flow))

    quill_formatted = None
    if args.quill_jsonl:
        quill_raw = load_quill_jsonl(pathlib.Path(args.quill_jsonl))
    elif args.quill_run:
        pairs = load_quill_run(pathlib.Path(args.quill_run))
        quill_raw = {k: v[0] for k, v in pairs.items()}
        quill_formatted = {k: v[1] for k, v in pairs.items()}
    else:
        sys.exit("need --quill-jsonl or --quill-run")

    common = sorted(set(truth) & set(flow) & set(quill_raw))
    if not common:
        sys.exit("no clips in common — the two runs are not of the same corpus")

    missing_flow = sorted(set(truth) & set(quill_raw) - set(flow))
    missing_quill = sorted(set(truth) & set(flow) - set(quill_raw))
    for label, ids in (("Flow", missing_flow), ("Quill", missing_quill)):
        if ids:
            print(f"  ! {label} has no result for {len(ids)} clip(s); excluded from both sides")

    norm = EnglishTextNormalizer()
    refs = [norm(truth[i]) for i in common]
    words = sum(len(r.split()) for r in refs)

    def score(getter):
        out = jiwer.process_words(refs, [norm(getter(i)) for i in common])
        return out.wer * 100, out.substitutions + out.deletions + out.insertions

    print(f"\nidentical audio, {len(common)} clips, {words} reference words\n")

    qr = score(lambda i: quill_raw[i])
    fr = score(lambda i: flow[i][0])
    print("  RAW recogniser output — this is the accuracy number")
    print(f"    Quill  {qr[0]:5.2f}%   {qr[1]} errors")
    print(f"    Flow   {fr[0]:5.2f}%   {fr[1]} errors")
    winner = "Quill" if qr[0] < fr[0] else "Flow"
    print(f"    -> {winner} by {abs(qr[0] - fr[0]):.2f} points\n")

    if quill_formatted:
        qf = score(lambda i: quill_formatted[i])
        ff = score(lambda i: flow[i][1])
        print("  AFTER each app's own cleanup")
        print(f"    Quill  {qf[0]:5.2f}%   {qf[1]} errors")
        print(f"    Flow   {ff[0]:5.2f}%   {ff[1]} errors")
        winner = "Quill" if qf[0] < ff[0] else "Flow"
        print(f"    -> {winner} by {abs(qf[0] - ff[0]):.2f} points\n")

    lats = sorted(l for i in common if (l := flow[i][2]))
    if lats:
        print(f"  Flow end-to-end latency, its own column: "
              f"median {lats[len(lats) // 2]:.0f}ms  "
              f"p90 {lats[min(int(len(lats) * 0.9), len(lats) - 1)]:.0f}ms  (n={len(lats)})")

    print("\n  where Quill loses — every span Flow got right and Quill did not:")
    shown = 0
    for i in common:
        ref = norm(truth[i])
        oq = jiwer.process_words([ref], [norm(quill_raw[i])])
        of = jiwer.process_words([ref], [norm(flow[i][0])])
        if oq.wer <= of.wer:
            continue
        hyp = norm(quill_raw[i]).split()
        for ch in oq.alignments[0]:
            if ch.type == "equal":
                continue
            said = " ".join(ref.split()[ch.ref_start_idx:ch.ref_end_idx])
            heard = " ".join(hyp[ch.hyp_start_idx:ch.hyp_end_idx])
            print(f"    {i}  {ch.type:11s} said {said!r} -> heard {heard!r}")
            shown += 1
    if not shown:
        print("    (none)")


if __name__ == "__main__":
    main()
