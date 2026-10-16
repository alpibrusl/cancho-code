#!/bin/sh
# The agent contract gate (docs/parity.md P1): what the driver promises the agent and what it does when the agent misbehaves,
# one case per promise, each with a stand-in agent that is one line of shell (tests/programs/driver_gate.cho, mode `custom`).
#
#   env       the agent has no environment: no HOME (ollama panics without one), but the shell's default PATH finds sed and mktemp
#   timeout   the agent's turn is capped by an argument, not a constant
#   feedback  the checker's answer reaches the agent as <project>.feedback before every turn, the first one included
#   exit      an agent that exits non-zero is named `unavailable agent` / `agent_exit` in the trail and the file is untouched
#   gave up   exit 10, 11, 12 (documented) mean the agent reached the model and had no usable answer: a retryable failure with a named signature
#             (`agent:gave-up:cut-off|no-program|splice`) under the signature stop and the ceiling; every other non-zero exit is still `unavailable`
#
# Exit 0 every case held.
set -u

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }

root=$(cd "$(dirname "$0")/.." && pwd)
exe=$(mktemp -t cc-agent-XXXXXX)
"$CANCHO" build "$root/tests/programs/driver_gate.cho" "$root/src/driver.cho" "$root/src/checker.cho" \
    "$root/src/signature.cho" "$root/src/loop_check.cho" "$root/src/snapshot.cho" "$root/src/trail.cho" "$root/src/acceptance.cho" \
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
# in the script that sets it; the shell's own default PATH finds the tools a script needs; and PATH is EXPORTED, so what the agent
# launches (a compiler calling the linker) finds its tools too (on Linux a child with no exported PATH failed to link).
d=$(fresh)
"$exe" custom "$CANCHO" "$d" "printf 'home=[%s]\n' \"\$HOME\" > $d/env.txt; command -v sed >> $d/env.txt; command -v mktemp >> $d/env.txt; env | grep '^PATH=' >> $d/env.txt" >/dev/null 2>&1
expect "env: HOME is not set for the agent" "$(sed -n 1p "$d/env.txt")" "home=[]"
expect "env: sed resolves" "$(sed -n 2p "$d/env.txt" | sed 's#.*/##')" sed
expect "env: mktemp resolves" "$(sed -n 3p "$d/env.txt" | sed 's#.*/##')" mktemp
case "$(sed -n 4p "$d/env.txt")" in PATH=*/usr/bin*) ;; *) echo "FAIL: env: PATH is not exported to the agent's children ('$(sed -n 4p "$d/env.txt")')" >&2; fail=1 ;; esac
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

# gave up: only a documented exit code (docs/project.md, "The agent's exit codes") means the agent reached the model and had no usable answer. That is the
# unit failing, not the provider: a retryable failure with a named signature, so the same-signature stop and the attempt ceiling apply.
trailf() { sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p" "$1" | tr '\n' ' '; }
d=$(fresh); before=$(cksum < "$d/project.cho")
out=$("$exe" custom "$CANCHO" "$d" "exit 10" 2>&1); t="$d/project.cho.trail.jsonl"
expect "gave up cut-off: verdict (a failure, not unavailable)" "$(printf '%s' "$out" | grep ISSUE_VERDICT)" "$(printf '[ISSUE_VERDICT]\tfailed\tsignature')"
expect "gave up cut-off: two attempts, then the same-signature stop" "$(trailf "$t" decision)" "retry signature "
expect "gave up cut-off: the signature is named" "$(trailf "$t" sig)" "agent:gave-up:cut-off agent:gave-up:cut-off "
expect "gave up cut-off: the outcome" "$(trailf "$t" outcome)" "gave_up gave_up "
expect "gave up cut-off: file untouched" "$(cksum < "$d/project.cho")" "$before"
rm -rf "$d"
d=$(fresh)
out=$("$exe" custom "$CANCHO" "$d" "exit 11" 2>&1); t="$d/project.cho.trail.jsonl"
expect "gave up no-program: verdict" "$(printf '%s' "$out" | grep ISSUE_VERDICT)" "$(printf '[ISSUE_VERDICT]\tfailed\tsignature')"
expect "gave up no-program: the signature is named" "$(trailf "$t" sig)" "agent:gave-up:no-program agent:gave-up:no-program "
rm -rf "$d"
d=$(fresh)
out=$("$exe" custom "$CANCHO" "$d" "exit 12" 2>&1)
expect "gave up splice: the signature is named" "$(trailf "$d/project.cho.trail.jsonl" sig)" "agent:gave-up:splice agent:gave-up:splice "
rm -rf "$d"
# different reasons each turn: the signature rule does not fire, the attempt ceiling (4) does
d=$(fresh)
out=$("$exe" custom "$CANCHO" "$d" "if [ -f $d/flip ]; then rm $d/flip; exit 11; else touch $d/flip; exit 10; fi" 2>&1); t="$d/project.cho.trail.jsonl"
expect "gave up ceiling: verdict" "$(printf '%s' "$out" | grep ISSUE_VERDICT)" "$(printf '[ISSUE_VERDICT]\tfailed\tceiling')"
expect "gave up ceiling: four attempts, the ceiling named" "$(trailf "$t" decision)" "retry retry retry ceiling "
rm -rf "$d"
# a turn that gave up counts as an attempt, and the next one can still verify
d=$(fresh)
printf 'edition 7;\nfn main(world: World) -> [] int {\n    let Split { io, ffi, fs, heap, args, net, clock, signals, exec } = split(world);\n    release(ffi); release(fs); release(net); release(clock); release(signals); release(exec); release(args);\n    release(io); release(heap);\n    return 0;\n}\n' > "$d/fixed.cho"
out=$("$exe" custom "$CANCHO" "$d" "if [ -f $d/seen ]; then cp $d/fixed.cho $d/project.cho; else touch $d/seen; exit 10; fi" 2>&1)
expect "gave up then fixed: verdict" "$(printf '%s' "$out" | grep ISSUE_VERDICT)" "$(printf '[ISSUE_VERDICT]\tverified\tattempts 2')"
rm -rf "$d"
# every other non-zero exit keeps its meaning: the agent is away (a plain failure, a usage error, a provider code of a third-party agent)
for code in 1 2 3 4 9 13 127; do
    d=$(fresh)
    out=$("$exe" custom "$CANCHO" "$d" "exit $code" 2>&1)
    expect "plain exit $code: verdict" "$(printf '%s' "$out" | grep ISSUE_VERDICT)" "$(printf '[ISSUE_VERDICT]\tunavailable\tagent')"
    expect "plain exit $code: decision" "$(trailf "$d/project.cho.trail.jsonl" decision)" "agent_exit "
    rm -rf "$d"
done

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
