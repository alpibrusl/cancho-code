#!/bin/sh
# The trail gate (docs/parity.md P0): trail.begin and trail.record alone, against a real file.
#
#   plain    two records, each line a valid JSON object with the documented fields in order
#   hostile  a signature with a quote, a backslash and a newline byte stays ONE line and round-trips through a JSON parser
#   restart  `begin` empties the file: a second run does not append to the first
#   cap      a record past the cap answers -1 and leaves no partial line
#
# Needs python3 (only to parse each line as JSON: the point of the hostile case).
set -u

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "no python3 on PATH" >&2; exit 2; }

root=$(cd "$(dirname "$0")/.." && pwd)
exe=$(mktemp -t cc-trail-XXXXXX)
"$CANCHO" build "$root/tests/programs/trail_gate.cho" "$root/src/trail.cho" "$root/src/acceptance.cho" \
    --std -o "$exe" || { echo "gate did not build" >&2; exit 2; }

dir=$(mktemp -d -t cc-trail-d-XXXXXX)
fail=0
expect() { [ "$2" = "$3" ] || { echo "FAIL: $1: wanted '$3', got '$2'" >&2; fail=1; }; }

# Parse the trail as JSON lines; print "lines=N" then each record's fields tab-separated.
parse() {
    python3 - "$1" <<'PY'
import json, sys
lines = open(sys.argv[1], encoding="utf-8", newline="").read().split("\n")
assert lines[-1] == "", "the file does not end in a newline"
recs = [json.loads(l) for l in lines[:-1]]
print("lines=%d" % len(recs))
for r in recs:
    assert list(r) == ["attempt", "agent_ms", "outcome", "sig", "decision"], list(r)
    print("%d\t%d\t%s\t%s\t%s" % (r["attempt"], r["agent_ms"], r["outcome"], r["sig"].replace("\n", "\\n"), r["decision"]))
PY
}

# plain
out=$("$exe" plain "$dir/plain.jsonl" | tr '\n' ' ')
expect "plain: record answers" "$out" "0 0 "
got=$(parse "$dir/plain.jsonl" 2>&1)
expect "plain: lines" "$(printf '%s\n' "$got" | sed -n 1p)" "lines=2"
expect "plain: record 1" "$(printf '%s\n' "$got" | sed -n 2p)" "$(printf '0\t12\trefused\ttype-mismatch:expected `int`, found `bool`\tretry')"
expect "plain: record 2" "$(printf '%s\n' "$got" | sed -n 3p)" "$(printf '1\t0\tverified\t\tverified')"

# hostile
out=$("$exe" hostile "$dir/hostile.jsonl" | tr '\n' ' ')
expect "hostile: record answers" "$out" "0 "
expect "hostile: one physical line" "$(wc -l < "$dir/hostile.jsonl" | tr -d ' ')" 1
got=$(parse "$dir/hostile.jsonl" 2>&1)
# the quote and the backslash survive exactly; the newline byte is replaced by a space (control bytes are not kept)
expect "hostile: signature" "$(printf '%s\n' "$got" | sed -n 2p)" "$(printf '0\t7\trefused\ta "quoted" word, a back\\slash, a second line\tretry')"

# restart
"$exe" restart "$dir/restart.jsonl" >/dev/null
got=$(parse "$dir/restart.jsonl" 2>&1)
expect "restart: lines" "$(printf '%s\n' "$got" | sed -n 1p)" "lines=1"
expect "restart: the first run is gone" "$(printf '%s\n' "$got" | sed -n 2p)" "$(printf '0\t2\tverified\t\tverified')"

# cap
out=$("$exe" cap "$dir/cap.jsonl" | tr '\n' ' ')
expect "cap: record answers" "$out" "-1 "
expect "cap: nothing partial was written" "$(wc -c < "$dir/cap.jsonl" | tr -d ' ')" 0

rm -rf "$exe" "$dir"
[ "$fail" = 0 ] && echo "trail gate: ok" || { echo "trail gate: FAILED" >&2; exit 1; }
