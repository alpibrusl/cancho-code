#!/bin/sh
# The driver gate (design §3, §7.1): the whole loop — stand-in agent, real
# `cancho check`, the §4 budgets, the re-verify pass, the snapshot —
# in three cases:
#
#   fix     — the agent repairs the file; the loop answers
#              `[ISSUE_VERDICT]  verified  attempts 1`
#   stuck   — the agent does nothing; the same refusal repeats and the
#              same-signature stop ends it: `failed signature`
#   ceiling — the agent writes a different broken file each turn; the
#              signature rule cannot fire and the ceiling does:
#              `failed ceiling`
#
# The tab-separated verdict lines are the design's §6 shape; the harness
# greps them exactly. Every fixture carries an `edition 7;` line and a
# `main` (measured, twice: `cancho check` refuses a file without a main,
# and refuses the nine-field `Split` without the edition — so a fixed but
# edition-less or mainless fixture is still a refused fixture).
set -u

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }

root=$(cd "$(dirname "$0")/.." && pwd)
exe=$(mktemp -t cc-drv-XXXXXX)

"$CANCHO" build "$root/tests/programs/driver_gate.cho" "$root/src/driver.cho" \
    "$root/src/checker.cho" "$root/src/signature.cho" "$root/src/loop_check.cho" \
    "$root/src/snapshot.cho" \
    --std --backend cranelift -o "$exe" || { echo "gate did not build" >&2; exit 2; }

fail=0

# Case 1: the agent fixes it on the first turn.
dir=$(mktemp -d -t cc-drv1-XXXXXX)
printf 'edition 7;\nfn broken() -> [] int { return true; }\n' > "$dir/project.cho"
printf 'edition 7;\nfn broken() -> [] int { return 1; }\n' > "$dir/fixed.cho"
cat >> "$dir/project.cho" <<'FIX'
fn main(world: World) -> [] int {
    let Split { io, ffi, fs, heap, args, net, clock, signals, exec } = split(world);
    release(ffi); release(fs); release(net); release(clock); release(signals); release(exec); release(args);
    release(io); release(heap);
    return 0;
}
FIX
cat >> "$dir/fixed.cho" <<'FIX'
fn main(world: World) -> [] int {
    let Split { io, ffi, fs, heap, args, net, clock, signals, exec } = split(world);
    release(ffi); release(fs); release(net); release(clock); release(signals); release(exec); release(args);
    release(io); release(heap);
    return 0;
}
FIX
out=$("$exe" fix "$CANCHO" "$dir")
echo "$out"
echo "$out" | grep -q '\[ISSUE_VERDICT\]\s*verified\s*attempts 1' || { echo "FAIL: fix answered '$out'" >&2; fail=1; }
# The verified state was snapshotted (§4).
[ -f "$dir/snap0.cho" ] || { echo "FAIL: verified state not snapshotted" >&2; fail=1; }
grep -q "return 1" "$dir/snap0.cho" || { echo "FAIL: snapshot holds the wrong content" >&2; fail=1; }

# Case 2: the looping agent stops at the signature rule.
dir2=$(mktemp -d -t cc-drv2-XXXXXX)
printf 'edition 7;\nfn broken() -> [] int { return true; }\n' > "$dir2/project.cho"
cat >> "$dir2/project.cho" <<'FIX'
fn main(world: World) -> [] int {
    let Split { io, ffi, fs, heap, args, net, clock, signals, exec } = split(world);
    release(ffi); release(fs); release(net); release(clock); release(signals); release(exec); release(args);
    release(io); release(heap);
    return 0;
}
FIX
out=$("$exe" stuck "$CANCHO" "$dir2")
echo "$out"
echo "$out" | grep -q '\[ISSUE_VERDICT\]\s*failed\s*signature' || { echo "FAIL: stuck answered '$out'" >&2; fail=1; }

# Case 3: the cycling agent stops at the ceiling.
dir3=$(mktemp -d -t cc-drv3-XXXXXX)
printf 'edition 7;\nfn broken() -> [] int { return true; }\n' > "$dir3/project.cho"
cat >> "$dir3/project.cho" <<'FIX'
fn main(world: World) -> [] int {
    let Split { io, ffi, fs, heap, args, net, clock, signals, exec } = split(world);
    release(ffi); release(fs); release(net); release(clock); release(signals); release(exec); release(args);
    release(io); release(heap);
    return 0;
}
FIX
out=$("$exe" ceiling "$CANCHO" "$dir3")
echo "$out"
echo "$out" | grep -q '\[ISSUE_VERDICT\]\s*failed\s*ceiling' || { echo "FAIL: ceiling answered '$out'" >&2; fail=1; }

rm -rf "$exe" "$dir" "$dir2" "$dir3"
[ "$fail" = 0 ] && echo "driver gate: ok" || { echo "driver gate: FAILED" >&2; exit 1; }
