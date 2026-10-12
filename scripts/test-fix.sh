#!/bin/sh
# The front-door gate (docs/parity.md P1): the real `fix` program (tests/programs/fix.cho), end to end, with a shell stand-in as the
# agent. The module gates build their harness around the library; this one builds what a person runs, which is how a snapshot that
# was never written (its directory was never created) went unseen until a real run.
#
#   fixed     the agent repairs the file: `verified`, the trail has one record, and the verified state is snapshotted
#             as <project>.snap0.cho, equal to the file
#
# Exit 0 every case held.
set -u

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }

root=$(cd "$(dirname "$0")/.." && pwd)
exe=$(mktemp -t cc-fix-XXXXXX)
"$CANCHO" build "$root/tests/programs/fix.cho" "$root/src/driver.cho" "$root/src/checker.cho" \
    "$root/src/signature.cho" "$root/src/loop_check.cho" "$root/src/snapshot.cho" "$root/src/trail.cho" "$root/src/acceptance.cho" \
    --std --backend cranelift -o "$exe" || { echo "gate did not build" >&2; exit 2; }

fail=0
expect() { [ "$2" = "$3" ] || { echo "FAIL: $1: wanted '$3', got '$2'" >&2; fail=1; }; }

d=$(mktemp -d -t cc-fix-d-XXXXXX)
cat > "$d/fixed.cho" <<'FIX'
edition 7;
fn main(world: World) -> [] int {
    let Split { io, ffi, fs, heap, args, net, clock, signals, exec } = split(world);
    release(ffi); release(fs); release(net); release(clock); release(signals); release(exec); release(args);
    release(io); release(heap);
    return 0;
}
FIX
printf 'edition 7;\nfn broken() -> [] int { return true; }\n' > "$d/project.cho"
sed 1d "$d/fixed.cho" >> "$d/project.cho"

out=$("$exe" "$CANCHO" "$d/project.cho" "cp $d/fixed.cho" 4 2>&1)
expect "fixed: verdict" "$(printf '%s' "$out" | grep ISSUE_VERDICT | cut -f1,2)" "$(printf '[ISSUE_VERDICT]\tverified')"
expect "fixed: the trail has one record" "$(wc -l < "$d/project.cho.trail.jsonl" | tr -d ' ')" 1
[ -f "$d/project.cho.snap0.cho" ] || { echo "FAIL: fixed: the verified state was not snapshotted ($d/project.cho.snap0.cho)" >&2; fail=1; }
[ -f "$d/project.cho.snap0.cho" ] && expect "fixed: the snapshot is the verified file" "$(cat "$d/project.cho.snap0.cho")" "$(cat "$d/project.cho")"

# std: the checker `fix` runs knows the standard library, so a project can import it (the first acceptance runs on a task that wants
# an Option were refused `no module std.option in this program` by the loop's own checker, because the command had no --std)
d2=$(mktemp -d -t cc-fix-std-XXXXXX)
printf 'edition 7;\nimport std.option;\nfn broken() -> [] option.Option[int] { return true; }\n' > "$d2/project.cho"
sed 1d "$d/fixed.cho" >> "$d2/project.cho"
cat > "$d2/good.cho" <<'GOOD'
edition 7;
import std.option;
fn pick() -> [] option.Option[int] { return option.Option::Some(1); }
fn main(world: World) -> [] int {
    let Split { io, ffi, fs, heap, args, net, clock, signals, exec } = split(world);
    release(ffi); release(fs); release(net); release(clock); release(signals); release(exec); release(args);
    release(io); release(heap);
    let p = pick();
    return 0;
}
GOOD
out=$("$exe" "$CANCHO" "$d2/project.cho" "cp $d2/good.cho" 4 2>&1)
expect "std: a project that imports std.option verifies" "$(printf '%s' "$out" | grep ISSUE_VERDICT | cut -f1,2)" "$(printf '[ISSUE_VERDICT]\tverified')"
rm -rf "$d2"

rm -rf "$exe" "$d"
[ "$fail" = 0 ] && echo "front door gate: ok" || { echo "front door gate: FAILED" >&2; exit 1; }
