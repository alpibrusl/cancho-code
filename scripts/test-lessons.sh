#!/bin/sh
# The memory gate (docs/memory.md): the miner (`cancho-lessons`, src/lessons.cho) and the recall path (src/memory.cho, src/prompt.cho).
#
#   scripts/test-lessons.sh             the gate
#   scripts/test-lessons.sh --mutants   prove the gate can fail: broken copies of src/lessons.cho and src/memory.cho must each be RED
#
#   CANCHO           the compiler (default: cancho on PATH)
#   LESSONS_SRC      the miner to judge   (default: src/lessons.cho); how --mutants judges a broken copy
#   MEMORY_SRC       the class and recall module to judge (default: src/memory.cho)
#
# What it asserts
#   class     the normalisation of a refusal into its class (tests/memory_test.cho): names, types, numbers, paths, test names; direction kept; bounded
#   mining    on the fixture journals under tests/lessons/ the tool's lessons.jsonl equals the independent oracle tests/reference/lessons_ref.py, and
#             - a refusal that recurs (3 times in 2 runs, fixed the same way) is `active` with its counts, its fix and its evidence references;
#             - one seen twice in one run is `insufficient`; the thresholds are the flags (--min-count, --min-runs), not constants;
#             - a lesson recalled twice or more and refused again each time is `superseded` (kept, with its history); one that verified more often than
#               it failed stays `active`: the data decides, never the model;
#             - a stand-in key in a prompt, a reply, a diff or a signature of a mined journal is nowhere in lessons.jsonl; a diff blob named outside the
#               blobs directory is not read; a journal killed mid-line, with a garbage line and a missing blob, mines what it holds; empty input gives an
#               empty file; the run directories are not changed; the file stops at 256 KiB; ignore.txt removes a lesson for good
#   legacy    trails (`trail-<unit>.jsonl`) of runs that left no journal give counts and the next attempt's success, never a fix
#   promote   `--promote` prints the lessons with a lot of evidence and a fix and writes nothing
#   recall    with a memory directory the prompt gets a `Known pitfalls` block for the refusal's class only: absent for a superseded, an under-evidenced,
#             a fix-less or a different-class lesson; bounded in lines and bytes whatever the file holds; the person's facts (facts.txt) are in every
#             prompt, capped; every injected lesson and fact is recorded in <project>.call/memory.json (the journal's `memory` field); nothing is
#             written when nothing is injected; the task file is not touched
set -u

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "no python3 on PATH" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
lessons_src="${LESSONS_SRC:-$root/src/lessons.cho}"
memory_src="${MEMORY_SRC:-$root/src/memory.cho}"
fx="$root/tests/lessons"

