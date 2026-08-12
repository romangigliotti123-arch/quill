#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["jiwer==4.0.0", "whisper-normalizer==0.1.15"]
# ///
"""
rig/score_vocabulary.py — is a candidate dictionary worth shipping?

WHY BOTH HALVES ARE MEASURED

Adding terms is not free. The corrector compares 1-3 word spans against every
term and REPLACES the span when it is close enough, so each entry is a standing
chance to rewrite something the user meant. Measured on this project in one
afternoon: "Builda Bed" turned "I need to build a bed for the spare room" into
"I need to Builda Bed for the spare room", and "Roman Design Co" turned "the
Roman design cost a lot" into "the Roman Design Co a lot", deleting a verb.

So a dictionary is scored on two numbers that pull against each other:

  GAIN   — errors repaired on Roman's own voice corpus, where the ground truth
           contains his real names.

  DAMAGE — spans rewritten in ordinary English that contains none of his
           vocabulary. The LibriSpeech reference transcripts are perfect: they
           are correct text, of 19th-century prose, with no reason for any
           dictionary to touch a word of them. EVERY change there is a false
           positive by construction. No judgement call, no eyeballing.

A dictionary that fixes six errors and damages four sentences is worse than no
change at all, because the six are visible to whoever reads the transcript and
the four are not.

usage:
    rig/score_vocabulary.py --vocab candidate.json [--baseline seed.json]
"""
import argparse
import json
import os
import pathlib
import subprocess
import sys
import tempfile

import jiwer
from whisper_normalizer.english import EnglishTextNormalizer

RIG = pathlib.Path(__file__).resolve().parent
ROOT = RIG.parent
BINARY = pathlib.Path.home() / "Library/Application Support/Quill/scratch/debug/Quill"


def clean(lines, vocab_path):
    """Run the real cleanup pipeline over lines, with a chosen dictionary."""
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as fh:
        fh.write("\n".join(lines) + "\n")
        infile = fh.name
    env = dict(os.environ)
    env["QUILL_CLEAN_FILE"] = infile
    if vocab_path:
        env["QUILL_VOCABULARY_FILE"] = str(vocab_path)
    out = subprocess.run([str(BINARY)], env=env, capture_output=True, text=True)
    os.unlink(infile)
    produced = [l for l in out.stdout.split("\n")]
    return produced[: len(lines)]


def load_voice():
    """Roman's own clips: raw recogniser output, and what he actually said."""
    truth = {}
    for line in (RIG / "audio/voice/roman/manifest.tsv").read_text().splitlines():
        if line.startswith("#") or line.startswith("clip_id") or not line.strip():
            continue
        parts = line.split("\t")
        truth[parts[0]] = parts[5]
    results = RIG / "out/voice-real/results.jsonl"
    ids, raws, refs = [], [], []
    for line in results.read_text().splitlines():
        if not line.strip():
            continue
        d = json.loads(line)
        cid = d.get("clip_id")
        # The self-correction clips are excluded: their ground truth deliberately
        # contains what the cleanup is supposed to remove, so they measure the
        # cleanup and not the dictionary.
        if not d.get("ok") or cid not in truth or cid.endswith(("031", "032", "033", "034", "035", "036")):
            continue
        ids.append(cid)
        raws.append((d.get("text_raw") or "").replace("\n", " "))
        refs.append(truth[cid])
    return ids, raws, refs


def load_ordinary_english():
    """Correct transcripts of prose containing none of his vocabulary."""
    out = []
    for line in (RIG / "corpus_manifest.tsv").read_text().splitlines():
        if line.startswith("#") or line.startswith("clip_id") or not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) >= 6:
            out.append(parts[5])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vocab", required=True, help="candidate vocabulary.json")
    ap.add_argument("--baseline", help="vocabulary.json to compare against (default: the shipped seed)")
    args = ap.parse_args()

    if not BINARY.exists():
        sys.exit(f"no debug binary at {BINARY} — run swift build first")

    ids, raws, refs = load_voice()
    ordinary = load_ordinary_english()
    norm = EnglishTextNormalizer()
    nrefs = [norm(r) for r in refs]
    words = sum(len(r.split()) for r in nrefs)

    def score(vocab):
        cleaned = clean(raws, vocab)
        out = jiwer.process_words(nrefs, [norm(c) for c in cleaned])
        errors = out.substitutions + out.deletions + out.insertions
        perfect = sum(
            1 for r, c in zip(nrefs, cleaned)
            if jiwer.process_words([r], [norm(c)]).wer == 0
        )
        # Damage: ordinary English is already correct, so any change is a wrong one.
        touched = clean(ordinary, vocab)
        damaged = [
            (a, b) for a, b in zip(ordinary, touched)
            if norm(a) != norm(b)
        ]
        return out.wer * 100, errors, perfect, damaged

    print(f"\nHis voice: {len(ids)} clips, {words} words. "
          f"Ordinary English: {len(ordinary)} sentences that must not be touched.\n")

    rows = []
    for label, vocab in (("baseline", args.baseline), ("candidate", args.vocab)):
        wer, errors, perfect, damaged = score(vocab)
        rows.append((label, wer, errors, perfect, damaged))
        print(f"  {label:<10} WER {wer:5.2f}%   {errors:3d} errors   "
              f"{perfect}/{len(ids)} clips perfect   {len(damaged)} sentences damaged")

    (_, bw, be, bp, bd), (_, cw, ce, cp, cd) = rows
    print(f"\n  gain   : {be - ce:+d} errors, {cp - bp:+d} clips perfect")
    print(f"  damage : {len(cd) - len(bd):+d} ordinary sentences rewritten")

    if cd:
        print("\n  every ordinary-English sentence the candidate dictionary touched:")
        for before, after in cd[:20]:
            print(f"    - {before[:74]}")
            print(f"      {after[:74]}")

    if len(cd) > len(bd):
        verdict = ("DO NOT SHIP — it damages ordinary English, and those errors are "
                   "invisible to the person reading them")
    elif ce < be:
        verdict = "SHIP"
    elif ce == be:
        verdict = "NO CHANGE — neither better nor worse"
    else:
        verdict = "DO NOT SHIP — more errors than the baseline"
    print(f"\n  verdict: {verdict}\n")


if __name__ == "__main__":
    main()
