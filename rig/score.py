#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["jiwer==4.0.0", "whisper-normalizer==0.1.15"]
# ///
"""
rig/score.py — WER/CER for the quill gauntlet.

Text normalisation is not a nicety here, it is the difference between measuring
accuracy and measuring formatting. Wispr Flow returns auto-punctuated, capitalised,
digit-formatted prose; LibriSpeech ground truth is bare uppercase words; a raw ASR
stream is neither. Comparing those directly scores typography.

So OpenAI's EnglishTextNormalizer (the one Whisper's published WER numbers use) is
applied to BOTH sides of every comparison, always. If it cannot be imported this
script exits non-zero rather than quietly substituting something weaker — a rig
that silently degrades its own metric is worse than one that stops.

Columns produced per app:
  wer / cer            accuracy. Flow's asrText, Quill's raw text. THE number.
  wer_fmt              same metric on Flow's formattedText — shows whether the
                       formatter changed the words, not just the punctuation.
  fmt_divergence       WER(raw → formatted). How much the formatter rewrote.
  punct_density        punctuation+capital ratio of the UNnormalised formatted
                       text. This is the actual "formatting" measure; it is
                       deliberately computed before normalisation, because
                       normalisation exists precisely to erase it.

usage:
  rig/score.py selftest                      # prove the pipeline works, no run needed
  rig/score.py --run out/<run_id> [--run out/<other>]
  rig/score.py --ref "some words" --hyp "some word"
"""

from __future__ import annotations

import argparse
import json
import os
import string
import sys
from pathlib import Path

RIG = Path(__file__).resolve().parent
MANIFEST = RIG / "corpus_manifest.tsv"


# ── normalisation (mandatory) ─────────────────────────────────────────────────

def load_normalizer():
    """Return OpenAI's EnglishTextNormalizer, or die explaining how to get it.

    Versions are pinned in the header block above: a scoring tool whose metric
    can shift under it when a dependency publishes a release is not a measuring
    instrument. Bump them deliberately and re-baseline when you do.
    """
    import warnings

    try:
        with warnings.catch_warnings():  # the package's own docstrings warn on import
            warnings.simplefilter("ignore")
            from whisper_normalizer.english import EnglishTextNormalizer  # type: ignore
        return EnglishTextNormalizer()
    except Exception:
        pass
    try:  # transformers ships a verbatim port; no torch needed for this module
        from transformers.models.whisper.english_normalizer import (  # type: ignore
            EnglishTextNormalizer,
        )
        return EnglishTextNormalizer({})
    except Exception:
        pass
    try:  # the original, if openai-whisper happens to be installed
        from whisper.normalizers import EnglishTextNormalizer  # type: ignore
        return EnglishTextNormalizer()
    except Exception:
        pass
    sys.exit(
        "FAIL  EnglishTextNormalizer could not be imported from any known source.\n"
        "      Refusing to score without it: unnormalised text measures punctuation,\n"
        "      not accuracy, and Flow auto-punctuates while raw ASR does not.\n"
        "      fix: uv run --script rig/score.py  (uv resolves the deps itself)\n"
        "      or:  uv tool install whisper-normalizer\n"
        "      Do NOT work around this by disabling normalisation."
    )


# ── metrics ───────────────────────────────────────────────────────────────────

def _counts(ref: str, hyp: str, char_level: bool):
    """(errors, ref_length) for one utterance, counting an empty hyp honestly."""
    import jiwer

    ref_units = list(ref) if char_level else ref.split()
    if not ref_units:
        return 0, 0
    if not (list(hyp) if char_level else hyp.split()):
        # Nothing came back. Every reference unit is a deletion. jiwer refuses
        # empty hypotheses, and this is the one case we must not skip — a silent
        # run is exactly the failure the rig is built to surface.
        return len(ref_units), len(ref_units)
    out = (jiwer.process_characters if char_level else jiwer.process_words)(ref, hyp)
    return out.substitutions + out.deletions + out.insertions, len(ref_units)


def corpus_rate(pairs, char_level=False):
    """Corpus-level rate: total errors / total reference units (not a mean of means)."""
    e = n = 0
    for ref, hyp in pairs:
        de, dn = _counts(ref, hyp, char_level)
        e += de
        n += dn
    return (e / n) if n else float("nan"), e, n


def punct_density(text: str) -> float:
    if not text:
        return 0.0
    marks = sum(1 for c in text if c in string.punctuation)
    caps = sum(1 for c in text if c.isupper())
    return (marks + caps) / len(text)


# ── data loading ──────────────────────────────────────────────────────────────

