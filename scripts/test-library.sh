#!/bin/sh
# The library gate (docs/library.md): `build --library NAME` turns a finished build into src/NAME.cho and tests/NAME_test.cho.
#
# The fixture is a real build: tests/library/diff/ holds the project.cho, plan.json and contract of the first cancho-diff build (a Haiku 5.5 run under
# Forge, 2026-10-30), which needed `module diff;`, `pub` on three functions, `cancho fmt` and a public-API test file by hand. Here the same
# input must come out right with no hand: the library step over it (`tests/programs/library.cho`) is held to
#   - the good case: exit 0, `[LIBRARY]<TAB>ok`, `module diff;` right after `edition`, `pub` on exactly the three contract functions, `fmt --check`
#     clean, and the generated test file compiled and run by the checker (its `test result: ok. N passed`, N the count the step printed);
#   - a plan whose contract function has examples and no tests: `[LIBRARY_SKIPPED]` for it (never silent), and the rest still ok;
#   - each refusal reached once, with its tag: library-name, library-no-contract, library-contract-missing, library-has-module, library-no-tests,
#     library-unread, library-tests (a test of the plan that fails against the code: the step does not say ok);
# and the command itself (`cancho-build`) refuses `--library` without `--contract` or with a bad name before it asks a model for anything (exit 2).
# Python is a test oracle here (it edits the fixture JSON), never part of the tool.
set -u

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
CANCHO=$(command -v "$CANCHO")
root=$(cd "$(dirname "$0")/.." && pwd)
fx=$root/tests/library/diff
exe=$(mktemp -t cc-library-XXXXXX)
bexe=$(mktemp -t cc-library-build-XXXXXX)
"$CANCHO" build "$root/tests/programs/library.cho" "$root/src/library.cho" "$root/src/plan.cho" "$root/src/project.cho" "$root/src/cases.cho" \
    "$root/src/acceptance.cho" "$root/src/driver.cho" "$root/src/checker.cho" "$root/src/signature.cho" "$root/src/loop_check.cho" \
    "$root/src/snapshot.cho" "$root/src/trail.cho" "$root/src/splice.cho" "$root/src/pool.cho" "$root/src/parallel.cho" \
    --std --backend cranelift -o "$exe" >/dev/null || { echo "gate did not build" >&2; exit 2; }
"$CANCHO" build "$root/tests/programs/build.cho" "$root/src/build.cho" "$root/src/project.cho" "$root/src/plan.cho" "$root/src/driver.cho" \
    "$root/src/checker.cho" "$root/src/signature.cho" "$root/src/loop_check.cho" "$root/src/snapshot.cho" "$root/src/trail.cho" \
    "$root/src/acceptance.cho" "$root/src/splice.cho" "$root/src/pool.cho" "$root/src/parallel.cho" "$root/src/library.cho" "$root/src/cases.cho" "$root/src/change.cho" "$root/src/repochange.cho" \
    --std --backend cranelift -o "$bexe" >/dev/null || { echo "gate did not build the command" >&2; exit 2; }

fail=0
expect() { [ "$2" = "$3" ] || { echo "FAIL: $1: wanted '$3', got '$2'" >&2; fail=1; }; }
tab=$(printf '\t')
work=$(mktemp -d -t cc-library-wd-XXXXXX)
trap 'rm -rf "$work" "$exe" "$bexe"' EXIT

# A fresh work directory holding the fixture; the plan and project may be edited by $1 (a python snippet over `plan` and `project`).
fresh() {
    d=$work/$1
    rm -rf "$d"; mkdir -p "$d"
    cp "$fx/project.cho" "$d/project.cho"
    if [ -n "${2:-}" ]; then
        python3 -I - "$fx/plan.json" "$d/plan.json" "$d/project.cho" <<PY
import json, sys
plan = json.load(open(sys.argv[1]))
project = open(sys.argv[3]).read()
$2
json.dump(plan, open(sys.argv[2], "w"))
open(sys.argv[3], "w").write(project)
PY
    else
        cp "$fx/plan.json" "$d/plan.json"
    fi
    printf '%s' "$d"
}
run() { env -i PATH="$PATH" "$exe" "$CANCHO" "$1" "$2" "$3" 2>&1; }

# ---- the good case --------------------------------------------------------
d=$(fresh good "")
out=$(run "$d" diff "$fx/contract.txt"); rc=$?
expect "good: exit" "$rc" "0"
line=$(printf '%s\n' "$out" | grep '^\[LIBRARY\]')
expect "good: verdict" "$(printf '%s' "$line" | cut -f1,2,3)" "[LIBRARY]${tab}ok${tab}diff"
n=$(printf '%s' "$line" | cut -f6)
expect "good: module line" "$(sed -n 2p "$d/src/diff.cho")" "module diff;"
expect "good: pub on exactly the contract" "$(grep -c '^pub fn ' "$d/src/diff.cho")" "3"
expect "good: pub names" "$(grep '^pub fn ' "$d/src/diff.cho" | sed 's/^pub fn \([a-z_]*\).*/\1/' | sort | tr '\n' ' ')" "apply edit_count unified "
"$CANCHO" fmt --check "$d/src/diff.cho" "$d/tests/diff_test.cho" >/dev/null 2>&1; expect "good: fmt --check" "$?" "0"
res=$(env -i PATH="$PATH" "$CANCHO" test --std --backend cranelift "$d/tests/diff_test.cho" "$d/src/diff.cho" 2>&1 | grep 'test result')
expect "good: the generated tests pass" "$res" "test result: ok. $n passed; 0 failed"
expect "good: tests are written against the module" "$(grep -c 'diff\.\(edit_count\|unified\|apply\)(' "$d/tests/diff_test.cho" | awk '{print ($1 > 0)}')" "1"
expect "good: no unqualified call of a contract function" "$(grep -c '[^.a-z_]\(edit_count\|unified\|apply\)(' "$d/tests/diff_test.cho")" "0"
expect "good: nothing skipped" "$(printf '%s\n' "$out" | grep -c '^\[LIBRARY_SKIPPED\]')" "0"

