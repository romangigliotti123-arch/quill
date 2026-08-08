#!/usr/bin/env bash
#
# rig/read_quill.sh — pull one transcript out of Quill's history.
#
# ASSUMED CONTRACT (Quill is being written in parallel with this rig)
#
#   ~/Library/Application Support/Quill/history.json
#   a JSON array, NEWEST FIRST, each record having at least:
#     .text      the transcript string
#     .timeline  an object of moments (hotkeyDown, audioFirstBuffer,
#                firstPartial, finalTranscript, textInserted) matching
#                DictationTimeline in Sources/QuillKit/Support/Contracts.swift
#
# Nothing here guesses. If the file is missing, or is not an array, or record 0
# has no .text, the script says exactly what it found and exits non-zero. If
# Quill ships a different shape, THIS FILE is the one place to change.
#
# Flow records which mic it used; Quill has no equivalent column, so the
# device proof for a Quill run comes from run_eval.sh asserting the system
# input device before AND after every clip. Do not run this standalone and
# assume the audio path was correct.
#
# usage:
#   rig/read_quill.sh --mark FILE            # snapshot state (run BEFORE dictating)
#   rig/read_quill.sh --since FILE [--json]  # newest record, proven fresh
#   rig/read_quill.sh --latest [--json]      # newest record, no freshness proof
#   rig/read_quill.sh --probe                # describe the file's real shape

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

MODE=""; MARK_FILE=""; AS_JSON=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mark)    MODE=mark;   MARK_FILE="${2:?--mark needs a file}"; shift 2 ;;
        --since)   MODE=since;  MARK_FILE="${2:?--since needs a file}"; shift 2 ;;
        --latest)  MODE=latest; shift ;;
        --probe)   MODE=probe;  shift ;;
        --json)    AS_JSON=1; shift ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" "see: rig/read_quill.sh --help" ;;
    esac
done
[[ -n "$MODE" ]] || die "nothing to do" "see: rig/read_quill.sh --help"

if [[ ! -f "$QUILL_HISTORY" ]]; then
    die "Quill has no history file at $QUILL_HISTORY" \
        "Either Quill has never completed a dictation, or it writes its history" \
        "somewhere else than this rig assumes." \
        "fix:" \
        "  1. launch Quill, grant Accessibility + Microphone, dictate once by hand" \
        "  2. if it still does not appear, find the real path:" \
        "       ls -la ~/Library/Application\\ Support/Quill/" \
        "     and update QUILL_HISTORY in rig/lib/common.sh"
fi

