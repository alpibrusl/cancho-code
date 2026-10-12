#!/bin/sh
# The agent contract gate (docs/parity.md P1): what the driver promises the agent and what it does when the agent misbehaves,
# one case per promise, each with a stand-in agent that is one line of shell (tests/programs/driver_gate.cho, mode `custom`).
#
#   env       the agent has no environment: no HOME (ollama panics without one), but the shell's default PATH finds sed and mktemp
#   exit      an agent that exits non-zero is named `unavailable agent` / `agent_exit` in the trail and the file is untouched
#
# Exit 0 every case held.
set -u

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }

root=$(cd "$(dirname "$0")/.." && pwd)
exe=$(mktemp -t cc-agent-XXXXXX)
"$CANCHO" build "$root/tests/programs/driver_gate.cho" "$root/src/driver.cho" "$root/src/checker.cho" \
    "$root/src/signature.cho" "$root/src/loop_check.cho" "$root/src/snapshot.cho" "$root/src/trail.cho" \
    --std --backend cranelift -o "$exe" || { echo "gate did not build" >&2; exit 2; }

fail=0
expect() { [ "$2" = "$3" ] || { echo "FAIL: $1: wanted '$3', got '$2'" >&2; fail=1; }; }

# A fresh project directory holding a file the checker refuses.
fresh() {
    d=$(mktemp -d -t cc-agent-d-XXXXXX)
    printf 'edition 7;\nfn broken() -> [] int { return true; }\n' > "$d/project.cho"
    cat >> "$d/project.cho" <<'FIX'
fn main(world: World) -> [] int {
    let Split { io, ffi, fs, heap, args, net, clock, signals, exec } = split(world);
    release(ffi); release(fs); release(net); release(clock); release(signals); release(exec); release(args);
    release(io); release(heap);
    return 0;
}
FIX
    echo "$d"
}

# env: the agent has no environment (cancho programs have none to pass): no HOME, which is why `ollama` panics without a line
# in the script that sets it; and the shell's own default PATH finds the tools a script needs. This pins what was measured.
d=$(fresh)
"$exe" custom "$CANCHO" "$d" "printf 'home=[%s]\n' \"\$HOME\" > $d/env.txt; command -v sed mktemp >> $d/env.txt" >/dev/null 2>&1
expect "env: HOME is not set for the agent" "$(sed -n 1p "$d/env.txt")" "home=[]"
expect "env: sed resolves" "$(sed -n 2p "$d/env.txt" | sed 's#.*/##')" sed
expect "env: mktemp resolves" "$(sed -n 3p "$d/env.txt" | sed 's#.*/##')" mktemp
rm -rf "$d"

# exit: an agent that fails is named, not read as a looping model, and the file is left as it was
d=$(fresh); before=$(cksum < "$d/project.cho")
out=$("$exe" custom "$CANCHO" "$d" "exit 3" 2>&1)
expect "exit: verdict" "$(printf '%s' "$out" | grep ISSUE_VERDICT)" "$(printf '[ISSUE_VERDICT]\tunavailable\tagent')"
t="$d/project.cho.trail.jsonl"
expect "exit: one record" "$(wc -l < "$t" | tr -d ' ')" 1
expect "exit: decision" "$(sed -n 's/.*"decision":"\([^"]*\)".*/\1/p' "$t")" agent_exit
expect "exit: file untouched" "$(cksum < "$d/project.cho")" "$before"
rm -rf "$d"

rm -f "$exe"
[ "$fail" = 0 ] && echo "agent gate: ok" || { echo "agent gate: FAILED" >&2; exit 1; }
