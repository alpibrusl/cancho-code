#!/bin/sh
# The project gate (docs/parity.md P5, docs/project.md): the driver that builds a plan unit by unit, against a stand-in agent that
# runs a shell recipe per unit and per attempt (tests/project/agent.sh). No model. The checker is the real compiler.
#
#   happy       three units in dependency order: done, exit 0, the functions are in project.cho, the state names all three
#   order       the plan lists the dependent first: dependencies are still built first (b, a, c: file order among the ready ones)
#   examples    a unit that type-checks but fails its own examples is not verified: a second attempt, `[ACCEPTANCE] fail` then pass
#   regression  building b breaks a: after b verifies the sweep finds it (`a regressed`), a is rebuilt, the project ends done
#   resume      the agent fails on c: provider_error, exit 4, the state keeps a and b; a second run keeps them (no rebuild) and builds c
#   stuck       a never verifies: it fails, an independent unit (b) is still built, its dependent (c) is skipped; stuck, exit 1
#   no plan     an invalid plan: its errors, then no_plan, exit 3, the agent never asked
#   usage       no arguments, and a plan that is not there: exit 2
#
# Needs the real cancho as CANCHO. Exit 0 every case held.
set -u

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
exe=$(mktemp -t cc-project-XXXXXX)
"$CANCHO" build "$root/tests/programs/project.cho" "$root/src/project.cho" "$root/src/plan.cho" "$root/src/driver.cho" \
    "$root/src/checker.cho" "$root/src/signature.cho" "$root/src/loop_check.cho" "$root/src/snapshot.cho" "$root/src/trail.cho" \
    "$root/src/acceptance.cho" --std --backend cranelift -o "$exe" || { echo "gate did not build" >&2; exit 2; }

fail=0
expect() { [ "$2" = "$3" ] || { echo "FAIL: $1: wanted '$3', got '$2'" >&2; fail=1; }; }
T="$root/tests/project"
units() { printf '%s\n' "$1" | grep '^\[UNIT\]' | cut -f2,3 | tr '\t' ':' | tr '\n' ' ' | sed 's/ $//'; }
verdict() { printf '%s\n' "$1" | grep '^\[PROJECT_VERDICT\]' | cut -f2; }
order() { tr '\n' ' ' < "$1" | sed 's/ $//'; }

