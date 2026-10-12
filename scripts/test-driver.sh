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
    "$root/src/snapshot.cho" "$root/src/trail.cho" "$root/src/acceptance.cho" \
    --std --backend cranelift -o "$exe" || { echo "gate did not build" >&2; exit 2; }

fail=0

# The trail (parity P0): one JSON line per attempt in <project>.trail.jsonl, fields in this order:
#   {"attempt":N,"agent_ms":M,"outcome":"verified|refused|outage","sig":"...","decision":"..."}
# `tf LINE NAME` reads a plain string field, `tsig LINE` the signature (which may hold escaped quotes), `tint` an integer.
tf()   { printf '%s' "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p"; }
tint() { printf '%s' "$1" | sed -n "s/.*\"$2\":\([0-9][0-9]*\).*/\1/p"; }
tsig() { printf '%s' "$1" | sed -n 's/.*"sig":"\(.*\)","decision".*/\1/p'; }
tline() { sed -n "${2}p" "$1"; }
expect() { [ "$2" = "$3" ] || { echo "FAIL: trail $1: wanted '$3', got '$2'" >&2; fail=1; }; }
trail_shape() { # file ; every line is one well-formed record
    n=0
    while IFS= read -r l; do
        n=$((n + 1))
        expect "$1 line $n attempt" "$(tint "$l" attempt)" "$((n - 1))"
        case "$(tint "$l" agent_ms)" in ''|*[!0-9]*) echo "FAIL: trail $1 line $n has no integer agent_ms" >&2; fail=1 ;; esac
        case "$l" in '{"attempt":'*'}') ;; *) echo "FAIL: trail $1 line $n is not one record: $l" >&2; fail=1 ;; esac
    done < "$1"
}

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

t="$dir/project.cho.trail.jsonl"
[ -f "$t" ] || { echo "FAIL: fix wrote no trail" >&2; fail=1; }
if [ -f "$t" ]; then
    expect "fix lines" "$(wc -l < "$t" | tr -d ' ')" 1
    l=$(tline "$t" 1)
    expect "fix outcome" "$(tf "$l" outcome)" verified
    expect "fix decision" "$(tf "$l" decision)" verified
    expect "fix sig" "$(tsig "$l")" ""
    trail_shape "$t"
fi
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

t2="$dir2/project.cho.trail.jsonl"
[ -f "$t2" ] || { echo "FAIL: stuck wrote no trail" >&2; fail=1; }
if [ -f "$t2" ]; then
    expect "stuck lines" "$(wc -l < "$t2" | tr -d ' ')" 2
    l1=$(tline "$t2" 1); l2=$(tline "$t2" 2)
    expect "stuck 1 outcome" "$(tf "$l1" outcome)" refused
    expect "stuck 1 decision" "$(tf "$l1" decision)" retry
    expect "stuck 2 decision" "$(tf "$l2" decision)" signature
    [ -n "$(tsig "$l1")" ] || { echo "FAIL: stuck: empty signature" >&2; fail=1; }
    expect "stuck same signature" "$(tsig "$l2")" "$(tsig "$l1")"
    trail_shape "$t2"
fi

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

t3="$dir3/project.cho.trail.jsonl"
[ -f "$t3" ] || { echo "FAIL: ceiling wrote no trail" >&2; fail=1; }
if [ -f "$t3" ]; then
    expect "ceiling lines" "$(wc -l < "$t3" | tr -d ' ')" 4
    expect "ceiling last decision" "$(tf "$(tline "$t3" 4)" decision)" ceiling
    expect "ceiling 1 decision" "$(tf "$(tline "$t3" 1)" decision)" retry
    [ "$(tsig "$(tline "$t3" 1)")" != "$(tsig "$(tline "$t3" 2)")" ] || { echo "FAIL: ceiling: consecutive signatures are equal" >&2; fail=1; }
    trail_shape "$t3"
fi

rm -rf "$exe" "$dir" "$dir2" "$dir3"
[ "$fail" = 0 ] && echo "driver gate: ok" || { echo "driver gate: FAILED" >&2; exit 1; }
