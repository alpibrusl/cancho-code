#!/bin/sh
# The agent contract gate (docs/parity.md P1): what the driver promises the agent and what it does when the agent misbehaves,
# one case per promise, each with a stand-in agent that is one line of shell (tests/programs/driver_gate.cho, mode `custom`).
#
#   env       the agent has no environment: no HOME (ollama panics without one), but the shell's default PATH finds sed and mktemp
#   timeout   the agent's turn is capped by an argument, not a constant
#   feedback  the checker's answer reaches the agent as <project>.feedback before every turn, the first one included
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

# timeout: the agent's turn is capped by the 5th argument (ms), not by a constant; a slower agent under a longer cap still works
d=$(fresh); start=$(date +%s)
out=$("$exe" custom "$CANCHO" "$d" "sleep 5" 1000 2>&1); took=$(( $(date +%s) - start ))
expect "timeout: verdict" "$(printf '%s' "$out" | grep ISSUE_VERDICT)" "$(printf '[ISSUE_VERDICT]\tunavailable\tagent')"
[ "$took" -lt 4 ] || { echo "FAIL: timeout: took ${took}s under a 1 s cap" >&2; fail=1; }
expect "timeout: decision" "$(sed -n 's/.*"decision":"\([^"]*\)".*/\1/p' "$d/project.cho.trail.jsonl")" agent_timeout
rm -rf "$d"
d=$(fresh)
printf 'edition 7;\nfn main(world: World) -> [] int {\n    let Split { io, ffi, fs, heap, args, net, clock, signals, exec } = split(world);\n    release(ffi); release(fs); release(net); release(clock); release(signals); release(exec); release(args);\n    release(io); release(heap);\n    return 0;\n}\n' > "$d/fixed.cho"
out=$("$exe" custom "$CANCHO" "$d" "sleep 1; cp $d/fixed.cho $d/project.cho" 10000 2>&1)
expect "timeout: a slow agent under a long cap verifies" "$(printf '%s' "$out" | grep ISSUE_VERDICT | cut -f1,2)" "$(printf '[ISSUE_VERDICT]\tverified')"
rm -rf "$d"

# feedback: before every agent turn the driver writes the checker's current answer to <project>.feedback, so the agent can show a model
# what the compiler refused. Turn 0 already has it (the driver checks the seed before the first turn); a stuck agent runs twice.
d=$(fresh)
"$exe" custom "$CANCHO" "$d" "cat $d/project.cho.feedback >> $d/probe.txt" >/dev/null 2>&1
want=$("$CANCHO" check --output json --backend cranelift "$d/project.cho" 2>&1); want="$want
$want"
got=$(cat "$d/probe.txt" 2>/dev/null)
[ -n "$got" ] || { echo "FAIL: feedback: the agent saw nothing" >&2; fail=1; }
expect "feedback: the agent saw the checker's answer, on both turns" "$got" "$want"
case "$got" in *type-mismatch*) ;; *) echo "FAIL: feedback: no refusal in what the agent saw" >&2; fail=1 ;; esac
rm -rf "$d"

rm -f "$exe"
[ "$fail" = 0 ] && echo "agent gate: ok" || { echo "agent gate: FAILED" >&2; exit 1; }
