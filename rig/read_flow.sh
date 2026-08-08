#!/usr/bin/env bash
#
# rig/read_flow.sh — pull one transcript out of Wispr Flow's history.
#
# THE ASSERTION THAT MATTERS
#
# Flow records which microphone produced each transcript in History.micDevice.
# If that column does not say BlackHole, then Flow was listening to the built-in
# mic while the rig played audio somewhere else, and whatever text came back is
# either the room, the previous utterance, or nothing. This script exits non-zero
# in that case, every time, with no override that quietly disables the check.
#
# That single column is the rig's proof that it is not measuring silence.
#
# usage:
#   rig/read_flow.sh --mark FILE                  # snapshot known rows (run BEFORE dictating)
#   rig/read_flow.sh --since FILE [--json]        # newest row not in FILE, asserted
#   rig/read_flow.sh --latest [--json]            # newest row, no freshness guarantee
#   rig/read_flow.sh --schema                     # dump the History columns we rely on
#
#   --expect-device SUBSTR   what micDevice must contain (default: BlackHole).
#                            Only for the human-voice corpus, where the real mic
#                            is correct. Prints a loud banner when overridden.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

MODE=""
MARK_FILE=""
AS_JSON=0
EXPECT_DEVICE="$BLACKHOLE_MATCH"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mark)           MODE=mark;   MARK_FILE="${2:?--mark needs a file}"; shift 2 ;;
        --since)          MODE=since;  MARK_FILE="${2:?--since needs a file}"; shift 2 ;;
        --latest)         MODE=latest; shift ;;
        --schema)         MODE=schema; shift ;;
        --json)           AS_JSON=1; shift ;;
        --expect-device)  EXPECT_DEVICE="${2:?--expect-device needs a substring}"; shift 2 ;;
        -h|--help)        sed -n '2,25p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" "see: rig/read_flow.sh --help" ;;
    esac
done
[[ -n "$MODE" ]] || die "nothing to do" "see: rig/read_flow.sh --help"

[[ -f "$FLOW_DB" ]] || die "Wispr Flow's database is not at $FLOW_DB" \
    "Flow has never run, or has never completed a dictation." \
    "fix: open Wispr Flow, sign in, and dictate once by hand."

# ── snapshot ──────────────────────────────────────────────────────────────────
#
# flow.sqlite is a WAL database that Flow writes to live. Reading it directly
# races the writer; copying just the .sqlite loses everything still in the -wal.
# `.backup` is the sanctioned way to take a consistent point-in-time copy of a
# WAL database — it reads the main file and the WAL together under the right
# locks. The three-file copy is kept as a fallback for when Flow holds a lock
# `.backup` will not wait out.

SNAP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/flowsnap.XXXXXX")"
trap 'rm -rf "$SNAP_DIR"' EXIT
SNAP="$SNAP_DIR/flow.sqlite"

snapshot() {
    if sqlite3 "file:${FLOW_DB}?mode=ro" ".backup '$SNAP'" 2>/dev/null; then
        return 0
    fi
    warn "sqlite .backup failed (Flow may be mid-write); falling back to a three-file copy"
    cp "$FLOW_DB" "$SNAP" 2>/dev/null || die "could not read $FLOW_DB"
    [[ -f "$FLOW_DB-wal" ]] && cp "$FLOW_DB-wal" "$SNAP-wal" || true
    [[ -f "$FLOW_DB-shm" ]] && cp "$FLOW_DB-shm" "$SNAP-shm" || true
}
snapshot

if [[ "$MODE" == "schema" ]]; then
    sqlite3 "$SNAP" "PRAGMA table_info(History);" \
        | awk -F'|' '{print "  " $2 "  (" $3 ")"}' \
        | grep -E "asrText|formattedText|timestamp|micDevice|numWords|duration|e2eLatency|status|transcriptEntityId|appVersion"
    exit 0
fi

# Rows with a NULL status are placeholders Flow creates before a dictation
# resolves; they are not transcripts and must never be returned as one.
REAL_ROW="status IS NOT NULL AND TRIM(COALESCE(status,'')) != ''"

if [[ "$MODE" == "mark" ]]; then
    sqlite3 "$SNAP" "SELECT transcriptEntityId FROM History WHERE $REAL_ROW;" > "$MARK_FILE"
    info "marked $(wc -l < "$MARK_FILE" | tr -d ' ') existing Flow rows → $MARK_FILE"
    exit 0
fi

