#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["jiwer==4.0.0", "whisper-normalizer==0.1.15"]
# ///
import json, pathlib, jiwer
from whisper_normalizer.english import EnglishTextNormalizer
root=pathlib.Path("/Users/romangigliotti/Documents/Work/Projects/quill/rig")
scr=pathlib.Path("/private/tmp/claude-501/-Users-romangigliotti-Documents-Work/ff2783c0-c086-4aa7-bf48-bbc7a83a9bb4/scratchpad")
truth={}
for line in (root/"corpus_manifest.tsv").read_text().splitlines():
    if line.startswith("#") or line.startswith("clip_id") or not line.strip(): continue
    p=line.split("\t"); truth[p[0]]=p[5]
rows=[json.loads(l) for l in (scr/"engines.jsonl").read_text().splitlines() if l.strip()]
by={}
for r in rows: by.setdefault(r["engine"], {})[r["clip"]]=r
common=sorted(set.intersection(*[set(v) for v in by.values()]) & set(truth))
norm=EnglishTextNormalizer()
refs=[norm(truth[c]) for c in common]
words=sum(len(r.split()) for r in refs)
print(f"{len(common)} clips, {words} reference words, leading silence trimmed\n")
print(f'{"engine":<24}{"WER":>8}{"errors":>8}{"first result median":>22}')
for eng, d in by.items():
    out=jiwer.process_words(refs, [norm(d[c]["text"]) for c in common])
    lat=sorted(d[c]["first_ms"] for c in common if d[c].get("first_ms"))
    med=lat[len(lat)//2] if lat else None
    errs=out.substitutions+out.deletions+out.insertions
    print(f'{eng:<24}{out.wer*100:7.2f}%{errs:8d}{(str(med)+"ms"):>22}')