if [ "${1:-}" = "--mutants" ]; then
    work=$(mktemp -d -t cc-lessons-mut-XXXXXX)
    trap 'rm -rf "$work"' EXIT
    fail=0
    # Each mutation is one edit of one marked line (`// MUTANT:<marker>`); the gate on the broken copy must fail. A refactor that loses the marker is itself a red.
    mutant() {
        name=$1; file=$2; marker=$3; from=$4; to=$5
        grep -q "// MUTANT:$marker" "$root/src/$file" || { echo "FAIL: no marker MUTANT:$marker in src/$file" >&2; fail=1; return; }
        python3 - "$root/src/$file" "$work/$name.cho" "$marker" "$from" "$to" <<'PY' || { echo "FAIL: mutant $name: the marked line does not contain the text to change" >&2; fail=1; return; }
import sys
src, dst, marker, a, b = sys.argv[1:6]
out, hit = [], 0
for line in open(src).read().split("\n"):
    if "// MUTANT:" + marker in line and a in line:
        line, hit = line.replace(a, b), hit + 1
    out.append(line)
sys.exit(0 if hit == 1 and open(dst, "w").write("\n".join(out)) else 1)
PY
        if [ "$file" = lessons.cho ]; then
            LESSONS_SRC="$work/$name.cho" sh "$0" >"$work/$name.out" 2>&1; rc=$?
        else
            MEMORY_SRC="$work/$name.cho" sh "$0" >"$work/$name.out" 2>&1; rc=$?
        fi
        if [ $rc = 0 ]; then
            echo "FAIL: mutant $name survived: the gate passed on a broken copy" >&2; fail=1
        else
            echo "mutant $name: red, as it should be ($(grep -m1 FAIL "$work/$name.out" | cut -c1-110))"
        fi
    }
    mutant threshold-count lessons.cho minc 'tget(st, c, c_count()) >= st[g_min_count()]' 'tget(st, c, c_count()) > st[g_min_count()]'
    mutant contradicted-still-active lessons.cho super '>= 2 &&' '>= 99 &&'
    mutant runs-counted-wrong lessons.cho runs 'tget(st, c, c_last_run()) != run' 'tget(st, c, c_last_run()) == run'
    mutant secret-copied memory.cho redact 'j - i >= 20' 'j - i >= 2000'
    mutant blob-outside-blobs lessons.cho plain 'if len(name) == 0 ||' 'if len(name) > 0 { return true; } if len(name) == 0 ||'
    mutant block-unbounded memory.cho cap 'used + len(l1) + 5 > block_cap() || lines >= block_lines()' 'false'
    mutant class-mismatch-recalled memory.cho class 'bytes.equal(scratch[0..cn], class) == false' 'bytes.starts_with(scratch[0..cn], "type-mismatch") == false'
    mutant superseded-recalled memory.cho status '"active") == false' '"active") == false && false'
    mutant recall-threshold-count memory.cho evidence 'count_at(line, tape, 0, "count") < min_count()' 'count_at(line, tape, 0, "count") < 2'
    mutant recall-threshold-runs memory.cho evidence 'count_at(line, tape, 0, "runs") < min_runs()' 'count_at(line, tape, 0, "runs") < 1'
    mutant injection-not-journalled memory.cho journal 'fs_write(fs, buffer.bytes(pq), buffer.bytes(rq));' 'fs_write(fs, "/dev/null", buffer.bytes(rq));'
    [ "$fail" = 0 ] && echo "lessons gate mutants: all red" || { echo "lessons gate mutants: FAILED" >&2; exit 1; }
    exit 0
fi

work=$(mktemp -d -t cc-lessons-XXXXXX)
trap 'rm -rf "$work"' EXIT
fail=0
expect() { [ "$2" = "$3" ] || { echo "FAIL: $1: wanted '$3', got '$2'" >&2; fail=1; }; }
fails() { echo "FAIL: $1" >&2; fail=1; }

# ---- the class of a refusal --------------------------------------------------------------------------------------------------------------
"$CANCHO" test "$root/tests/memory_test.cho" "$memory_src" "$root/src/signature.cho" --std --backend cranelift >"$work/unit.out" 2>&1 \
    || { fails "class: the unit tests of the normalisation fail"; grep -E "FAILED|error" "$work/unit.out" | head -5 >&2; }

# ---- the tool and the recall gate program -----------------------------------------------------------------------------------------------
tool="$work/lessons"
"$CANCHO" build "$root/tests/programs/lessons.cho" "$lessons_src" "$memory_src" "$root/src/signature.cho" --std --backend cranelift -o "$tool" >/dev/null 2>"$work/build.err" \
    || { cat "$work/build.err" >&2; echo "gate did not build the tool" >&2; exit 2; }
rgate="$work/memory_gate"
"$CANCHO" build "$root/tests/programs/memory_gate.cho" "$memory_src" "$root/src/prompt.cho" "$root/src/signature.cho" --std --backend cranelift -o "$rgate" >/dev/null 2>"$work/build2.err" \
    || { cat "$work/build2.err" >&2; echo "gate did not build the recall program" >&2; exit 2; }