# ── select the row ────────────────────────────────────────────────────────────

MARK_ARG=""
if [[ "$MODE" == "since" ]]; then
    [[ -f "$MARK_FILE" ]] || die "marker file $MARK_FILE does not exist" \
        "fix: call rig/read_flow.sh --mark $MARK_FILE BEFORE dictating."
    MARK_ARG="$MARK_FILE"
fi

RESULT="$(python3 - "$SNAP" "$MODE" "$MARK_ARG" "$REAL_ROW" <<'PY'
import json, sqlite3, sys

snap, mode, mark_file, real_row = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

con = sqlite3.connect(f"file:{snap}?mode=ro", uri=True)
con.row_factory = sqlite3.Row
cols = ("transcriptEntityId, timestamp, micDevice, asrText, formattedText, "
        "numWords, duration, e2eLatency, status, appVersion, language")

if mode == "since":
    with open(mark_file, encoding="utf-8") as fh:
        known = {l.strip() for l in fh if l.strip()}
    rows = con.execute(
        f"SELECT {cols} FROM History WHERE {real_row} ORDER BY timestamp DESC"
    ).fetchall()
    fresh = [r for r in rows if r["transcriptEntityId"] not in known]
    if not fresh:
        print(json.dumps({"error": "no_new_row", "known": len(known), "total": len(rows)}))
        sys.exit(0)
    row = fresh[0]
    extra = {"new_rows_since_mark": len(fresh)}
else:
    row = con.execute(
        f"SELECT {cols} FROM History WHERE {real_row} ORDER BY timestamp DESC LIMIT 1"
    ).fetchone()
    if row is None:
        print(json.dumps({"error": "no_rows"}))
        sys.exit(0)
    extra = {}

out = {k: row[k] for k in row.keys()}
out.update(extra)
print(json.dumps(out))
PY
)"

err="$(printf '%s' "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("error",""))')"

case "$err" in
    no_new_row)
        die "Flow produced NO new transcript for this utterance." \
            "The dictation never registered. Common causes, in order of likelihood:" \
            "  1. Flow's push-to-talk key is not the one the rig is holding" \
            "     (check Flow › Settings › Shortcuts, and rig/run_eval.sh --ptt-key)" \
            "  2. Flow is not signed in — it is cloud-only and stores nothing when signed out" \
            "  3. Flow was not running, or was still starting up" \
            "  4. the hold was shorter than Flow's minimum utterance length" \
            "This clip has no result. Do not score the run as if it did." ;;
    no_rows)
        die "Flow's History table has no completed transcripts at all." \
            "fix: open Wispr Flow, sign in, dictate one sentence by hand, then re-run." ;;
esac

MIC="$(printf '%s' "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("micDevice") or "")')"

# ── THE assertion ─────────────────────────────────────────────────────────────

if ! printf '%s' "$MIC" | grep -qi -- "$EXPECT_DEVICE"; then
    die "Flow recorded this transcript from '${MIC:-<empty>}', not '$EXPECT_DEVICE'." \
        "" \
        "THE RUN IS INVALID. Flow was listening to a different device than the one" \
        "the rig played into, so this text did not come from the clip. Scoring it" \
        "would produce a number that looks real and means nothing." \
        "" \
        "fix:" \
        "  1. System Settings › Sound › Input → select $EXPECT_DEVICE" \
        "  2. Wispr Flow › Settings → set its microphone to $EXPECT_DEVICE too;" \
        "     Flow keeps its OWN device preference and does not always follow the" \
        "     system default. This is the usual cause." \
        "  3. re-run the whole run. Do not splice results."
fi

if [[ "$EXPECT_DEVICE" != "$BLACKHOLE_MATCH" ]]; then
    warn "device assertion was relaxed to '$EXPECT_DEVICE' (not $BLACKHOLE_MATCH) —"
    warn "valid ONLY for the spoken-voice corpus, never for the LibriSpeech run."
fi

if (( AS_JSON )); then
    printf '%s\n' "$RESULT"
else
    printf '%s' "$RESULT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(f"  timestamp   : {d.get(\"timestamp\")}")
print(f"  micDevice   : {d.get(\"micDevice\")}")
print(f"  words       : {d.get(\"numWords\")}   duration: {d.get(\"duration\")}s   e2e: {d.get(\"e2eLatency\")}ms")
print(f"  asrText     : {d.get(\"asrText\")!r}")
print(f"  formatted   : {d.get(\"formattedText\")!r}")'
fi