run_py() {
    python3 - "$QUILL_HISTORY" "$MODE" "$MARK_FILE" <<'PY'
import hashlib, json, sys
from datetime import datetime

path, mode, mark_file = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    raw = open(path, encoding="utf-8").read()
except Exception as e:
    sys.exit(f"could not read {path}: {e}")

if not raw.strip():
    print(json.dumps({"error": "empty_file"})); sys.exit(0)

try:
    doc = json.loads(raw)
except json.JSONDecodeError as e:
    sys.exit(f"{path} is not valid JSON: {e}\n"
             f"      Quill may have been mid-write. Retry; if it persists, Quill is "
             f"writing non-atomically and should write to a temp file then rename.")

# Tolerate {"records": [...]} as well as a bare array — but say which was found.
if isinstance(doc, dict):
    for key in ("records", "history", "entries", "items"):
        if isinstance(doc.get(key), list):
            records, container = doc[key], f"object with .{key}"
            break
    else:
        print(json.dumps({"error": "unexpected_shape",
                          "found": "object", "keys": sorted(doc)[:12]})); sys.exit(0)
elif isinstance(doc, list):
    records, container = doc, "array"
else:
    print(json.dumps({"error": "unexpected_shape", "found": type(doc).__name__})); sys.exit(0)

def top_hash(recs):
    if not recs:
        return ""
    return hashlib.sha256(
        json.dumps(recs[0], sort_keys=True, default=str).encode()).hexdigest()[:16]

if mode == "probe":
    print(json.dumps({
        "container": container, "records": len(records),
        "record0_keys": sorted(records[0]) if records else [],
        "timeline_keys": sorted(records[0].get("timeline", {}))
                         if records and isinstance(records[0].get("timeline"), dict) else [],
    }, indent=2)); sys.exit(0)

if mode == "mark":
    open(mark_file, "w").write(json.dumps({"count": len(records), "top": top_hash(records)}))
    print(json.dumps({"marked": len(records)})); sys.exit(0)

if not records:
    print(json.dumps({"error": "no_records"})); sys.exit(0)

if mode == "since":
    try:
        prev = json.load(open(mark_file))
    except Exception as e:
        sys.exit(f"marker {mark_file} unreadable: {e}")
    # Either a record was appended, or the newest one changed. A capped history
    # can keep the count identical, so the hash is what actually proves freshness.
    if len(records) == prev.get("count") and top_hash(records) == prev.get("top"):
        print(json.dumps({"error": "no_new_record", "count": len(records)})); sys.exit(0)

rec = records[0]
if "text" not in rec:
    print(json.dumps({"error": "no_text_field", "record0_keys": sorted(rec)})); sys.exit(0)

# Timeline moments may be epoch seconds, epoch millis, or ISO-8601 strings
# depending on how Swift encoded Date. Handle all three rather than guessing.
def to_ms(v):
    if isinstance(v, (int, float)):
        return v * 1000.0 if v < 1e11 else float(v)
    if isinstance(v, str):
        try:
            return datetime.fromisoformat(v.replace("Z", "+00:00")).timestamp() * 1000.0
        except ValueError:
            return None
    return None

tl = rec.get("timeline") if isinstance(rec.get("timeline"), dict) else {}
moments = {k: to_ms(v) for k, v in tl.items()}

def span(a, b):
    x, y = moments.get(a), moments.get(b)
    return round(y - x) if x is not None and y is not None else None

latency = rec.get("endToEndMs") or span("hotkeyDown", "textInserted")

print(json.dumps({
    "text": rec.get("text"),
    "latency_ms": latency,
    "time_to_first_word_ms": rec.get("timeToFirstWordMs") or span("hotkeyDown", "firstPartial"),
    "final_to_inserted_ms": rec.get("finalToInsertedMs") or span("finalTranscript", "textInserted"),
    "timeline": tl,
    "records_total": len(records),
    "container": container,
}))
PY
}

RESULT="$(run_py)"

if [[ "$MODE" == "probe" || "$MODE" == "mark" ]]; then
    printf '%s\n' "$RESULT"
    exit 0
fi

err="$(printf '%s' "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("error",""))')"
case "$err" in
    no_new_record)
        die "Quill produced NO new transcript for this utterance." \
            "Likely causes, in order:" \
            "  1. Quill was not running, or its hotkey listener is not installed" \
            "  2. Accessibility / Microphone permission is missing — check with:" \
            "       open --env QUILL_DIAGNOSE=1 $QUILL_APP" \
            "  3. the rig held the wrong key (Quill's default is Right Option, code 61)" \
            "  4. Secure Input is on, which blocks every event tap" \
            "This clip has no result. Do not score the run as if it did." ;;
    no_records)   die "Quill's history.json is an empty list — no dictation has ever completed." ;;
    empty_file)   die "Quill's history.json is a zero-byte file." "fix: dictate once by hand and check it is written." ;;
    no_text_field)
        die "Quill's newest record has no .text field." \
            "found keys: $(printf '%s' "$RESULT" | python3 -c 'import json,sys; print(", ".join(json.load(sys.stdin).get("record0_keys",[])))')" \
            "fix: update the contract at the top of rig/read_quill.sh to match Quill." ;;
    unexpected_shape)
        die "Quill's history.json is not the expected array-of-records." \
            "found: $(printf '%s' "$RESULT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("found"), d.get("keys",""))')" \
            "fix: update the contract at the top of rig/read_quill.sh." ;;
esac

if (( AS_JSON )); then
    printf '%s\n' "$RESULT"
else
    printf '%s' "$RESULT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(f"  text        : {d.get(\"text\")!r}")
print(f"  e2e latency : {d.get(\"latency_ms\")} ms")
print(f"  ttfw        : {d.get(\"time_to_first_word_ms\")} ms")
print(f"  records     : {d.get(\"records_total\")}")'
fi
