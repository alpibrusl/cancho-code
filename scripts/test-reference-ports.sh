#!/bin/sh
# The reference ports (eval/reference, cancho-code#9): each implementation against the tests generated from its backlog oracle, with the
# exact pass count pinned, so a port that regresses or a test file that loses cases is red. Counts are tests, not oracle cases, where a
# generator chunked cases (01-semver: 20 tests holding 492 cases).
set -u

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)/eval/reference
fail=0

check() { # item want files... [-- extra args]
    item=$1; want=$2; shift 2
    out=$(cd "$root/$item" && "$CANCHO" test "$@" --std 2>&1)
    got=$(printf '%s\n' "$out" | sed -n 's/^test result: ok\. \([0-9]*\) passed; 0 failed.*/\1/p')
    [ "$got" = "$want" ] || { echo "FAIL: $item: wanted $want passed, got '${got:-no result}'" >&2; printf '%s\n' "$out" | grep -E "error|FAILED" | head -3 >&2; fail=1; }
}

check 01-semver 20 semver.cho tests.cho
check 02-glob 87 glob.cho globtest.cho
check 03-csv 50 csv_test.cho
check 04-jsonptr 134 jsonptr.cho jsonptr_tests.cho
check 05-duration 66 oracle_tests.cho duration.cho
check 06-editdistance 49 tests.cho editdistance.cho --backend cranelift
check 08-ini 49 oracle_test.cho ini.cho

[ "$fail" = 0 ] && echo "reference ports: ok" || { echo "reference ports: FAILED" >&2; exit 1; }