# a fresh work directory with a copy of the good recipes; echoes "<workdir> <recipes> <log>"
mk() {
    wd=$(mktemp -d -t cc-project-wd-XXXXXX); rc=$(mktemp -d -t cc-project-rc-XXXXXX); lg="$wd/agent.log"
    cp "$T"/recipes-good/*.sh "$rc"/; : > "$lg"
    echo "$wd $rc $lg"
}
run() { # plan wd recipes log
    "$exe" "$CANCHO" "$1" "$2" "sh $T/agent.sh $3 $4" 4 60 2>&1
}

# happy
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$(run "$T/plan.json" "$wd" "$rc" "$lg"); r=$?
expect "happy: exit code" "$r" 0
expect "happy: verdict" "$(verdict "$out")" done
expect "happy: agent order" "$(order "$lg")" "a b c"
expect "happy: unit lines" "$(units "$out")" "a:building a:verified b:building b:verified c:building c:verified"
for f in double is_big big_double; do grep -q "fn $f" "$wd/project.cho" || { echo "FAIL: happy: project.cho has no $f" >&2; fail=1; }; done
expect "happy: the state" "$(order "$wd/state.txt")" "verified a verified b verified c"
[ -f "$wd/main.cho" ] || { echo "FAIL: happy: no main.cho" >&2; fail=1; }
expect "happy: unit a's trail" "$(wc -l < "$wd/trail-a.jsonl" | tr -d ' ')" 1
rm -rf "$wd" "$rc"

# order
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$(run "$T/plan-reordered.json" "$wd" "$rc" "$lg"); r=$?
expect "order: exit code" "$r" 0
expect "order: agent order" "$(order "$lg")" "b a c"
rm -rf "$wd" "$rc"

# examples
set -- $(mk); wd=$1; rc=$2; lg=$3
printf 'printf "\\nfn double(x: int) -> [] int { return x + 2; }\\n" >> "$1"\n' > "$rc/a.1.sh"
printf 'sed -i.bak "s/x + 2/x * 2/" "$1"\n' > "$rc/a.2.sh"
out=$(run "$T/plan.json" "$wd" "$rc" "$lg"); r=$?
expect "examples: exit code" "$r" 0
expect "examples: agent order" "$(order "$lg")" "a a b c"
expect "examples: acceptance lines for a" "$(printf '%s\n' "$out" | tr '\t' ':' | sed -n '/^\[UNIT\]:a:building/,/^\[UNIT\]:a:verified/p' | grep ACCEPTANCE | cut -d: -f2 | tr '\n' ' ')" "fail pass "
expect "examples: a took two attempts" "$(printf '%s\n' "$out" | grep 'ISSUE_VERDICT.*verified' | head -1 | cut -f3)" "attempts 2"
rm -rf "$wd" "$rc"

# regression: building b breaks a's function
set -- $(mk); wd=$1; rc=$2; lg=$3
printf 'printf "\\nfn is_big(x: int) -> [] bool { return x > 10; }\\n" >> "$1"; sed -i.bak "s/x \\\\* 2/x * 3/" "$1"\n' > "$rc/b.sh"
printf 'sed -i.bak "s/x \\\\* 3/x * 2/" "$1"\n' > "$rc/a.2.sh"
out=$(run "$T/plan.json" "$wd" "$rc" "$lg"); r=$?
expect "regression: exit code" "$r" 0
expect "regression: verdict" "$(verdict "$out")" done
expect "regression: agent order" "$(order "$lg")" "a b a c"
case "$(units "$out")" in *"b:verified a:regressed"*) ;; *) echo "FAIL: regression: no 'a:regressed' right after b verified: $(units "$out")" >&2; fail=1 ;; esac
grep -q 'x \* 2' "$wd/project.cho" || { echo "FAIL: regression: double was not repaired" >&2; fail=1; }
rm -rf "$wd" "$rc"

# resume: c's agent fails the first time, then works
set -- $(mk); wd=$1; rc=$2; lg=$3
mv "$rc/c.sh" "$rc/c.sh.later"
out=$(run "$T/plan.json" "$wd" "$rc" "$lg"); r=$?
expect "resume: first run exit code" "$r" 4
expect "resume: first run verdict" "$(verdict "$out")" provider_error
expect "resume: first run unit lines" "$(units "$out")" "a:building a:verified b:building b:verified c:building c:unavailable"
expect "resume: the state kept a and b" "$(order "$wd/state.txt")" "verified a verified b"
mv "$rc/c.sh.later" "$rc/c.sh"
out=$(run "$T/plan.json" "$wd" "$rc" "$lg"); r=$?
expect "resume: second run exit code" "$r" 0
expect "resume: second run kept a and b" "$(units "$out")" "a:kept b:kept c:building c:verified"
expect "resume: only c was asked again" "$(order "$lg")" "a b c c"
rm -rf "$wd" "$rc"

# stuck: a is always wrong, b is independent, c depends on a
set -- $(mk); wd=$1; rc=$2; lg=$3
printf 'sed -i.bak "/fn double/d" "$1"; printf "\\nfn double(x: int) -> [] int { return x + 3; }\\n" >> "$1"\n' > "$rc/a.sh"
out=$(run "$T/plan-failing.json" "$wd" "$rc" "$lg"); r=$?
expect "stuck: exit code" "$r" 1
expect "stuck: verdict" "$(verdict "$out")" stuck
expect "stuck: unit lines" "$(units "$out")" "a:building a:failed b:building b:verified c:skipped"
expect "stuck: agent order (b was still built)" "$(order "$lg")" "a a b"
expect "stuck: the state has b only" "$(order "$wd/state.txt")" "verified b"
expect "stuck: the failed unit's trail was kept (two records)" "$(wc -l < "$wd/trail-a.jsonl" 2>/dev/null | tr -d ' ')" 2
rm -rf "$wd" "$rc"

# no plan
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$(run "$T/plan-invalid.json" "$wd" "$rc" "$lg"); r=$?
expect "no plan: exit code" "$r" 3
expect "no plan: verdict" "$(verdict "$out")" no_plan
printf '%s\n' "$out" | grep -q '^\[PLAN_ERROR\]' || { echo "FAIL: no plan: no [PLAN_ERROR] line" >&2; fail=1; }
expect "no plan: the agent was never asked" "$(wc -c < "$lg" | tr -d ' ')" 0
rm -rf "$wd" "$rc"

# usage
"$exe" >/dev/null 2>&1; expect "usage: no arguments" "$?" 2
# a checker path that is not absolute: the driver spawns it from another directory, so it is a usage error, not a crash
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$("$exe" "cancho" "$T/plan.json" "$wd" "true" 2>&1); r=$?
expect "usage: a relative checker path" "$r" 2
case "$out" in *absolute*) ;; *) echo "FAIL: usage: a relative checker path: no message that says 'absolute' ('$out')" >&2; fail=1 ;; esac
rm -rf "$wd" "$rc"
set -- $(mk); wd=$1; rc=$2; lg=$3
"$exe" "$CANCHO" "$T/does-not-exist.json" "$wd" "true" >/dev/null 2>&1; expect "usage: a plan that is not there" "$?" 2
rm -rf "$wd" "$rc"

# a path with `..` in it: the file capability refuses traversal by trapping (exit 132), so the driver says so and exits 2 instead
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$("$exe" "$CANCHO" "$T/plan.json" "$wd/../$(basename "$wd")" "true" 2>&1); r=$?
expect "usage: a work directory with .. in it" "$r" 2
case "$out" in *".."*) ;; *) echo "FAIL: usage: a work directory with .. : no message that names '..' ('$out')" >&2; fail=1 ;; esac
out=$("$exe" "$CANCHO" "$T/../project/plan.json" "$wd" "true" 2>&1); r=$?
expect "usage: a plan path with .. in it" "$r" 2
rm -rf "$wd" "$rc"

rm -f "$exe"
[ "$fail" = 0 ] && echo "project gate: ok" || { echo "project gate: FAILED" >&2; exit 1; }
