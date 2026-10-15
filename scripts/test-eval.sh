#!/bin/sh
# The audit gate (docs/parity.md, #9): eval/audit_tokenbucket.py against three files whose right score is known, so a harness that
# cannot fail, or that fails for the wrong reason, is caught here and not discovered inside a result.
#
#   reference  eval/tokenbucket/reference.cho, in the brief's shapes: 46/46, exit 0
#   mutated    the same with the capacity cap changed (capacity * 999): bucket_refill must drop, exit non-zero
#   acceptance the brief's 15 worked examples (the builder sees these): the reference holds, a wrong-shape real output names what it was
#              running, a behavioural break names the examples that fail
#   duration   05-duration: the audit (reference 64/64, a mutation caught, a wrong shape scored apart) and the plan's own tests, which the
#              reference passes through the whole driver and the mutation does not
#   csv        03-csv: the same for the csv item (audit 50/50 for the reference, a mutation caught, the plan's tests through the driver)
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

# 05-duration (held out): the audit, and the plan's own tests checked against the reference
dur="python3 $root/eval/audit_duration.py"
out=$($dur "$root/eval/duration/reference.cho" 2>&1); rc=$?
expect "duration: the reference holds (exit)" "$rc" 0
expect "duration: the reference scores" "$(printf '%s\n' "$out" | grep TOTAL)" "  TOTAL 64/64"
sed 's/3600/3601/g' "$root/eval/duration/reference.cho" > "$d/dur-mutated.cho"
out=$($dur "$d/dur-mutated.cho" 2>&1); rc=$?
[ "$rc" != 0 ] || { echo "FAIL: duration: exit 0 for a broken implementation" >&2; fail=1; }
case "$(printf '%s\n' "$out" | grep TOTAL)" in "  TOTAL 64/64") echo "FAIL: duration: the mutation scored 64/64" >&2; fail=1 ;; esac
# a format of another shape (no heap, an int): the file builds, parse still scores, format scores 0 with the reason
python3 - "$root/eval/duration/reference.cho" > "$d/dur-shape.cho" <<'PYEOF'
import sys
s = open(sys.argv[1]).read()
print(s[:s.index("fn duration_format")] + "fn duration_format(seconds: int) -> [] int { return seconds; }")
PYEOF
out=$($dur "$d/dur-shape.cho" 2>&1)
expect "duration: parse is graded apart from format (shape)" "$(printf '%s\n' "$out" | grep 'duration_parse:')" "  duration_parse: 42/42 "
case "$(printf '%s\n' "$out" | grep 'duration_format:')" in "  duration_format: 0/22 does not build"*) ;; *) echo "FAIL: duration: a format of the wrong shape was not scored 0 with a build error: $out" >&2; fail=1 ;; esac

# the plan's tests hold for the reference, through the whole driver (a stand-in agent installs it); and they refuse the mutation
pexe=$(mktemp -t cc-eval-proj-XXXXXX)
"$CANCHO" build "$root/tests/programs/project.cho" "$root/src/project.cho" "$root/src/plan.cho" "$root/src/driver.cho" \
    "$root/src/checker.cho" "$root/src/signature.cho" "$root/src/loop_check.cho" "$root/src/snapshot.cho" "$root/src/trail.cho" "$root/src/journal.cho" "$root/src/runjournal.cho" \
    "$root/src/acceptance.cho" --std --backend cranelift -o "$pexe" >/dev/null 2>&1 || { echo "FAIL: duration: the project driver did not build" >&2; fail=1; }
for which in reference mutated; do
    wd=$(mktemp -d -t cc-eval-wd-XXXXXX); rcp=$(mktemp -d -t cc-eval-rc-XXXXXX); : > "$wd/agent.log"
    [ "$which" = reference ] && src="$root/eval/duration/reference.cho" || src="$d/dur-mutated.cho"
    printf 'cp "%s" "$1"\n' "$src" > "$rcp/parse.sh"; cp "$rcp/parse.sh" "$rcp/format.sh"
    printf 'edition 7;\nimport std.result;\nimport std.buffer;\n' > "$wd/project.cho"
    out=$("$pexe" "$CANCHO" "$root/eval/duration/plan.json" "$wd" "sh $root/tests/project/agent.sh $rcp $wd/agent.log" 2 60 2>&1); rc=$?
    if [ "$which" = reference ]; then
        expect "duration plan: the reference passes its own tests (exit)" "$rc" 0
        expect "duration plan: the reference passes its own tests (verdict)" "$(printf '%s\n' "$out" | grep PROJECT_VERDICT | cut -f2)" done
    else
        [ "$rc" != 0 ] || { echo "FAIL: duration plan: the mutated implementation passed the plan's tests" >&2; fail=1; }
    fi
    rm -rf "$wd" "$rcp"
done
# 03-csv (the untouched item): the audit, and the plan's own tests through the whole driver
csv="python3 $root/eval/audit_csv.py"
out=$($csv "$root/eval/csv/reference.cho" 2>&1); rc=$?
expect "csv: the reference holds (exit)" "$rc" 0
expect "csv: the reference scores" "$(printf '%s\n' "$out" | grep TOTAL)" "  TOTAL 50/50"
sed "s/byte_of(',')/byte_of(';')/g" "$root/eval/csv/reference.cho" > "$d/csv-mutated.cho"
cmp -s "$d/csv-mutated.cho" "$root/eval/csv/reference.cho" && { echo "FAIL: csv: the mutation changed nothing" >&2; fail=1; }
out=$($csv "$d/csv-mutated.cho" 2>&1); rc=$?
[ "$rc" != 0 ] || { echo "FAIL: csv: exit 0 for a broken implementation" >&2; fail=1; }
case "$(printf '%s\n' "$out" | grep TOTAL)" in "  TOTAL 50/50") echo "FAIL: csv: the mutation scored 50/50" >&2; fail=1 ;; esac
for which in reference mutated; do
    wd=$(mktemp -d -t cc-eval-wd-XXXXXX); rcp=$(mktemp -d -t cc-eval-rc-XXXXXX); : > "$wd/agent.log"
    [ "$which" = reference ] && src="$root/eval/csv/reference.cho" || src="$d/csv-mutated.cho"
    printf 'cp "%s" "$1"\n' "$src" > "$rcp/parse.sh"; cp "$rcp/parse.sh" "$rcp/format.sh"
    printf 'edition 7;\nimport std.list;\nimport std.result;\n' > "$wd/project.cho"
    out=$("$pexe" "$CANCHO" "$root/eval/csv/plan.json" "$wd" "sh $root/tests/project/agent.sh $rcp $wd/agent.log" 2 60 2>&1); rc=$?
    if [ "$which" = reference ]; then
        expect "csv plan: the reference passes its own tests (exit)" "$rc" 0
        expect "csv plan: the reference passes its own tests (verdict)" "$(printf '%s\n' "$out" | grep PROJECT_VERDICT | cut -f2)" done
    else
        [ "$rc" != 0 ] || { echo "FAIL: csv plan: the mutated implementation passed the plan's tests" >&2; fail=1; }
    fi
    rm -rf "$wd" "$rcp"
done
rm -f "$pexe"

rm -rf "$d"
[ "$fail" = 0 ] && echo "eval gate: ok" || { echo "eval gate: FAILED" >&2; exit 1; }
