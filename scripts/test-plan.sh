#!/bin/sh
# The plan gate (docs/parity.md P3, docs/plan.md): `plancheck` on one fixture per rule, with the rule and the unit of every
# [PLAN_ERROR] line asserted in order, the verdict line, and the exit code. tests/plans/expected.txt is the table.
#
# Also: a valid plan prints exactly `[PLAN]<TAB>valid`; every error line has four fields and a non-empty message; and the usage
# cases (no argument, a file that is not there, a file of 1 MiB or more) exit 2.
set -u

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
exe=$(mktemp -t cc-plan-XXXXXX)
"$CANCHO" build "$root/tests/programs/plancheck.cho" "$root/src/plan.cho" \
    --std --backend cranelift -o "$exe" || { echo "gate did not build" >&2; exit 2; }

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

"$exe" >/dev/null 2>&1; expect "usage: no argument" "$?" 2
"$exe" "$root/tests/plans/does-not-exist.json" >/dev/null 2>&1; expect "usage: a file that is not there" "$?" 2

# the real plan for 07-tokenbucket (eval/tokenbucket/plan.json, the brief as units) is valid
out=$("$exe" "$root/eval/tokenbucket/plan.json" 2>&1); rc=$?
expect "tokenbucket plan: exit code" "$rc" 0
expect "tokenbucket plan: output" "$out" "$(printf '[PLAN]\tvalid')"

out=$("$exe" "$root/eval/duration/plan.json" 2>&1); rc=$?
expect "duration plan: exit code" "$rc" 0
expect "duration plan: output" "$out" "$(printf '[PLAN]\tvalid')"

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
