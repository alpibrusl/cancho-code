#!/bin/sh
# The plan gate (docs/parity.md P3, docs/plan.md): `plancheck` on one fixture per rule, with the rule and the unit of every
# [PLAN_ERROR] line asserted in order, the verdict line, and the exit code. tests/plans/expected.txt is the table.
#
# Each message names what the model must change (tests/plans/messages.txt: the field, the function, the callee): it is the next round's only teacher.
# Also: a valid plan prints exactly `[PLAN]<TAB>valid`; every error line has four fields and a non-empty message; and the usage
# cases (no argument, a file that is not there, a file of 1 MiB or more) exit 2.
set -u

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
exe=$(mktemp -t cc-plan-XXXXXX)
"$CANCHO" build "$root/tests/programs/plancheck.cho" "$root/src/plan.cho" \
    --std -o "$exe" || { echo "gate did not build" >&2; exit 2; }

fail=0
expect() { [ "$2" = "$3" ] || { echo "FAIL: $1: wanted '$3', got '$2'" >&2; fail=1; }; }
tab=$(printf '\t')

grep -v '^#' "$root/tests/plans/expected.txt" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "$line"
done > "${exe}.table"

while IFS= read -r line; do
    name=$(printf '%s' "$line" | awk '{print $1}')
    want_rc=$(printf '%s' "$line" | awk '{print $2}')
    want=$(printf '%s' "$line" | awk '{ s = ""; for (i = 3; i <= NF; i++) s = s (i > 3 ? " " : "") $i; print s }')
    out=$("$exe" "$root/tests/plans/$name.json" 2>&1); rc=$?
    expect "$name: exit code" "$rc" "$want_rc"
    got=$(printf '%s\n' "$out" | grep '^\[PLAN_ERROR\]' | awk -F'\t' '{print $2 ":" $3}' | tr '\n' ' ' | sed 's/ $//')
    expect "$name: errors" "$got" "$want"
    # every error line has four fields and a message
    printf '%s\n' "$out" | grep '^\[PLAN_ERROR\]' | while IFS= read -r e; do
        n=$(printf '%s' "$e" | awk -F'\t' '{print NF}'); m=$(printf '%s' "$e" | awk -F'\t' '{print $4}')
        [ "$n" = 4 ] && [ -n "$m" ] || { echo "FAIL: $name: malformed error line: $e" >&2; exit 1; }
    done || fail=1
    if [ "$want_rc" = 0 ]; then
        expect "$name: output" "$out" "$(printf '[PLAN]\tvalid')"
    else
        expect "$name: verdict" "$(printf '%s\n' "$out" | grep '^\[PLAN\]' | tail -1)" "$(printf '[PLAN]\tinvalid')"
    fi
done < "${exe}.table"

# the message is what a model reads on the next round: it names the field, the function, the callee
grep -v '^#' "$root/tests/plans/messages.txt" | while IFS="$tab" read -r name piece; do
    [ -n "$name" ] || continue
    msg=$("$exe" "$root/tests/plans/$name.json" 2>&1 | grep '^\[PLAN_ERROR\]' | head -1 | awk -F'\t' '{print $4}')
    case "$msg" in *"$piece"*) ;; *) echo "FAIL: $name: the message lacks '$piece': $msg" >&2; exit 1 ;; esac
done || fail=1

"$exe" >/dev/null 2>&1; expect "usage: no argument" "$?" 2
"$exe" "$root/tests/plans/does-not-exist.json" >/dev/null 2>&1; expect "usage: a file that is not there" "$?" 2

# the real plan for 07-tokenbucket (eval/tokenbucket/plan.json, the brief as units) is valid
out=$("$exe" "$root/eval/tokenbucket/plan.json" 2>&1); rc=$?
expect "tokenbucket plan: exit code" "$rc" 0
expect "tokenbucket plan: output" "$out" "$(printf '[PLAN]\tvalid')"

out=$("$exe" "$root/eval/duration/plan.json" 2>&1); rc=$?
expect "duration plan: exit code" "$rc" 0
expect "duration plan: output" "$out" "$(printf '[PLAN]\tvalid')"

# every hand-written eval plan stays valid under every rule
for p in "$root"/eval/*/plan.json; do
    out=$("$exe" "$p" 2>&1); rc=$?
    expect "$(basename "$(dirname "$p")") plan: valid" "$out" "$(printf '[PLAN]\tvalid')"
done

# the hand plans of the four services (docs/project.md, "Services") are valid, and each names its integration unit
for p in "$root"/eval/services/*/plan.json; do
    out=$("$exe" "$p" 2>&1); rc=$?
    expect "service $(basename "$(dirname "$p")") plan: valid" "$out" "$(printf '[PLAN]\tvalid')"
    grep -q '"integration": "app"' "$p" || { echo "FAIL: service $(basename "$(dirname "$p")") plan: no integration unit" >&2; fail=1; }