ref="$root/tests/reference/lessons_ref.py"
# the inputs of a fixture group: every directory under it is a run (a journal), or a legacy run when it holds trail files
inputs() {
    a=""
    for r in "$fx/$1"/*/; do
        r=${r%/}
        if ls "$r"/trail-*.jsonl >/dev/null 2>&1; then
            for t in "$r"/trail-*.jsonl; do a="$a --trail $t"; done
        else
            a="$a --run $r"
        fi
    done
    echo "$a"
}
# q <lessons.jsonl> <python expression over L (the lines) and by (the lines by id)>
q() { python3 - "$1" "$2" <<'PY'
import json, sys
L = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
by = {l["id"]: l for l in L}
print(eval(sys.argv[2]))
PY
}
A=L864bef6c   # type-mismatch: expected `T`, found `Buffer`
B=L6238ad87   # unknown-name: `N` has no variant `N`
C=Le876a31a   # not-a-function: `N` is not a function in this program
D=L1abe01d5   # unknown-name: `List` has no variant `N`

mine() { # <name> <args...>: mine into $work/mem-<name>, stderr to $work/err-<name>
    name=$1; shift
    mkdir -p "$work/mem-$name"
    "$tool" --memory "$work/mem-$name" "$@" >"$work/out-$name" 2>"$work/err-$name"
}
same_as_oracle() { # <name> <args...>
    name=$1; shift
    python3 "$ref" "$@" > "$work/ref-$name.jsonl"
    python3 - "$work/mem-$name/lessons.jsonl" "$work/ref-$name.jsonl" <<'PY' || fails "oracle: $name: the tool and tests/reference/lessons_ref.py disagree"
import json, sys
a = [json.loads(l) for l in open(sys.argv[1])]
b = [json.loads(l) for l in open(sys.argv[2])]
if a != b:
    for i, (x, y) in enumerate(zip(a, b)):
        for k in x:
            if x[k] != y.get(k):
                print("line %d, %s: tool %r, oracle %r" % (i, k, x[k], y.get(k)), file=sys.stderr)
    if len(a) != len(b):
        print("%d lines against %d" % (len(a), len(b)), file=sys.stderr)
    sys.exit(1)
PY
}

before=$(cd "$fx" && find . -type f | sort | xargs cksum | cksum)

# ---- mining ----------------------------------------------------------------------------------------------------------------------------------
for g in recurring contradicted held secrets traversal killed empty legacy; do
    mine "$g" $(inputs $g); expect "mining $g: exit code" "$?" 0
    same_as_oracle "$g" $(inputs $g)
done
m="$work/mem-recurring/lessons.jsonl"
expect "recurring: three occurrences in two runs and three units" "$(q $m "[by['$A'][k] for k in ('count','runs','units')]")" "[3, 2, 3]"
expect "recurring: it is active" "$(q $m "by['$A']['status']")" active
expect "recurring: the attempt after it verified in 2 of 3" "$(q $m "[by['$A']['next_seen'], by['$A']['next_verified']]")" "[3, 2]"
expect "recurring: the fix is the shortest diff, an excerpt of changed lines" "$(q $m "by['$A']['fixes'][0]['diff']")" "-    let n = len(b);
+    let n = len(buffer.bytes(b));"
expect "recurring: every fix is a bounded excerpt" "$(q $m "all(len(f['diff'].encode()) <= 600 and len(f['diff'].splitlines()) <= 14 for l in L for f in l['fixes'])")" True
expect "recurring: the evidence names run, unit and attempt" "$(q $m "by['$A']['evidence']")" "[{'run': 'r1', 'unit': 'u1', 'attempt': 0}, {'run': 'r1', 'unit': 'u2', 'attempt': 0}, {'run': 'r2', 'unit': 'u1', 'attempt': 0}]"
expect "recurring: first and last seen are the journal's own times" "$(q $m "[by['$A']['first'], by['$A']['last']]")" "[1792000001000, 1792000008000]"
expect "recurring: the class and the id" "$(q $m "[by['$A']['class'], by['$A']['rule']]")" "['type-mismatch:expected \`T\`, found \`Buffer\`', 'type-mismatch']"
expect "recurring: seen twice in one run is insufficient" "$(q $m "[by['$B']['status'], by['$B']['count'], by['$B']['runs']]")" "['insufficient', 2, 1]"
expect "recurring: active comes first" "$(q $m "L[0]['id']")" "$A"
mine strict --min-count 4 $(inputs recurring)
expect "threshold: --min-count 4 makes the lesson insufficient" "$(q $work/mem-strict/lessons.jsonl "by['$A']['status']")" insufficient
mine strict2 --min-runs 3 $(inputs recurring)
expect "threshold: --min-runs 3 makes the lesson insufficient" "$(q $work/mem-strict2/lessons.jsonl "by['$A']['status']")" insufficient
mine lax --min-count 2 --min-runs 1 $(inputs recurring)
expect "threshold: --min-count 2 --min-runs 1 makes the other one active" "$(q $work/mem-lax/lessons.jsonl "by['$B']['status']")" active
same_as_oracle strict --min-count 4 $(inputs recurring)

c="$work/mem-contradicted/lessons.jsonl"
expect "contradicted: recalled three times and refused again each time" "$(q $c "[by['$C'][k] for k in ('contradicted','confirmed','status')]")" "[3, 0, 'superseded']"
expect "contradicted: the history is kept (fixes and evidence stay)" "$(q $c "[len(by['$C']['fixes']) > 0, by['$C']['count'], by['$C']['runs']]")" "[True, 8, 3]"
h="$work/mem-held/lessons.jsonl"
expect "held: recalled five times, verified three, refused twice: still active" "$(q $h "[by['$D'][k] for k in ('contradicted','confirmed','status')]")" "[2, 3, 'active']"

# a key in a journal: the miner never reads a prompt or a reply, and a diff or a signature that holds one is cut
k="$work/mem-secrets/lessons.jsonl"
[ -s "$k" ] || fails "secrets: no lessons were mined from the journal with the key"
for frag in sk-ant-test 0123456789 not-a-real-key; do
    if grep -q -- "$frag" "$k" "$work"/mem-secrets/* "$work/err-secrets" "$work/out-secrets" 2>/dev/null; then fails "secrets: '$frag' of the stand-in key is in the memory directory or the output"; fi
done
grep -q '\[redacted\]' "$k" || fails "secrets: the key in the diff was not replaced by a mark"
# a diff blob named outside the blobs directory is not read
t="$work/mem-traversal/lessons.jsonl"
if grep -q "TOPSECRET\|localhost" "$t"; then fails "traversal: a file outside the blobs directory was read"; fi
expect "traversal: no fix from a blob named ../../secret.txt or /etc/hosts" "$(q $t "len(by['$A']['fixes'])")" 0
# a killed journal: a garbage line, a half-written last line, a missing blob
expect "killed: counts from what is whole" "$(q $work/mem-killed/lessons.jsonl "[by['$A']['count'], by['$A']['runs'], by['$A']['units'], by['$A']['next_seen'], by['$A']['next_verified'], len(by['$A']['fixes'])]")" "[3, 1, 3, 2, 2, 1]"
grep -q "2 lines skipped" "$work/err-killed" || fails "killed: the summary does not say two lines were skipped ($(cat $work/err-killed))"
# empty input
[ -f "$work/mem-empty/lessons.jsonl" ] && [ ! -s "$work/mem-empty/lessons.jsonl" ] || fails "empty: an empty journal and a directory with none must give an empty file"
mine nothing --run "$work/does-not-exist"; expect "empty: a run directory that is not there is not an error" "$?" 0
# legacy trails
lg="$work/mem-legacy/lessons.jsonl"
expect "legacy: counts and the next attempt, from trails" "$(q $lg "[by['$C']['count'], by['$C']['runs'], by['$C']['units'], by['$C']['next_seen'], by['$C']['next_verified'], by['$C']['source']]")" "[3, 2, 2, 3, 2, 'legacy']"
expect "legacy: never a fix" "$(q $lg "all(l['fixes'] == [] and l['source'] == 'legacy' for l in L)")" True
expect "legacy: a test's name is not part of the class" "$(q $lg "[l['class'] for l in L if l['rule'] == 'acceptance']")" "['acceptance:test N ... FAILED']"
# the same input twice gives the same file; the fixtures are not touched
mine again $(inputs recurring)
cmp -s "$work/mem-again/lessons.jsonl" "$work/mem-recurring/lessons.jsonl" || fails "idempotence: two runs on the same journals gave different files"
after=$(cd "$fx" && find . -type f | sort | xargs cksum | cksum)
expect "read-only: the run directories are as they were" "$after" "$before"
# ignore.txt: a person's deletion that stays
mkdir -p "$work/mem-ign"; printf '%s\n' "$A" > "$work/mem-ign/ignore.txt"
"$tool" --memory "$work/mem-ign" $(inputs recurring) >/dev/null 2>&1
expect "ignore: a lesson named in ignore.txt is not written again" "$(q $work/mem-ign/lessons.jsonl "'$A' in by")" False
# the size cap: 700 classes, each with a fix
python3 - "$work/big" <<'PY'
import json, os, sys
d = sys.argv[1] + "/big"
os.makedirs(d + "/journal/blobs")
ev = []
for i in range(700):
    ev.append({"t_ms": 1000 + 3 * i, "kind": "attempt", "unit": "u%d" % (i % 200), "n": 0, "outcome": "refused", "signature": "rule%d:something broke" % i})
    ev.append({"t_ms": 1001 + 3 * i, "kind": "attempt", "unit": "u%d" % (i % 200), "n": 1, "outcome": "verified", "signature": "", "diff": "d%d.txt" % i})
    open(d + "/journal/blobs/d%d.txt" % i, "w").write("".join("+    line_%d_%d = some_call(argument, other_argument, more, even_more_arguments);\n" % (i, j) for j in range(8)))
open(d + "/journal/events.jsonl", "w").write("".join(json.dumps(e) + "\n" for e in ev))
PY
mine big --run "$work/big/big"; expect "size: exit code" "$?" 0
sz=$(wc -c < "$work/mem-big/lessons.jsonl" | tr -d ' ')
[ "$sz" -le 262144 ] && [ "$sz" -gt 200000 ] || fails "size: lessons.jsonl is $sz bytes, wanted at most 262144 and a file that was filled"
grep -q "left out for size" "$work/err-big" && ! grep -q " 0 left out for size" "$work/err-big" || fails "size: the summary does not count what was left out ($(cat $work/err-big))"

# usage errors write nothing
mkdir -p "$work/u1"
"$tool" --run "$fx/recurring/r1" >/dev/null 2>&1; expect "usage: no --memory is exit 2" "$?" 2
"$tool" --memory relative/dir --run "$fx/recurring/r1" >/dev/null 2>&1; expect "usage: a relative memory directory is exit 2" "$?" 2
"$tool" --memory "$work/u1" --run "relative/run" >/dev/null 2>&1; expect "usage: a relative run directory is exit 2" "$?" 2
"$tool" --memory "$work/u1/../u1" --run "$fx/recurring/r1" >/dev/null 2>&1; expect "usage: .. is exit 2" "$?" 2
"$tool" --memory "$work/u1" >/dev/null 2>&1; expect "usage: no input is exit 2" "$?" 2
"$tool" --memory "$work/u1" --promote --run "$fx/recurring/r1" >/dev/null 2>&1; expect "usage: --promote with an input is exit 2" "$?" 2
"$tool" --memory "$work/u1" --min-count 0 --run "$fx/recurring/r1" >/dev/null 2>&1; expect "usage: --min-count 0 is exit 2" "$?" 2
"$tool" --memory "$work/u1" --bogus >/dev/null 2>&1; expect "usage: an unknown flag is exit 2" "$?" 2
[ -z "$(ls "$work/u1")" ] || fails "usage: a usage error wrote something"
"$tool" --memory "$work/no/such/dir" --run "$fx/recurring/r1" >/dev/null 2>&1; expect "write: an unwritable memory directory is exit 1" "$?" 1

# ---- promotion ------------------------------------------------------------------------------------------------------------------------------
cp "$fx/memory/good/lessons.jsonl" "$work/promo.jsonl"; mkdir -p "$work/pm"; cp "$work/promo.jsonl" "$work/pm/lessons.jsonl"
ls "$work/pm" > "$work/pm.before"
"$tool" --memory "$work/pm" --promote >"$work/promote.out" 2>"$work/promote.err"; expect "promote: exit code" "$?" 0
grep -q "Pitfall: type-mismatch:expected" "$work/promote.out" && grep -q "len(buffer.bytes(b))" "$work/promote.out" || fails "promote: the lesson with 5 occurrences in 3 runs and a fix is not printed with its fix"
expect "promote: only the active lessons with enough evidence and a fix" "$(grep -c '^## ' "$work/promote.out")" 2
if grep -q "has no variant\|is not a function" "$work/promote.out"; then fails "promote: a superseded or insufficient lesson was printed"; fi
ls "$work/pm" > "$work/pm.after"
cmp -s "$work/pm.before" "$work/pm.after" && cmp -s "$work/promo.jsonl" "$work/pm/lessons.jsonl" || fails "promote: it changed the memory directory"
mkdir -p "$work/pm2"; "$tool" --memory "$work/pm2" --promote >/dev/null 2>"$work/promote2.err"; expect "promote: no lessons file is exit 1" "$?" 1

# ---- recall -----------------------------------------------------------------------------------------------------------------------------------
# feedback as the checker prints it
feedback() { printf '{\n  "refused": [\n    {\n      "rule": "%s",\n      "message": "%s",\n      "position": { "file": "/x/project.cho", "line": 2, "column": 30 }\n    }\n  ]\n}\n' "$1" "$2" > "$3"; }
prompt_for() { # <memory dir> <rule> <message> -> $work/rp/prompt.txt; the sidecar is $work/rp/project.cho.call/memory.json
    rm -rf "$work/rp"; mkdir -p "$work/rp/project.cho.call"
    printf 'edition 7;\nfn broken() -> [] int { return true; }\n' > "$work/rp/project.cho"
    printf 'Write a function broken.\nHINT: try again\n' > "$work/rp/project.cho.task"
    feedback "$2" "$3" "$work/rp/project.cho.feedback"
    "$rgate" "$1" "$work/rp/project.cho" > "$work/rp/prompt.txt" 2>"$work/rp/err.txt"; rc=$?
    [ $rc = 0 ] || fails "recall: the gate program exited $rc ($(head -c 200 "$work/rp/err.txt"))"
}
has() { grep -q -- "$1" "$work/rp/prompt.txt"; }
good="$fx/memory/good"; bad="$fx/memory/bad"
prompt_for "$good" type-mismatch 'expected `&[byte]`, found `Buffer`'
has "Known pitfalls, found in the journals" || fails "recall: no pitfalls block for a refusal of a class the memory knows"
has "+    let n = len(buffer.bytes(b));" || fails "recall: the fix is not in the block"
has "recurred 5 times in 3 runs; the attempt after it verified 4 of 5" || fails "recall: the evidence is not in the block"
has "no network" && has "lowercase_with_underscores" || fails "recall: the person's facts are not in the prompt"
has "HINT" && fails "recall: the HINT line leaked into the prompt as it is"
has "try again" || fails "recall: the person's hint was lost"
mj="$work/rp/project.cho.call/memory.json"
expect "journal: the memory field names the lesson and the facts" "$(python3 -c "import json; print([m['id'] for m in json.load(open('$mj'))])")" "['$A', 'F1', 'F2']"
expect "journal: the lesson's text in the field is the text in the prompt" "$(python3 - "$mj" "$work/rp/prompt.txt" <<'PY'
import json, sys
t = json.load(open(sys.argv[1]))[0]["text"]
p = open(sys.argv[2]).read()
print(all(("    " + l if False else l) in p for l in t.splitlines()))
PY
)" True
expect "recall: the task file is as it was" "$(cat "$work/rp/project.cho.task")" "Write a function broken.
HINT: try again"
# a plan's own text that looks like the memory's lines is not the memory
mkdir -p "$work/emptymem2"
rm -rf "$work/rp"; mkdir -p "$work/rp"; printf 'edition 7;\nfn x() -> [] int { return 1; }\n' > "$work/rp/project.cho"; printf 'Write x.\nMEMORY: sneaky one\nFACT: sneaky two\n' > "$work/rp/project.cho.task"
"$rgate" "$work/emptymem2" "$work/rp/project.cho" > "$work/rp/prompt.txt" 2>/dev/null
has "sneaky one" && has "sneaky two" || fails "recall: a plan's own MEMORY:/FACT: lines were taken out of the job"
has "Known pitfalls" && fails "recall: a plan's own MEMORY: line made a pitfalls block"
has "holds for every unit" && fails "recall: a plan's own FACT: line made a facts block"
# a superseded lesson, an under-evidenced one, one without a fix, and a different class are not recalled
prompt_for "$good" not-a-function '`empty` is not a function in this program'
has "Known pitfalls" && fails "recall: a superseded lesson was recalled"
prompt_for "$good" unknown-name '`List` has no variant `Nil`'
has "Known pitfalls" && fails "recall: an insufficient lesson was recalled"
prompt_for "$good" type-mismatch 'expected `int`, found `float`'
has "Known pitfalls" && fails "recall: a lesson of another class was recalled"
prompt_for "$good" type-mismatch 'expected `bool`, found `int`'
has "Known pitfalls" || fails "recall: the lesson of exactly this class (bool for int) was not recalled"
has "no network" || fails "recall: facts are in every prompt"
prompt_for "$bad" not-a-function '`empty` is not a function in this program'
has "Known pitfalls" && fails "recall: a lesson with one run of evidence was recalled"
prompt_for "$bad" unknown-name '`List` has no variant `Nil`'
has "Known pitfalls" && fails "recall: a lesson with no fix was recalled"
prompt_for "$bad" arity 'expected 2 arguments, found 3'
has "Known pitfalls" && fails "recall: a lesson with two occurrences was recalled"
[ ! -e "$work/rp/project.cho.call/memory.json" ] || fails "journal: a memory.json was written though nothing was injected"
# bounded: fixes of 60 lines each
prompt_for "$bad" type-mismatch 'expected `&[byte]`, found `Buffer`'
has "Known pitfalls" || fails "recall: the big lesson was not recalled at all"
python3 - "$work/rp/prompt.txt" <<'PY' || fails "recall: the block is not bounded"
import sys
p = open(sys.argv[1]).read()
a = p.index("Known pitfalls")
b = p.index("\n---\n", a)
block = p[a:b].split("\n", 1)[1]
lines = block.splitlines()
ok = len(lines) <= 24 and len(block.encode()) <= 1700
sys.exit(0 if ok else 1)
PY
expect "journal: the injected text is bounded too" "$(python3 -c "import json; print(len(open('$work/rp/project.cho.call/memory.json').read().encode()) < 8192)")" True
# no memory directory, or an empty one: the prompt is as it is without memory
mkdir -p "$work/emptymem"
prompt_for "$work/emptymem" type-mismatch 'expected `&[byte]`, found `Buffer`'; cp "$work/rp/prompt.txt" "$work/rp-empty.txt"
[ ! -e "$work/rp/project.cho.call/memory.json" ] || fails "journal: an empty memory wrote a memory.json"
prompt_for "$work/not-there" type-mismatch 'expected `&[byte]`, found `Buffer`'
cmp -s "$work/rp/prompt.txt" "$work/rp-empty.txt" || fails "recall: a missing memory directory changes the prompt"
has "Known pitfalls" && fails "recall: pitfalls from nothing"
# the checker said something that is not JSON: no lesson, the facts stay
rm -rf "$work/rp"; mkdir -p "$work/rp"; printf 'edition 7;\nfn x() -> [] int { return 1; }\n' > "$work/rp/project.cho"; printf 'plain text from a checker that is not cancho\n' > "$work/rp/project.cho.feedback"
"$rgate" "$good" "$work/rp/project.cho" > "$work/rp/prompt.txt" 2>/dev/null; has "Known pitfalls" && fails "recall: a lesson from feedback that is not JSON"
has "no network" || fails "recall: facts are not in the prompt when the feedback is not JSON"
[ ! -d "$work/rp/project.cho.call" ] || fails "journal: a .call directory was made by the memory"
# facts are capped: 30 lines of 300 bytes, a comment, a blank
mkdir -p "$work/factsmem"
python3 - "$work/factsmem/facts.txt" <<'PY'
import sys
with open(sys.argv[1], "w") as f:
    f.write("# comment\n\n")
    for i in range(30):
        f.write("fact %d " % i + "x" * 290 + "\n")
PY
prompt_for "$work/factsmem" type-mismatch 'expected `&[byte]`, found `Buffer`'
expect "facts: at most ten, each cut" "$(python3 - "$work/rp/prompt.txt" <<'PY'
import sys
p = open(sys.argv[1]).read()
a = p.index("holds for every unit:\n") + len("holds for every unit:\n")
fs = [l for l in p[a:p.index("\n---\n", a)].splitlines()]
print(len(fs), max(len(l) for l in fs) <= 2 + 160)
PY
)" "10 True"

[ "$fail" = 0 ] && echo "lessons gate: ok" || { echo "lessons gate: FAILED" >&2; exit 1; }