def load_manifest() -> dict[str, str]:
    if not MANIFEST.exists():
        sys.exit(f"FAIL  no manifest at {MANIFEST}\n      fix: rig/fetch_corpus.sh")
    refs = {}
    with MANIFEST.open(encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("#") or line.startswith("clip_id"):
                continue
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 6:
                refs[parts[0]] = parts[5]
    return refs


def load_run(run_dir: Path) -> tuple[dict, list[dict]]:
    meta_p, res_p = run_dir / "meta.json", run_dir / "results.jsonl"
    if not res_p.exists():
        sys.exit(f"FAIL  {res_p} not found\n      fix: rig/run_eval.sh --app <flow|quill>")
    meta = json.loads(meta_p.read_text()) if meta_p.exists() else {}
    rows = [json.loads(l) for l in res_p.read_text().splitlines() if l.strip()]
    return meta, rows


# ── reporting ─────────────────────────────────────────────────────────────────

def score_run(run_dir: Path, refs: dict[str, str], norm) -> dict:
    meta, rows = load_run(run_dir)
    app = meta.get("app") or (rows[0].get("app") if rows else "unknown")

    ok_rows = [r for r in rows if r.get("ok")]
    failed = [r for r in rows if not r.get("ok")]
    missing_ref = [r["clip_id"] for r in ok_rows if r["clip_id"] not in refs]
    if missing_ref:
        sys.exit(f"FAIL  {len(missing_ref)} clip(s) not in the manifest: {missing_ref[:3]}\n"
                 f"      The run and the frozen corpus disagree. Do not score this.")

    per_clip, raw_pairs, char_pairs, fmt_pairs, div_pairs, dens = [], [], [], [], [], []
    for r in ok_rows:
        ref_n = norm(refs[r["clip_id"]])
        raw_n = norm(r.get("text_raw") or "")
        fmt_src = r.get("text_formatted") or ""
        fmt_n = norm(fmt_src)

        if not ref_n:
            continue
        raw_pairs.append((ref_n, raw_n))
        char_pairs.append((ref_n, raw_n))
        wer_i, _, _ = corpus_rate([(ref_n, raw_n)])
        per_clip.append({
            "clip_id": r["clip_id"], "wer": round(wer_i, 4),
            "ref_words": len(ref_n.split()), "hyp_words": len(raw_n.split()),
            "latency_ms": r.get("latency_ms"),
        })
        if fmt_src:
            fmt_pairs.append((ref_n, fmt_n))
            div_pairs.append((raw_n, fmt_n))
            dens.append(punct_density(fmt_src))

    wer, we, wn = corpus_rate(raw_pairs)
    cer, ce, cn = corpus_rate(char_pairs, char_level=True)
    wer_fmt = corpus_rate(fmt_pairs)[0] if fmt_pairs else None
    divergence = corpus_rate(div_pairs)[0] if div_pairs else None
    lat = [r["latency_ms"] for r in ok_rows if isinstance(r.get("latency_ms"), (int, float))]
    lat.sort()

    return {
        "run_dir": str(run_dir), "app": app, "meta": meta,
        "clips_ok": len(ok_rows), "clips_failed": len(failed),
        "failed_clips": [r.get("clip_id") for r in failed],
        "wer": wer, "word_errors": we, "ref_words": wn,
        "cer": cer, "char_errors": ce, "ref_chars": cn,
        "wer_formatted": wer_fmt, "fmt_divergence": divergence,
        "punct_density": (sum(dens) / len(dens)) if dens else None,
        "latency_ms_median": lat[len(lat) // 2] if lat else None,
        "latency_ms_p90": lat[int(len(lat) * 0.9)] if lat else None,
        "per_clip": per_clip,
    }


def pct(v):
    return "—" if v is None or v != v else f"{v * 100:.2f}%"


def report(results: list[dict]) -> None:
    w = 22
    print()
    print("  " + "metric".ljust(w) + "".join(r["app"].rjust(16) for r in results))
    print("  " + "─" * (w + 16 * len(results)))

    def row(label, fn):
        print("  " + label.ljust(w) + "".join(str(fn(r)).rjust(16) for r in results))

    row("clips scored", lambda r: r["clips_ok"])
    row("clips FAILED", lambda r: r["clips_failed"])
    row("WER (accuracy)", lambda r: pct(r["wer"]))
    row("CER", lambda r: pct(r["cer"]))
    row("word errors / words", lambda r: f'{r["word_errors"]}/{r["ref_words"]}')
    row("WER on formatted", lambda r: pct(r["wer_formatted"]))
    row("formatter divergence", lambda r: pct(r["fmt_divergence"]))
    row("punct density", lambda r: pct(r["punct_density"]))
    row("latency median (ms)", lambda r: r["latency_ms_median"] or "—")
    row("latency p90 (ms)", lambda r: r["latency_ms_p90"] or "—")
    print()

    if len(results) == 2:
        a, b = results
        if a["clips_ok"] != b["clips_ok"]:
            print(f"  ⚠️  UNEQUAL CLIP COUNTS ({a['app']}={a['clips_ok']}, "
                  f"{b['app']}={b['clips_ok']}). The two columns are not comparable.")
        delta = (b["wer"] - a["wer"]) * 100
        better = a["app"] if a["wer"] < b["wer"] else b["app"]
        print(f"  WER delta: {delta:+.2f} points ({b['app']} minus {a['app']}) "
              f"→ {better} is more accurate")
        print("  Note: a WER gap smaller than ~1 point on 50 utterances is inside")
        print("  the noise floor. Treat it as a tie unless you ran more clips.")
    print()


# ── self test ─────────────────────────────────────────────────────────────────

def selftest() -> int:
    norm = load_normalizer()
    print("  normalizer:", type(norm).__module__ + "." + type(norm).__name__)
    print()

    cases = [
        # (name, ref, hyp, expected_wer, why)
        ("identical", "the cat sat", "the cat sat", 0.0, "sanity"),
        ("one substitution", "the cat sat", "the bat sat", 1 / 3, "1 error / 3 words"),
        ("one deletion", "the cat sat", "the sat", 1 / 3, "1 error / 3 words"),
        ("empty hypothesis", "the cat sat", "", 1.0, "silence must score 1.0, not crash"),
        ("formatting only",
         "HE HOPED THERE WOULD BE STEW FOR DINNER",
         "He hoped there would be stew for dinner.",
         0.0, "THE POINT: casing+punctuation must normalise to zero errors"),
        ("numbers",
         "I HAVE TWENTY THREE DOLLARS",
         "I have $23.",
         0.0, "normaliser folds digits/currency to words"),
    ]

    failures = 0
    for name, ref, hyp, expect, why in cases:
        got, _, _ = corpus_rate([(norm(ref), norm(hyp))])
        good = abs(got - expect) < 1e-6
        failures += not good
        print(f"  {'ok  ' if good else 'FAIL'}  {name:<20} WER={got:.4f} "
              f"expected={expect:.4f}   {why}")
        if not good:
            print(f"        normalised ref: {norm(ref)!r}")
            print(f"        normalised hyp: {norm(hyp)!r}")

    print()
    unnorm, _, _ = corpus_rate([("HE HOPED THERE WOULD BE STEW FOR DINNER",
                                "He hoped there would be stew for dinner.")])
    print(f"  Without normalisation that same pair scores WER={unnorm:.4f} "
          f"— {unnorm * 100:.0f}% of the words look wrong purely because of")
    print("  capitalisation and a full stop. That is the error this script exists to prevent.")
    print()
    if failures:
        print(f"  {failures} self-test(s) FAILED — do not trust this scorer.")
        return 1
    print("  all self-tests passed.")
    return 0


# ── main ──────────────────────────────────────────────────────────────────────

def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "selftest":
        return selftest()

    ap = argparse.ArgumentParser(description="WER/CER for the quill gauntlet")
    ap.add_argument("--run", action="append", default=[], metavar="DIR",
                    help="a run directory under rig/out (repeat for a comparison)")
    ap.add_argument("--ref", help="ad-hoc reference text")
    ap.add_argument("--hyp", help="ad-hoc hypothesis text")
    ap.add_argument("--json", metavar="FILE", help="also write full results as JSON")
    args = ap.parse_args()

    norm = load_normalizer()

    if args.ref is not None and args.hyp is not None:
        r, h = norm(args.ref), norm(args.hyp)
        wer, we, wn = corpus_rate([(r, h)])
        cer, _, _ = corpus_rate([(r, h)], char_level=True)
        print(f"  normalised ref: {r!r}")
        print(f"  normalised hyp: {h!r}")
        print(f"  WER {wer * 100:.2f}%  ({we}/{wn} words)   CER {cer * 100:.2f}%")
        return 0

    if not args.run:
        ap.error("give --run DIR (once or twice), or --ref/--hyp, or `selftest`")

    refs = load_manifest()
    results = []
    for d in args.run:
        p = Path(d)
        if not p.is_absolute():
            p = (RIG / d) if (RIG / d).exists() else Path.cwd() / d
        results.append(score_run(p, refs, norm))

    report(results)

    if args.json:
        Path(args.json).write_text(json.dumps(results, indent=2))
        print(f"  wrote {args.json}")

    if any(r["clips_failed"] for r in results):
        print("  ⚠️  some clips failed to produce a transcript; they are EXCLUDED from")
        print("      the rates above. Check results.jsonl before quoting these numbers.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
