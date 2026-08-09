#!/usr/bin/env python3
"""
rig/blind.py — hide which app produced which transcript.

A critic who can see the labels is not scoring transcripts, they are scoring
their expectations. This writes every transcript to

    results/<clip_id>/<uuid>.txt

with the uuid→app map SEALED in a separate file that the scoring step never
reads. Unsealing is a deliberate, separate command that records when it happened.

WHAT BLINDING CANNOT DO — read this before trusting it

Text carries its own fingerprints. Wispr Flow's formatted output is punctuated
and capitalised; raw ASR is not. A critic who notices that can de-blind the set
by eye in seconds. So:

  * By default this writes the ACCURACY field (Flow's asrText, Quill's raw
    text), which is the field the WER column uses and the one least likely to
    be self-identifying.
  * `--field formatted` exists for scoring formatting quality, and in that mode
    the blinding is decorative. It says so, loudly, in the manifest.

Blinding removes the label. It does not make two systems indistinguishable, and
this file will not pretend otherwise.

usage:
  blind.py seal   --run out/<runA> --run out/<runB> [--out out/blind-<name>]
  blind.py unseal --dir out/blind-<name>
  blind.py status --dir out/blind-<name>
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import random
import shutil
import sys
import uuid
from pathlib import Path

RIG = Path(__file__).resolve().parent
OUT = RIG / "out"

SEAL_NAME = "SEALED_uuid_to_app.json"
PUBLIC_NAME = "blind_manifest.json"


def resolve_run(d: str) -> Path:
    for cand in (Path(d), RIG / d, OUT / d):
        if cand.is_dir():
            return cand.resolve()
    sys.exit(f"FAIL  no such run directory: {d}\n"
             f"      available: {', '.join(sorted(p.name for p in OUT.iterdir())) if OUT.is_dir() else '(none)'}")


def load_rows(run: Path) -> tuple[str, list[dict]]:
    res = run / "results.jsonl"
    if not res.exists():
        sys.exit(f"FAIL  {res} not found\n      fix: rig/run_eval.sh --app <flow|quill>")
    meta = {}
    if (run / "meta.json").exists():
        meta = json.loads((run / "meta.json").read_text())
    rows = [json.loads(l) for l in res.read_text().splitlines() if l.strip()]
    app = meta.get("app") or (rows[0].get("app") if rows else run.name)
    return app, rows


def cmd_seal(args: argparse.Namespace) -> int:
    if len(args.run) < 2:
        sys.exit("FAIL  --run must be given at least twice; blinding one run is pointless.")

    runs = [resolve_run(d) for d in args.run]
    loaded = [load_rows(r) for r in runs]
    apps = [a for a, _ in loaded]
    if len(set(apps)) != len(apps):
        sys.exit(f"FAIL  two runs report the same app ({apps}).\n"
                 f"      Blinding needs distinct systems to be worth anything.")

    out_dir = Path(args.out) if args.out else OUT / f"blind-{datetime.datetime.now():%Y%m%d-%H%M%S}"
    if out_dir.exists():
        sys.exit(f"FAIL  {out_dir} already exists — refusing to overwrite a sealed set.")
    (out_dir / "results").mkdir(parents=True)

    field = args.field
    # A fixed seed would make the mapping reproducible, which defeats the point.
    rng = random.SystemRandom()

    mapping: dict[str, dict] = {}
    per_clip: dict[str, list[str]] = {}
    skipped: list[str] = []

    by_clip: dict[str, list[tuple[str, dict]]] = {}
    for (app, rows), run in zip(loaded, runs):
        for r in rows:
            if not r.get("ok"):
                continue
            by_clip.setdefault(r["clip_id"], []).append((app, r))

    # Only clips present in EVERY run can be compared; a clip one app failed on
    # would otherwise silently become a one-sided comparison.
    complete = {c: v for c, v in by_clip.items() if len(v) == len(runs)}
    incomplete = sorted(set(by_clip) - set(complete))

    for clip_id, entries in sorted(complete.items()):
        clip_dir = out_dir / "results" / clip_id
        clip_dir.mkdir()
        ids = []
        shuffled = list(entries)
        rng.shuffle(shuffled)          # so file order never encodes the app
        for app, row in shuffled:
            text = (row.get("text_formatted") if field == "formatted" else row.get("text_raw")) or ""
            u = str(uuid.uuid4())
            (clip_dir / f"{u}.txt").write_text(text + "\n", encoding="utf-8")
            mapping[u] = {"app": app, "clip_id": clip_id, "field": field,
                          "sha256": hashlib.sha256(text.encode()).hexdigest()}
            ids.append(u)
        per_clip[clip_id] = ids
        if not any((clip_dir / f"{i}.txt").read_text().strip() for i in ids):
            skipped.append(clip_id)

    seal_path = out_dir / SEAL_NAME
    # Run directories are named after their app ("…-flow", "…-quill"), so the
    # paths themselves are a partial de-blind and belong inside the seal, not in
    # the manifest the critic can read.
    seal_path.write_text(json.dumps(
        {"runs": [str(r) for r in runs], "apps": apps, "mapping": mapping}, indent=2),
        encoding="utf-8")
    os.chmod(seal_path, 0o400)

    seal_hash = hashlib.sha256(seal_path.read_bytes()).hexdigest()
    public = {
        "created_utc": datetime.datetime.now(datetime.UTC).isoformat(),
        "n_systems": len(runs),
        "field_scored": field,
        "clips_blinded": len(complete),
        "clips_dropped_incomplete": incomplete,
        "uuids_per_clip": per_clip,
        "seal_sha256": seal_hash,
        "unsealed": False,
        "warning": (
            "Formatted text is self-identifying (punctuation and capitalisation); "
            "blinding this field is decorative."
            if field == "formatted" else
            "Raw ASR text was blinded. Style may still leak identity — blinding "
            "removes the label, not the fingerprints."
        ),
    }
    (out_dir / PUBLIC_NAME).write_text(json.dumps(public, indent=2), encoding="utf-8")

    print(f"  sealed {len(mapping)} transcripts across {len(complete)} clips")
    print(f"  field  : {field}")
    print(f"  dir    : {out_dir}")
    print(f"  seal   : {seal_path.name}  (chmod 400, sha256 {seal_hash[:16]}…)")
    if incomplete:
        print(f"  dropped {len(incomplete)} clip(s) missing from at least one run: "
              f"{', '.join(incomplete[:5])}{'…' if len(incomplete) > 5 else ''}")
    if skipped:
        print(f"  note: {len(skipped)} clip(s) are empty in every system")
    if field == "formatted":
        print()
        print("  ⚠️  formatted text is trivially de-blindable by eye. Treat any")
        print("     judgement made on this set as unblinded.")
    print()
    print(f"  the critic scores:  {out_dir / 'results'}")
    print(f"  unseal later with:  rig/blind.py unseal --dir {out_dir}")
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    d = Path(args.dir)
    pub = d / PUBLIC_NAME
    if not pub.exists():
        sys.exit(f"FAIL  {pub} not found — is {d} a sealed set?")
    info = json.loads(pub.read_text())
    for k in ("created_utc", "n_systems", "field_scored", "clips_blinded", "unsealed"):
        print(f"  {k:<24} {info.get(k)}")
    seal = d / SEAL_NAME
    if seal.exists():
        live = hashlib.sha256(seal.read_bytes()).hexdigest()
        same = live == info.get("seal_sha256")
        print(f"  {'seal intact':<24} {same}")
        if not same:
            print("  ⚠️  the seal file has been modified since it was written.")
            return 1
    return 0


def cmd_unseal(args: argparse.Namespace) -> int:
    d = Path(args.dir)
    seal, pub = d / SEAL_NAME, d / PUBLIC_NAME
    if not seal.exists():
        sys.exit(f"FAIL  no seal at {seal}")
    info = json.loads(pub.read_text()) if pub.exists() else {}

    live = hashlib.sha256(seal.read_bytes()).hexdigest()
    if info.get("seal_sha256") and live != info["seal_sha256"]:
        sys.exit("FAIL  the seal file has changed since sealing. The blind is void.")

    sealed = json.loads(seal.read_text())
    mapping = sealed.get("mapping", sealed)   # tolerate the older flat layout
    by_app: dict[str, int] = {}
    print()
    for r in sealed.get("runs", []):
        print(f"  run: {r}")
    print()
    print(f"  {'clip_id':<24} {'uuid':<38} app")
    print("  " + "─" * 74)
    for u, m in sorted(mapping.items(), key=lambda kv: (kv[1]["clip_id"], kv[1]["app"])):
        print(f"  {m['clip_id']:<24} {u:<38} {m['app']}")
        by_app[m["app"]] = by_app.get(m["app"], 0) + 1
    print()
    for app, n in sorted(by_app.items()):
        print(f"  {app}: {n} transcripts")

    if pub.exists():
        info["unsealed"] = True
        info["unsealed_utc"] = datetime.datetime.now(datetime.UTC).isoformat()
        pub.write_text(json.dumps(info, indent=2), encoding="utf-8")
        print(f"\n  recorded the unseal in {pub.name} — this set is no longer blind.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("seal", help="write blinded transcripts + a sealed map")
    s.add_argument("--run", action="append", default=[], required=True,
                   help="a run directory; give it once per system")
    s.add_argument("--out", help="output directory (default out/blind-<timestamp>)")
    s.add_argument("--field", choices=["raw", "formatted"], default="raw",
                   help="raw = the accuracy field (default). formatted = decorative blinding.")
    s.set_defaults(fn=cmd_seal)

    u = sub.add_parser("unseal", help="reveal the uuid→app map (deliberate, recorded)")
    u.add_argument("--dir", required=True)
    u.set_defaults(fn=cmd_unseal)

    t = sub.add_parser("status", help="show a sealed set's metadata without revealing it")
    t.add_argument("--dir", required=True)
    t.set_defaults(fn=cmd_status)

    args = ap.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
