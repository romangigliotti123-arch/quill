#!/usr/bin/env bash
#
# rig/read_quill.sh — pull one transcript out of Quill's history.
#
# CONTRACT — verified against a real history.json on 2026-08-09
#
#   ~/Library/Application Support/Quill/history.json
#   a JSON array, NEWEST FIRST, each record:
#     .id            UUID string — used to prove a transcript is new
#     .date          ISO-8601 (e.g. "2026-08-09T00:14:25Z")
#     .rawText       transcript as recognised      → the ACCURACY field
#     .insertedText  transcript as actually typed  → the post-cleanup field
#     .wordCount     int
#     .timings       { endToEndMs, timeToFirstWordMs, finalToInsertedMs,
#                      usedThoroughCleanup }
#
# rawText pairs with Flow's asrText and insertedText pairs with Flow's
# formattedText, so the accuracy column compares raw against raw and the
# formatting column compares cleaned against cleaned. Mixing those two is the
# easiest way to accidentally publish a number that measures text cleanup.
#
# The earlier assumed shape (.text / .timeline) is still accepted, because this
# rig was written before Quill existed and nothing is gained by breaking if it
# reverts. Anything else fails loudly with the keys it actually found.
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

MODE=""; MARK_FILE=""; AS_JSON=0; EXPECT_DEVICE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mark)    MODE=mark;   MARK_FILE="${2:?--mark needs a file}"; shift 2 ;;
        --since)   MODE=since;  MARK_FILE="${2:?--since needs a file}"; shift 2 ;;
        --latest)  MODE=latest; shift ;;
        --probe)   MODE=probe;  shift ;;
        --json)    AS_JSON=1; shift ;;
        # Mirrors read_flow.sh. Quill records the microphone it actually used, so
        # a run through the loopback device can be audited the same way Flow's is:
        # if this says Built-in when the rig was playing into BlackHole, the app
        # never heard the test audio and the run is void.
        --expect-device) EXPECT_DEVICE="${2-}"; shift 2 ;;
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
    python3 - "$QUILL_HISTORY" "$MODE" "$MARK_FILE" "$EXPECT_DEVICE" <<'PY'
import hashlib, json, sys
from datetime import datetime

path, mode, mark_file = sys.argv[1], sys.argv[2], sys.argv[3]
expect_device = sys.argv[4] if len(sys.argv) > 4 else ""

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

def ident(rec):
    """A stable identity for a record: its id if it has one, else a hash."""
    if isinstance(rec.get("id"), str):
        return rec["id"]
    return hashlib.sha256(
        json.dumps(rec, sort_keys=True, default=str).encode()).hexdigest()[:16]

if mode == "probe":
    r0 = records[0] if records else {}
    print(json.dumps({
        "container": container, "records": len(records),
        "record0_keys": sorted(r0),
        "timings_keys": sorted(r0.get("timings", {})) if isinstance(r0.get("timings"), dict) else [],
        "timeline_keys": sorted(r0.get("timeline", {})) if isinstance(r0.get("timeline"), dict) else [],
        "newest_date": r0.get("date"),
        "oldest_date": records[-1].get("date") if records else None,
    }, indent=2)); sys.exit(0)

if mode == "mark":
    open(mark_file, "w").write(json.dumps(
        {"count": len(records), "ids": [ident(r) for r in records]}))
    print(json.dumps({"marked": len(records)})); sys.exit(0)

if not records:
    print(json.dumps({"error": "no_records"})); sys.exit(0)

if mode == "since":
    try:
        prev = json.load(open(mark_file))
    except Exception as e:
        sys.exit(f"marker {mark_file} unreadable: {e}")
    known = set(prev.get("ids") or [])
    fresh = [r for r in records if ident(r) not in known]
    if not fresh:
        print(json.dumps({"error": "no_new_record", "count": len(records)})); sys.exit(0)
    # Records are newest-first, so the first unseen one is the newest unseen one.
    rec = fresh[0]
else:
    rec = records[0]

# rawText is the accuracy field. `.text` is the older assumed name.
raw = rec.get("rawText") if rec.get("rawText") is not None else rec.get("text")
if raw is None:
    print(json.dumps({"error": "no_text_field", "record0_keys": sorted(rec)})); sys.exit(0)

def to_ms(v):
    """Timeline moments may be epoch seconds, epoch millis, or ISO-8601."""
    if isinstance(v, (int, float)):
        return v * 1000.0 if v < 1e11 else float(v)
    if isinstance(v, str):
        try:
            return datetime.fromisoformat(v.replace("Z", "+00:00")).timestamp() * 1000.0
        except ValueError:
            return None
    return None

timings = rec.get("timings") if isinstance(rec.get("timings"), dict) else {}
tl = rec.get("timeline") if isinstance(rec.get("timeline"), dict) else {}
moments = {k: to_ms(v) for k, v in tl.items()}

def span(a, b):
    x, y = moments.get(a), moments.get(b)
    return round(y - x) if x is not None and y is not None else None

def pick(key, a, b):
    v = timings.get(key)
    return v if v is not None else span(a, b)

device = rec.get("inputDevice")

# The audit gate. A transcript from an app that was listening to the room while
# the rig played into a loopback device produces a perfectly plausible WER that
# means nothing. Refuse it loudly rather than let it into a results table.
if expect_device:
    if device is None:
        print(json.dumps({
            "error": "no_input_device_field",
            "detail": ("this Quill build does not record inputDevice, so the run "
                       "cannot be audited — rebuild from a commit that includes it"),
        })); sys.exit(3)
    if expect_device.lower() not in device.lower():
        print(json.dumps({
            "error": "wrong_input_device",
            "expected": expect_device, "actual": device,
            "detail": ("Quill heard a different microphone than the rig played into, "
                       "so this transcript is not evidence of anything"),
        })); sys.exit(3)

print(json.dumps({
    "text": raw,
    "text_inserted": rec.get("insertedText") or "",
    "input_device": device,
    "latency_ms":            pick("endToEndMs",        "hotkeyDown",      "textInserted"),
    "time_to_first_word_ms": pick("timeToFirstWordMs", "hotkeyDown",      "firstPartial"),
    "final_to_inserted_ms":  pick("finalToInsertedMs", "finalTranscript", "textInserted"),
    "used_thorough_cleanup": timings.get("usedThoroughCleanup"),
    "word_count": rec.get("wordCount"),
    "id": rec.get("id"),
    "date": rec.get("date"),
    "timings": timings or tl,
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
            "history held $(printf '%s' "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("count","?"))') records, none of them unseen since the mark." \
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
print("  rawText     : %r"   % (d.get("text"),))
if (d.get("text_inserted") or "") and d.get("text_inserted") != d.get("text"):
    print("  inserted    : %r" % (d.get("text_inserted"),))
print("  e2e latency : %s ms" % (d.get("latency_ms"),))
print("  ttfw        : %s ms" % (d.get("time_to_first_word_ms"),))
print("  date        : %s"    % (d.get("date"),))
print("  records     : %s"    % (d.get("records_total"),))'
fi
