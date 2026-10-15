#!/bin/sh
# The acceptance gate (docs/parity.md P4a): an optional command that runs on the file after the checker verifies it, so `verified` can
# mean "meets the brief" and not only "type-checks". It is a shell command with the project file appended, like the agent; exit 0 holds.
#
#   pass      a file that checks and satisfies the acceptance: `[ACCEPTANCE] pass`, verified, one trail record
#   retry     it fails once, then holds: `[ACCEPTANCE] fail` then `pass`; the trail's first record is `retry` with an `acceptance:`
#             signature, and the next agent turn can read the acceptance output in <project>.feedback
#   stuck     it never holds and says the same thing: the same-signature stop ends it (`failed signature`) in two turns; the output is
#             in <project>.feedback
#   noise     a varying first line (a linker warning with a temp directory) does not hide the failure: the signature is the failing test
#   path      the acceptance command runs with an exported PATH, so what it launches (a compiler calling the linker) works
#   hang      an acceptance that never answers is cut at its own cap and counts as a failure (`acceptance:timeout`), not a hang
#
# Stand-ins are one line of shell (tests/programs/driver_gate.cho, mode `custom`, args: agent, agent cap ms, acceptance, acceptance cap ms).
set -u

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
exe=$(mktemp -t cc-accept-XXXXXX)
"$CANCHO" build "$root/tests/programs/driver_gate.cho" "$root/src/driver.cho" "$root/src/checker.cho" \
    "$root/src/signature.cho" "$root/src/loop_check.cho" "$root/src/snapshot.cho" "$root/src/trail.cho" "$root/src/journal.cho" "$root/src/acceptance.cho" \
    --std --backend cranelift -o "$exe" || { echo "gate did not build" >&2; exit 2; }

fail=0
expect() { [ "$2" = "$3" ] || { echo "FAIL: $1: wanted '$3', got '$2'" >&2; fail=1; }; }
field() { sed -n "s/.*\"$2\":\"\\([^\"]*\\)\".*/\\1/p" "$1" | sed -n "${3}p"; }

fresh() { # a project that does not check, and the file that does
    d=$(mktemp -d -t cc-accept-d-XXXXXX)
    printf 'edition 7;\nfn broken() -> [] int { return true; }\nfn main(world: World) -> [] int { return 0; }\n' > "$d/project.cho"
    cat > "$d/fixed.cho" <<'FIX'
edition 7;
fn main(world: World) -> [] int {
    let Split { io, ffi, fs, heap, args, net, clock, signals, exec } = split(world);
    release(ffi); release(fs); release(net); release(clock); release(signals); release(exec); release(args);
    release(io); release(heap);
    return 0;
}
FIX
    echo "$d"
}
run() { # dir agent accept [accept_cap_ms]
    "$exe" custom "$CANCHO" "$1" "$2" 30000 "$3" ${4:-60000} 2>&1
}

# pass
d=$(fresh); out=$(run "$d" "cp $d/fixed.cho $d/project.cho" "grep -q return")
expect "pass: verdict" "$(printf '%s\n' "$out" | grep ISSUE_VERDICT | cut -f1,2)" "$(printf '[ISSUE_VERDICT]\tverified')"
expect "pass: acceptance line" "$(printf '%s\n' "$out" | grep ACCEPTANCE)" "$(printf '[ACCEPTANCE]\tpass')"
expect "pass: one record" "$(wc -l < "$d/project.cho.trail.jsonl" | tr -d ' ')" 1
rm -rf "$d"

