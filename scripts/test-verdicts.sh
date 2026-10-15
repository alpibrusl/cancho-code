#!/bin/sh
# The verdicts gate (docs/parity.md P2): every way `fix` can end, as a fixture, with the verdict line and the exit code asserted.
# The exit codes (docs/design.md section 6): 0 verified, 1 stopped by a budget, 2 usage, 3 something it depends on is away.
#
#   verified          [ISSUE_VERDICT] verified, [ACCEPTANCE] none, exit 0
#   failed signature  the same refusal twice, exit 1
#   failed ceiling    different refusals until the ceiling, exit 1
#   unavailable agent an agent that exits non-zero, exit 3
#   no checker        a checker that is not there: unavailable checker, exit 3, and NEVER verified
#   crashing checker  a checker that exits 3 with no output: the same
#   silent checker    a checker that exits 0 and prints nothing useful: the same
#   lying checker     the clean answer but a failing exit code: the same
#   usage             no arguments: exit 2
#
# `failed defect` and `regressed` are not reachable from a fixture today: a plan defect is the store's word (no store yet) and a
# regression needs a file that checks and then stops checking between two runs. They are listed in docs/design.md as reserved.
set -u

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
exe=$(mktemp -t cc-verdicts-XXXXXX)
"$CANCHO" build "$root/tests/programs/fix.cho" "$root/src/driver.cho" "$root/src/checker.cho" \
    "$root/src/signature.cho" "$root/src/loop_check.cho" "$root/src/snapshot.cho" "$root/src/trail.cho" "$root/src/journal.cho" "$root/src/acceptance.cho" \
    --std --backend cranelift -o "$exe" || { echo "gate did not build" >&2; exit 2; }

fail=0
expect() { [ "$2" = "$3" ] || { echo "FAIL: $1: wanted '$3', got '$2'" >&2; fail=1; }; }
tab=$(printf '\t')
fresh() {
    d=$(mktemp -d -t cc-verdicts-d-XXXXXX)
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
verdict() { printf '%s\n' "$1" | grep ISSUE_VERDICT | tr '\t' ' '; }
outcome() { sed -n 's/.*"outcome":"\([^"]*\)".*/\1/p' "$1/project.cho.trail.jsonl" | tail -1; }

# verified
d=$(fresh); out=$("$exe" "$CANCHO" "$d/project.cho" "cp $d/fixed.cho" 4 2>&1); rc=$?
expect "verified: exit code" "$rc" 0
expect "verified: line" "$(verdict "$out")" "[ISSUE_VERDICT] verified attempts 1"
expect "verified: acceptance line" "$(printf '%s\n' "$out" | grep ACCEPTANCE | tr '\t' ' ')" "[ACCEPTANCE] none"
rm -rf "$d"

# failed signature
d=$(fresh); out=$("$exe" "$CANCHO" "$d/project.cho" "true" 4 2>&1); rc=$?
expect "signature: exit code" "$rc" 1
expect "signature: line" "$(verdict "$out")" "[ISSUE_VERDICT] failed signature"
rm -rf "$d"

# failed ceiling: the agent alternates two different unknown names on line 2
d=$(fresh)
out=$("$exe" "$CANCHO" "$d/project.cho" "f=$d/flip; p=$d/project.cho; if [ -f \$f ]; then rm \$f; sed -i.bak '2s/.*/fn broken() -> [] int { return yy; }/' \$p; else touch \$f; sed -i.bak '2s/.*/fn broken() -> [] int { return zz; }/' \$p; fi #" 4 2>&1); rc=$?
expect "ceiling: exit code" "$rc" 1
expect "ceiling: line" "$(verdict "$out")" "[ISSUE_VERDICT] failed ceiling"
rm -rf "$d"

# unavailable agent
d=$(fresh); out=$("$exe" "$CANCHO" "$d/project.cho" "exit 3 #" 4 2>&1); rc=$?
expect "agent: exit code" "$rc" 3
expect "agent: line" "$(verdict "$out")" "[ISSUE_VERDICT] unavailable agent"
rm -rf "$d"

# a checker that is not there, one that crashes, one that is silent: never verified
d=$(fresh)
out=$("$exe" "/nonexistent/cancho" "$d/project.cho" "true" 4 2>&1); rc=$?
expect "no checker: exit code" "$rc" 3
expect "no checker: line" "$(verdict "$out")" "[ISSUE_VERDICT] unavailable checker"
expect "no checker: trail outcome" "$(outcome "$d")" outage
printf '#!/bin/sh\nexit 3\n' > "$d/crash"; chmod +x "$d/crash"
rm -f "$d/project.cho.trail.jsonl"; out=$("$exe" "$d/crash" "$d/project.cho" "true" 4 2>&1); rc=$?
expect "crashing checker: exit code" "$rc" 3
expect "crashing checker: line" "$(verdict "$out")" "[ISSUE_VERDICT] unavailable checker"
printf '#!/bin/sh\necho "all good"\nexit 0\n' > "$d/silent"; chmod +x "$d/silent"
rm -f "$d/project.cho.trail.jsonl"; out=$("$exe" "$d/silent" "$d/project.cho" "true" 4 2>&1); rc=$?
expect "silent checker: exit code" "$rc" 3
expect "silent checker: line" "$(verdict "$out")" "[ISSUE_VERDICT] unavailable checker"
printf '#!/bin/sh\necho "{\\"refused\\": []}"\nexit 3\n' > "$d/lying"; chmod +x "$d/lying"
rm -f "$d/project.cho.trail.jsonl"; out=$("$exe" "$d/lying" "$d/project.cho" "true" 4 2>&1); rc=$?
expect "clean answer with a failing exit code: exit code" "$rc" 3
expect "clean answer with a failing exit code: line" "$(verdict "$out")" "[ISSUE_VERDICT] unavailable checker"
rm -rf "$d"

# usage
"$exe" >/dev/null 2>&1; expect "usage: exit code" "$?" 2

rm -f "$exe"
[ "$fail" = 0 ] && echo "verdicts gate: ok" || { echo "verdicts gate: FAILED" >&2; exit 1; }