# ---- a contract function the plan gives no tests: said, not skipped silently -----
d=$(fresh skipped 'for u in plan["units"]:
    if u["signature"].startswith("fn edit_count"):
        u["tests"] = []')
out=$(run "$d" diff "$fx/contract.txt"); rc=$?
expect "skipped: exit" "$rc" "0"
expect "skipped: said" "$(printf '%s\n' "$out" | grep '^\[LIBRARY_SKIPPED\]' | cut -f1,2)" "[LIBRARY_SKIPPED]${tab}edit_count"
expect "skipped: the rest ok" "$(printf '%s\n' "$out" | grep '^\[LIBRARY\]' | cut -f1,2)" "[LIBRARY]${tab}ok"
expect "skipped: no test of it in the file" "$(grep -c 'diff\.edit_count(' "$d/tests/diff_test.cho")" "0"

# ---- the refusals ---------------------------------------------------------
tag() { printf '%s\n' "$1" | grep '^\[LIBRARY_ERROR\]' | head -1 | cut -f2; }

d=$(fresh name ""); out=$(run "$d" Diff "$fx/contract.txt"); expect "name: exit" "$?" "6"; expect "name: tag" "$(tag "$out")" "library-name"
d=$(fresh nocontract ""); out=$("$exe" "$CANCHO" "$d" diff "" 2>&1); expect "no contract: exit" "$?" "6"; expect "no contract: tag" "$(tag "$out")" "library-no-contract"
printf 'pub fn nowhere[&h](heap: &!h Heap) -> [heap] int\n' > "$work/missing.txt"
d=$(fresh missing ""); out=$(run "$d" diff "$work/missing.txt"); expect "missing: exit" "$?" "6"; expect "missing: tag" "$(tag "$out")" "library-contract-missing"
printf '%s\n' "$out" | grep -q "nowhere" || { echo "FAIL: missing: the message does not name the function" >&2; fail=1; }
d=$(fresh hasmodule 'project = project.replace("edition 7;", "edition 7;\nmodule other;", 1)')
out=$(run "$d" diff "$fx/contract.txt"); expect "has module: exit" "$?" "6"; expect "has module: tag" "$(tag "$out")" "library-has-module"
d=$(fresh notests 'for u in plan["units"]:
    u["tests"] = []')
out=$(run "$d" diff "$fx/contract.txt"); expect "no tests: exit" "$?" "6"; expect "no tests: tag" "$(tag "$out")" "library-no-tests"
d=$(fresh unread ""); rm "$d/plan.json"; out=$(run "$d" diff "$fx/contract.txt"); expect "unread: exit" "$?" "6"; expect "unread: tag" "$(tag "$out")" "library-unread"
d=$(fresh failing 'for u in plan["units"]:
    if u["signature"].startswith("fn edit_count"):
        u["tests"] = [t.replace("== 2", "== 99", 1) if "== 2" in t else t for t in u["tests"]]')
out=$(run "$d" diff "$fx/contract.txt"); rc=$?
if printf '%s\n' "$out" | grep -q '^\[LIBRARY\]'; then
    echo "FAIL: failing: a test that fails against the code must not end ok" >&2; fail=1
else
    expect "failing: exit" "$rc" "6"; expect "failing: tag" "$(tag "$out")" "library-tests"
fi

# ---- the command refuses before it asks a model for anything ----------------
bw=$work/cmd; mkdir -p "$bw"; : > "$bw/brief.txt"
out=$("$bexe" "$CANCHO" "$bw/brief.txt" "$bw/wd" /bin/true --provider p --model m --library diff 2>&1); expect "cmd: no contract: exit" "$?" "2"
expect "cmd: no contract: tag" "$(tag "$out")" "library-no-contract"
out=$("$bexe" "$CANCHO" "$bw/brief.txt" "$bw/wd" /bin/true --provider p --model m --contract "$fx/contract.txt" --library Diff 2>&1); expect "cmd: bad name: exit" "$?" "2"
expect "cmd: bad name: tag" "$(tag "$out")" "library-name"
[ ! -e "$bw/wd" ] || { echo "FAIL: cmd: the work directory was made before the arguments were checked" >&2; fail=1; }

[ "$fail" = 0 ] && echo "library gate: ok"
exit "$fail"