done

out=$("$exe" "$root/eval/csv/plan.json" 2>&1); rc=$?
expect "csv plan: exit code" "$rc" 0
expect "csv plan: output" "$out" "$(printf '[PLAN]\tvalid')"

# with a brief (`plancheck <plan.json> <brief.txt>`): after a valid plan check, the brief's own rules (src/plan.cho `brief_report`, the check the
# plan agent runs in each round and `build` keeps as a backstop). `brief-heap` (docs/plan.md, "The call shape"): a function the brief names whose
# result owns no memory takes no heap, since its caller calls it with the brief's arguments only. The real plans are Haiku's: runs-83 editdistance
# (0/54, `edit_distance` and `similarity_pct` with a heap), forge1 ev2 roman (192/439, `from_roman` with a heap), runs-83c editdistance (54/54).
brief_case() {
    out=$("$exe" "$root/tests/plans/$2" "$3" 2>&1); rc=$?
    expect "$1: exit code" "$rc" "$4"
    got=$(printf '%s\n' "$out" | grep '^\[PLAN_ERROR\]' | awk -F'\t' '{print $2 ":" $3}' | tr '\n' ' ' | sed 's/ $//')
    expect "$1: errors" "$got" "$5"
    expect "$1: verdict" "$(printf '%s\n' "$out" | tail -1)" "$(if [ "$4" = 0 ]; then printf '[PLAN]\tvalid'; else printf '[PLAN]\tinvalid'; fi)"
}
brief_case "brief-heap" brief-heap.json "$root/tests/plans/brief-heap.txt" 1 "brief-heap:dist brief-heap:rom"
brief_case "brief-heap ok" brief-heap-ok.json "$root/tests/plans/brief-heap.txt" 0 ""
brief_case "brief-heap real editdistance" real-editdistance-heap.json "$root/eval/editdistance/brief.txt" 1 "brief-heap:edit_distance brief-heap:similarity"
brief_case "brief-heap real roman" real-roman-heap.json "$root/eval/roman/brief.txt" 1 "brief-heap:from_roman"
brief_case "brief-heap real editdistance contract" real-editdistance-contract.json "$root/eval/editdistance/brief.txt" 0 ""
msg=$("$exe" "$root/tests/plans/brief-heap.json" "$root/tests/plans/brief-heap.txt" 2>&1 | grep '^\[PLAN_ERROR\]' | head -1 | awk -F'\t' '{print $4}')
for piece in '`edit_distance`' 'Remove the heap parameter' '`-> [] int`' 'region'; do
    case "$msg" in *"$piece"*) ;; *) echo "FAIL: brief-heap: the message lacks '$piece': $msg" >&2; fail=1 ;; esac
done
# the brief-name refusal comes through the same entry, and a valid plan with no brief is unchanged (one argument, as before)
brief_case "brief-name" brief-heap-ok.json "$root/tests/plans/brief-names-extra.txt" 1 "brief-name:levenshtein"
# every hand-written eval plan stays valid against its own brief
for p in "$root"/eval/*/plan.json; do
    b="$(dirname "$p")/brief.txt"
    [ -f "$b" ] || continue
    out=$("$exe" "$p" "$b" 2>&1)
    expect "$(basename "$(dirname "$p")") plan with its brief: valid" "$out" "$(printf '[PLAN]\tvalid')"
done

# a plan of 1 MiB or more is refused as a usage error, never read in part (a truncated plan would be checked as if it were the whole)
big=$(mktemp -t cc-plan-big-XXXXXX)
python3 -c "
import sys
sys.stdout.write(open('$root/tests/plans/valid.json').read().rstrip()[:-1] + ' ' * 1100000 + '}')" > "$big" 2>/dev/null
out=$("$exe" "$big" 2>&1); rc=$?
expect "oversize: exit code" "$rc" 2
case "$out" in *"too large"*) ;; *) echo "FAIL: oversize: no 'too large' message ('$out')" >&2; fail=1 ;; esac
rm -f "$big"

rm -f "$exe" "${exe}.table"
[ "$fail" = 0 ] && echo "plan gate: ok" || { echo "plan gate: FAILED" >&2; exit 1; }
