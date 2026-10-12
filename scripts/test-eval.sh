#!/bin/sh
# The audit gate (docs/parity.md, #9): eval/audit_tokenbucket.py against three files whose right score is known, so a harness that
# cannot fail, or that fails for the wrong reason, is caught here and not discovered inside a result.
#
#   reference  eval/tokenbucket/reference.cho, in the brief's shapes: 46/46, exit 0
#   mutated    the same with the capacity cap changed (capacity * 999): bucket_refill must drop, exit non-zero
#   acceptance the brief's 15 worked examples (the builder sees these): the reference holds, a wrong-shape real output names what it was
#              running, a behavioural break names the examples that fail
#   shapes     a real qwen3.8:27b output (eval/tokenbucket/fixtures/model-int-shapes.cho) whose arithmetic is right and whose
#              shapes are not (int where the brief says Option and a record): strict 24/46, and the lenient line says take 10/10
#
# Needs python3. Exit 0 every case held.
set -u

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "no python3 on PATH" >&2; exit 2; }
export CANCHO
root=$(cd "$(dirname "$0")/.." && pwd)
audit="python3 $root/eval/audit_tokenbucket.py"
fail=0
expect() { [ "$2" = "$3" ] || { echo "FAIL: $1: wanted '$3', got '$2'" >&2; fail=1; }; }
d=$(mktemp -d -t cc-eval-XXXXXX)

out=$($audit "$root/eval/tokenbucket/reference.cho" 2>&1); rc=$?
expect "reference: exit code" "$rc" 0
expect "reference: score" "$(printf '%s\n' "$out" | grep STRICT)" "  STRICT total 46/46"

sed 's/capacity \* 1000/capacity * 999/g' "$root/eval/tokenbucket/reference.cho" > "$d/mutated.cho"
cmp -s "$d/mutated.cho" "$root/eval/tokenbucket/reference.cho" && { echo "FAIL: mutated: the mutation changed nothing" >&2; fail=1; }
out=$($audit "$d/mutated.cho" 2>&1); rc=$?
[ "$rc" != 0 ] || { echo "FAIL: mutated: exit code 0 for a broken implementation" >&2; fail=1; }
case "$(printf '%s\n' "$out" | grep 'bucket_refill:')" in "  bucket_refill: 12/12"*) echo "FAIL: mutated: bucket_refill still scores 12/12" >&2; fail=1 ;; esac

out=$($audit "$root/eval/tokenbucket/fixtures/model-int-shapes.cho" 2>&1); rc=$?
[ "$rc" != 0 ] || { echo "FAIL: shapes: exit code 0 for the wrong shapes" >&2; fail=1; }
expect "shapes: strict score" "$(printf '%s\n' "$out" | grep STRICT)" "  STRICT total 24/46"
expect "shapes: lenient take" "$(printf '%s\n' "$out" | grep 'lenient' | sed 's/ *$//')" "  bucket_take (lenient: None=-1): 10/10"

# the acceptance check (the brief's 15 worked examples; the builder sees these, never the audit)
acc="python3 $root/eval/tokenbucket/acceptance.py"
out=$($acc "$root/eval/tokenbucket/reference.cho" 2>&1); rc=$?
expect "acceptance: the reference holds (exit)" "$rc" 0
expect "acceptance: the reference prints nothing" "$out" ""
out=$($acc "$root/eval/tokenbucket/fixtures/model-int-shapes.cho" 2>&1); rc=$?
[ "$rc" != 0 ] || { echo "FAIL: acceptance: exit 0 for the wrong shapes" >&2; fail=1; }
case "$out" in "does not build in the brief's shapes: "*"cannot be matched"*"while checking: bucket_take(5000, 5) is Some(0)"*) ;; *) echo "FAIL: acceptance: the wrong-shape message does not name the example in the brief's words: $out" >&2; fail=1 ;; esac
case "$out" in *test_e0*|*"pub fn"*) echo "FAIL: acceptance: the message shows the harness's own code, which a model pastes into its program (then the harness defines it twice): $out" >&2; fail=1 ;; esac
out=$($acc "$d/mutated.cho" 2>&1); rc=$?
[ "$rc" != 0 ] || { echo "FAIL: acceptance: exit 0 for a broken implementation" >&2; fail=1; }
case "$out" in "failing: bucket_refill(9500, 0, 1000, 10, 1), "*"The brief's worked examples: 12 of 15 hold."*"bucket_refill(9500, 0, 1000, 10, 1) is 10000"*) ;; *) echo "FAIL: acceptance: the behavioural failure is not named: $out" >&2; fail=1 ;; esac

rm -rf "$d"
[ "$fail" = 0 ] && echo "eval gate: ok" || { echo "eval gate: FAILED" >&2; exit 1; }
