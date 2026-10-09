#!/bin/sh
# The snapshot gate (design §4): build tests/programs/snapshot_gate.cho and
# assert its cases against a real store directory in /tmp. The cases:
#
#   take    — three snapshots; the ring advances 0, 1, 2
#   rescue  — snapshot once, corrupt the live file, restore: the content
#             is back, from the position before next (the §4 contract:
#             one bad edit must not block every other unit's work)
#   empty   — a store with nothing in it: restore answers empty and the
#             live file is not touched
#
# Exit 0 every case held; 1 the first that did not.
set -u

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }

root=$(cd "$(dirname "$0")/.." && pwd)
exe=$(mktemp -t cc-snap-XXXXXX)

"$CANCHO" build "$root/tests/programs/snapshot_gate.cho" "$root/src/snapshot.cho" \
    --std --backend cranelift -o "$exe" || { echo "gate did not build" >&2; exit 2; }

store=$(mktemp -d -t cc-store-XXXXXX)
fail=0

# Case 1: the ring advances.
printf 'fn one() -> [] int { return 1; }\n' > "$store/live.cho"
out=$("$exe" take "$store")
echo "$out"
[ "$out" = "take 0
take 1
take 2" ] || { echo "FAIL: take answered '$out'" >&2; fail=1; }
# The snapshots exist and hold the content.
[ -f "$store/snap0.cho" ] || { echo "FAIL: snap0 missing" >&2; fail=1; }

# Case 2: corrupt the live file, restore from the newest snapshot.
printf 'CORRUPTED MID-EDIT\n' > "$store/live.cho"
out=$("$exe" rescue "$store")
echo "$out"
[ "$out" = "restored 0" ] || { echo "FAIL: rescue answered '$out'" >&2; fail=1; }
# The content is back.
grep -q "fn one" "$store/live.cho" || { echo "FAIL: live file not restored" >&2; fail=1; }

# Case 3: an empty store answers empty, and does not touch the live file.
store2=$(mktemp -d -t cc-store2-XXXXXX)
printf 'fn live() -> [] int { return 0; }\n' > "$store2/live.cho"
out=$("$exe" empty "$store2")
echo "$out"
[ "$out" = "restored empty" ] || { echo "FAIL: empty answered '$out'" >&2; fail=1; }
grep -q "fn live" "$store2/live.cho" || { echo "FAIL: empty touched the live file" >&2; fail=1; }

rm -rf "$exe" "$store" "$store2"
[ "$fail" = 0 ] && echo "snapshot gate: ok" || { echo "snapshot gate: FAILED" >&2; exit 1; }