# retry: the first turn fixes the check, the second adds what the acceptance wants
d=$(fresh)
out=$(run "$d" "if [ -f $d/turn ]; then printf '// GOOD\\n' >> $d/project.cho; else touch $d/turn; cp $d/fixed.cho $d/project.cho; fi" "grep -q GOOD")
expect "retry: verdict" "$(printf '%s\n' "$out" | grep ISSUE_VERDICT | cut -f1,2,3)" "$(printf '[ISSUE_VERDICT]\tverified\tattempts 2')"
expect "retry: acceptance lines" "$(printf '%s\n' "$out" | grep ACCEPTANCE | tr '\n' ' ')" "$(printf '[ACCEPTANCE]\tfail [ACCEPTANCE]\tpass ')"
t="$d/project.cho.trail.jsonl"
expect "retry: records" "$(wc -l < "$t" | tr -d ' ')" 2
expect "retry: first decision" "$(field "$t" decision 1)" retry
expect "retry: first outcome" "$(field "$t" outcome 1)" refused
case "$(field "$t" sig 1)" in acceptance:*) ;; *) echo "FAIL: retry: the first signature is not an acceptance one ('$(field "$t" sig 1)')" >&2; fail=1 ;; esac
expect "retry: second decision" "$(field "$t" decision 2)" verified
rm -rf "$d"

# stuck
d=$(fresh)
out=$(run "$d" "cp $d/fixed.cho $d/project.cho" "printf nope; false")
expect "stuck: verdict" "$(printf '%s\n' "$out" | grep ISSUE_VERDICT)" "$(printf '[ISSUE_VERDICT]\tfailed\tsignature')"
t="$d/project.cho.trail.jsonl"
expect "stuck: records" "$(wc -l < "$t" | tr -d ' ')" 2
expect "stuck: signature" "$(field "$t" sig 1)" "acceptance:nope"
expect "stuck: last decision" "$(field "$t" decision 2)" signature
case "$(cat "$d/project.cho.feedback" 2>/dev/null)" in *nope*) ;; *) echo "FAIL: stuck: the acceptance output is not in the feedback the agent reads" >&2; fail=1 ;; esac
rm -rf "$d"

# noise: the first line of an acceptance's output is often noise that changes on every run (the linker warns, with a temp directory in
# its text, on macOS); the signature comes from the informative line, so the same failure twice is the same signature (found when a
# project unit that was always wrong ran to the ceiling instead of stopping at the second identical failure)
d=$(fresh)
out=$(run "$d" "cp $d/fixed.cho $d/project.cho" "echo \"ld: warning: in /tmp/run-\$\$-\$RANDOM/x.o\"; echo \"running 1 test\"; echo \"test test_a_1 ... FAILED\"; false")
expect "noise: verdict" "$(printf '%s\n' "$out" | grep ISSUE_VERDICT)" "$(printf '[ISSUE_VERDICT]\tfailed\tsignature')"
t="$d/project.cho.trail.jsonl"
expect "noise: records" "$(wc -l < "$t" | tr -d ' ')" 2
expect "noise: signature is the failing test" "$(field "$t" sig 1)" "acceptance:test test_a_1 ... FAILED"
rm -rf "$d"

# path: the acceptance runs with a PATH that its children inherit. A shell has a default PATH it does not export, so a child (`cancho test`
# calling `cc` to link) started with none and failed on Linux with "liblto_plugin.so not found" (found by the project gate on a Linux runner)
d=$(fresh)
out=$(run "$d" "cp $d/fixed.cho $d/project.cho" "env | grep -q '^PATH=.*/usr/bin' #")
expect "path: the acceptance's children get a PATH" "$(printf '%s\n' "$out" | grep ACCEPTANCE | cut -f2)" pass
rm -rf "$d"

# hang
d=$(fresh); start=$(date +%s)
out=$(run "$d" "cp $d/fixed.cho $d/project.cho" "sleep 20 #" 1000); took=$(( $(date +%s) - start ))
[ "$took" -lt 12 ] || { echo "FAIL: hang: took ${took}s with a 1 s cap" >&2; fail=1; }
expect "hang: signature" "$(field "$d/project.cho.trail.jsonl" sig 1)" "acceptance:timeout"
rm -rf "$d"

rm -f "$exe"
[ "$fail" = 0 ] && echo "acceptance gate: ok" || { echo "acceptance gate: FAILED" >&2; exit 1; }
