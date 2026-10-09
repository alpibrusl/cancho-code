#!/bin/sh
# The checker gate (design §7.1): build tests/programs/checker_gate.cho and
# assert its three cases against the real `cancho check` binary. Each case
# prints one line:
#     case <verified|retryable|provider_outage> [signed]
#
#   ok      — a clean program answers verified
#   bad     — a refused program answers retryable signed
#   silent  — a checker that never answers (sleep, 1ms) answers provider_outage
#              — a wait, not a failure (design §4)
#
# Exit 0 every case held; 1 the first that did not. No hang can outlive this
# script: every case has its own deadline in the gate itself.
set -u

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }

root=$(cd "$(dirname "$0")/.." && pwd)
exe=$(mktemp -t cc-gate-XXXXXX)

# The gate runs the checker by its absolute path (given as argv[2]), so no
# PATH is involved: the child gets the exact program, which is the Exec
# story anyway — and measured on this gate, the child of exec_spawn has
# no PATH of its own to search (processes.md §4.3: the environment is
# exactly what is passed).

"$CANCHO" build "$root/tests/programs/checker_gate.cho" "$root/src/checker.cho" \
    "$root/src/signature.cho" "$root/src/loop_check.cho" \
    --std --backend cranelift -o "$exe" || { echo "gate did not build" >&2; exit 2; }

ok_file=/tmp/cc_gate_ok.cho
bad_file=/tmp/cc_gate_bad.cho

cat > "$ok_file" <<'FIX'
edition 7;
fn main(world: World) -> [] int {
    let Split { io, ffi, fs, heap, args, net, clock, signals, exec } = split(world);
    release(ffi); release(fs); release(net); release(clock); release(signals); release(exec); release(args);
    release(io); release(heap);
    return 0;
}
FIX

cat > "$bad_file" <<'FIX'
edition 7;
fn broken() -> [] int { return true; }
fn main(world: World) -> [] int {
    let Split { io, ffi, fs, heap, args, net, clock, signals, exec } = split(world);
    release(ffi); release(fs); release(net); release(clock); release(signals); release(exec); release(args);
    release(io); release(heap);
    return 0;
}
FIX

fail=0

line=$("$exe" ok "$CANCHO") || fail=1
echo "$line"
[ "$line" = "case verified" ] || { echo "FAIL: ok answered '$line'" >&2; fail=1; }

line=$("$exe" bad "$CANCHO") || fail=1
echo "$line"
[ "$line" = "case retryable signed" ] || { echo "FAIL: bad answered '$line'" >&2; fail=1; }

line=$("$exe" silent "$CANCHO") || fail=1
echo "$line"
[ "$line" = "case provider_outage" ] || { echo "FAIL: silent answered '$line'" >&2; fail=1; }

rm -f "$exe" "$ok_file" "$bad_file"
[ "$fail" = 0 ] && echo "checker gate: ok" || { echo "checker gate: FAILED" >&2; exit 1; }
