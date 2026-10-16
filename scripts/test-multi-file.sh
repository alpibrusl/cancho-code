#!/bin/sh
# The multi-file gate (docs/multi-file.md, issue #75): a plan whose units say which module file they belong to, built by the project driver against
# stand-in agents (tests/multifile/agent.sh: no model, no network) and the real compiler.
#
#   layout       a plan of four files (three modules and project.cho) built at --jobs 1: done; each function is in its unit's file and in no other; the
#                scaffold of every file has the `module` line and the imports the plan declared (generated, not guessed); the tests of a unit of a module are
#                in that module; the unit agent is given the unit's file and is told the siblings' public signatures; state, trails, `.before` copies are per file
#   journal      `unit_start` and `attempt` events carry the unit's file (`attempt` only when it is not project.cho)
#   jobs         the same plan at --jobs 4: the same files; every unit's workspace held copies of ALL the project's files; the unit's file is what the
#                agent was given; each integrates (fast) into its own file
#   wide         units of two modules built together at --jobs 4: the unit of another file integrates by copying while the first file has changed, two units
#                of one file that define the same helper differently clash and the second is requeued with the clash, then verifies
#   pub          a unit of a module whose function is not `pub` is refused with the reason (another module could not call it), the next attempt is accepted
#   qualified    a call to another module's function without the module name is the compiler's refusal; the next attempt, with the name, is accepted
#   sweep        a unit of one file changes a function another file's unit depends on (--retry): the sweep finds the other file's unit regressed, it is rebuilt
#                with a note naming the unit that broke it
#   patch        `--patch <unit> <file>` splices the patch into the unit's file
#   resume       the agent fails on a unit of the third file: provider_error, nothing of the first is lost; the rerun builds the rest
#   no plan      a unit whose file `files` does not declare: no_plan, exit 3, the agent never asked, nothing written
#   single       a plan without files: the console, project.cho, state, tests, legends, task, snapshots, the names of the files and the journal (times masked)
#                are byte for byte what the driver wrote before this feature (tests/multifile/golden-single, written by this gate with MULTIFILE_GOLDEN=write
#                and PROJECT_SRC=<the src/ of the commit before>), at --jobs 1 and with no option
#
# Needs the real cancho as CANCHO and python3 (the journal reader). Exit 0 every case held.
set -u

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "no python3 on PATH" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
SRC="${PROJECT_SRC:-$root/src}"   # a directory to take src/ from: how the mutation runs judge a broken copy
d=$(mktemp -d -t cc-multifile-XXXXXX)
exe="$d/project"
"$CANCHO" build "$root/tests/programs/project.cho" "$SRC/project.cho" "$SRC/plan.cho" "$SRC/driver.cho" \
    "$SRC/checker.cho" "$SRC/signature.cho" "$SRC/loop_check.cho" "$SRC/snapshot.cho" "$SRC/trail.cho" \
    "$SRC/acceptance.cho" "$SRC/splice.cho" "$SRC/pool.cho" "$SRC/parallel.cho" --std --backend cranelift -o "$exe" >/dev/null 2>"$d/build.err" \
    || { cat "$d/build.err" >&2; echo "gate did not build" >&2; exit 2; }

fail=0
expect() { [ "$2" = "$3" ] || { echo "FAIL: $1: wanted '$3', got '$2'" >&2; fail=1; }; }
T="$root/tests/multifile"
J="python3 $root/tests/parallel/jlook.py"
verdict() { printf '%s\n' "$1" | grep '^\[PROJECT_VERDICT\]' | cut -f2; }
order() { tr '\n' ' ' < "$1" | sed 's/ $//'; }
has() { # name file text: the file holds the text
    grep -qF -- "$3" "$2" 2>/dev/null || { echo "FAIL: $1: '$2' lacks '$3'" >&2; fail=1; }
}
hasnot() {
    if grep -qF -- "$3" "$2" 2>/dev/null; then echo "FAIL: $1: '$2' has '$3'" >&2; fail=1; fi
    return 0
}

# a fresh work directory and recipe directory (with the good recipes); "<workdir> <recipes> <log>"
mk() {
    wd=$(mktemp -d -t cc-multifile-wd-XXXXXX); rc=$(mktemp -d -t cc-multifile-rc-XXXXXX); lg="$wd/agent.log"; : > "$lg"
    cp "$T"/recipes-good/*.sh "$rc"/
    echo "$wd $rc $lg"
}
# the driver: plan wd recipes log jobs [more options...]
runp() {
    p=$1; w=$2; r=$3; l=$4; j=$5; shift 5
    "$exe" "$CANCHO" "$p" "$w" "sh $T/agent.sh $r $l" 4 60 --jobs "$j" "$@" 2>&1
}
rec() { # file pre post code: sleep, say the first call returned, sleep, append the code to the unit's file
    cat > "$1" <<EOT
sleep $2
mkdir -p "\$1.call"; echo '{"samples":1}' > "\$1.call/meta.json"
sleep $3
printf '\n%s\n' '$4' >> "\$1"
EOT
}

# ---- single: a plan without files is what it always was -----------------------------------------------------------------------------------
snap() { # workdir console-file out-dir: what the driver wrote, with the times taken out
    w=$1; c=$2; o=$3; mkdir -p "$o"
    cp "$c" "$o/console.txt"
    (cd "$w" && ls -a | grep -v '^agent.log$' | grep -v '^\.\.\?$') > "$o/names.txt"
    for f in project.cho main.cho state.txt project.cho.task project.cho.before project.cho.snap0.cho; do cp "$w/$f" "$o/$f" 2>/dev/null; done
    for f in "$w"/tests-*.cho "$w"/legend-*.txt; do cp "$f" "$o/" 2>/dev/null; done
    sed -E 's/"[a-z_]*(ms|seconds)":[0-9]+/"MS":0/g' "$w/journal/events.jsonl" > "$o/events.jsonl"
    (cd "$w/journal/blobs" && ls) > "$o/blobs.txt"
}
G="$T/golden-single"
for j in none 1; do
    wd=$(mktemp -d -t cc-multifile-wd-XXXXXX); rc=$(mktemp -d -t cc-multifile-rc-XXXXXX); lg="$wd/agent.log"; : > "$lg"
    cp "$root/tests/project/recipes-good"/*.sh "$rc"/
    if [ "$j" = none ]; then
        "$exe" "$CANCHO" "$root/tests/project/plan.json" "$wd" "sh $root/tests/project/agent.sh $rc $lg" 4 60 > "$d/single.out" 2>&1; r=$?
    else
        "$exe" "$CANCHO" "$root/tests/project/plan.json" "$wd" "sh $root/tests/project/agent.sh $rc $lg" 4 60 --jobs 1 > "$d/single.out" 2>&1; r=$?
    fi
    expect "single ($j): exit code" "$r" 0
    if [ "${MULTIFILE_GOLDEN:-}" = write ] && [ "$j" = none ]; then
        rm -rf "${G:?}"; snap "$wd" "$d/single.out" "$G"
        echo "golden written: $G"
    else
        snap "$wd" "$d/single.out" "$d/snap-$j"
        diff -r "$G" "$d/snap-$j" > "$d/single.diff" 2>&1 || { echo "FAIL: single ($j): the driver's output differs from tests/multifile/golden-single:" >&2; head -20 "$d/single.diff" >&2; fail=1; }
    fi
    rm -rf "${wd:?}" "${rc:?}"
done
if [ "${MULTIFILE_GOLDEN:-}" = write ]; then rm -rf "${d:?}"; exit 0; fi

# ---- layout ----------------------------------------------------------------------------------------------------------------------------
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$(runp "$T/plan.json" "$wd" "$rc" "$lg" 1); r=$?
expect "layout: exit code" "$r" 0
expect "layout: verdict" "$(verdict "$out")" done
expect "layout: the order" "$(order "$lg")" "digits width cost total"
has "layout: tokens.cho is a module" "$wd/tokens.cho" "module tokens;"
has "layout: tokens.cho has the declared import" "$wd/tokens.cho" "import std.buffer;"
has "layout: parser.cho imports the module it needs" "$wd/parser.cho" "import tokens;"
has "layout: store.cho imports the module it needs" "$wd/store.cho" "import parser;"
has "layout: the root file imports the module it needs" "$wd/project.cho" "import store;"
hasnot "layout: the root file is no module" "$wd/project.cho" "module "
expect "layout: tokens.cho starts with the scaffold" "$(head -5 "$wd/tokens.cho" | tr '\n' '|')" "edition 7;||module tokens;||import std.buffer;|"
expect "layout: each function is in its unit's file only" "$(grep -c 'fn tok_digits' "$wd/tokens.cho") $(grep -c 'fn parse_width' "$wd/parser.cho") $(grep -c 'fn store_cost' "$wd/store.cho") $(grep -c 'fn app_total' "$wd/project.cho")" "1 1 1 1"
expect "layout: ... and in no other" "$(cat "$wd/parser.cho" "$wd/store.cho" "$wd/project.cho" "$wd/main.cho" | grep -c 'fn tok_digits') $(cat "$wd/tokens.cho" "$wd/store.cho" "$wd/project.cho" | grep -c 'fn parse_width')" "0 0"
expect "layout: the state" "$(order "$wd/state.txt")" "verified digits verified width verified cost verified total"
expect "layout: the file each request was given" "$(cat "$rc"/file-digits.1.txt "$rc"/file-width.1.txt "$rc"/file-cost.1.txt "$rc"/file-total.1.txt | tr '\n' ' ')" "tokens.cho parser.cho store.cho project.cho "
expect "layout: the tests of a unit of a module are in that module" "$(sed -n 2p "$wd/tests-width.cho")" "module parser;"
hasnot "layout: the root unit's tests are no module" "$wd/tests-total.cho" "module "
for u in digits width cost total; do [ -s "$wd/trail-$u.jsonl" ] || { echo "FAIL: layout: no trail for $u" >&2; fail=1; }; done
for f in tokens parser store; do [ -f "$wd/$f.cho.before" ] || { echo "FAIL: layout: no $f.cho.before" >&2; fail=1; }; done
# the task: the file, the module, what the others offer
t="$rc/seen-width.1.task"
has "layout: the task names the file" "$t" "FILE: parser.cho"
has "layout: the task names the module" "$t" "MODULE: parser"
has "layout: the task says the file already imports tokens" "$t" "IMPORTS ALREADY AT THE TOP OF parser.cho: tokens"
has "layout: the task shows the sibling's public signature" "$t" "pub fn tok_digits(n: int) -> [] int"
has "layout: ... with how to call it" "$t" "tokens.NAME(...)"
has "layout: the task says to declare pub" "$t" "Declare the function \`pub fn\`"
hasnot "layout: the sibling's body is not shown" "$t" "while m >= 10"
has "layout: the task of the first unit names its file" "$rc/seen-digits.1.task" "FILE: tokens.cho"
has "layout: files not imported are named" "$rc/seen-cost.1.task" "NOT IMPORTED BY store.cho (do not use): tokens.cho"
hasnot "layout: no note on a first request" "$t" "NOTE:"
# the journal
ev="$wd/journal/events.jsonl"
expect "journal: unit_start carries the file" "$(grep '"kind":"unit_start"' "$ev" | sed -n 's/.*"unit":"\([a-z]*\)".*"file":"\([^"]*\)".*/\1=\2/p' | tr '\n' ' ')" "digits=tokens.cho width=parser.cho cost=store.cho total=project.cho "
expect "journal: attempts of a module's unit carry the file" "$(grep '"kind":"attempt"' "$ev" | grep -c '"file":"')" 3
expect "journal: the attempt of the root unit has none" "$(grep '"kind":"attempt","unit":"total"' "$ev" | grep -c '"file":"')" 0
rm -rf "${wd:?}" "${rc:?}"

# ---- jobs: the same plan with units built side by side -------------------------------------------------------------------------------
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$(runp "$T/plan.json" "$wd" "$rc" "$lg" 4); r=$?
expect "jobs: exit code" "$r" 0
expect "jobs: verdict" "$(verdict "$out")" done
expect "jobs: the functions are in the files" "$(grep -c 'fn tok_digits' "$wd/tokens.cho") $(grep -c 'fn parse_width' "$wd/parser.cho") $(grep -c 'fn store_cost' "$wd/store.cho") $(grep -c 'fn app_total' "$wd/project.cho")" "1 1 1 1"
for u in digits width cost total; do
    expect "jobs: the workspace of $u held every file" "$(cat "$rc/ls-$u.1.txt")" "main.cho parser.cho project.cho store.cho tests-$u.cho tokens.cho "
done
expect "jobs: the file each worker was given" "$(cat "$rc"/file-digits.1.txt "$rc"/file-width.1.txt "$rc"/file-cost.1.txt "$rc"/file-total.1.txt | tr '\n' ' ')" "tokens.cho parser.cho store.cho project.cho "
expect "jobs: the integrations" "$($J "$wd" integrate)" "digits:fast:ok width:fast:ok cost:fast:ok total:fast:ok"
expect "jobs: unit_start carries the file" "$(grep '"kind":"unit_start"' "$wd/journal/events.jsonl" | grep -c '"file":"')" 4
expect "jobs: no scratch workspace is left" "$(ls "$wd" | grep -c '^units$')" 0
rm -rf "${wd:?}" "${rc:?}"

# ---- wide: two files at once; a clash inside one file ----------------------------------------------------------------------------------
set -- $(mk); wd=$1; rc=$2; lg=$3
rm -f "${rc:?}"/digits.sh "${rc:?}"/width.sh "${rc:?}"/cost.sh "${rc:?}"/total.sh
rec "$rc/one.sh" 0.3 0.3 'pub fn shared(x: int) -> [] int { return x * 2; }
pub fn tok_one(x: int) -> [] int { return shared(x) + 1; }'
rec "$rc/two.1.sh" 0.3 3.5 'pub fn shared(x: int) -> [] int { return x * 3; }
pub fn tok_two(x: int) -> [] int { return shared(x) + 1; }'
cat > "$rc/two.2.sh" <<'EOT'
grep -q 'INTEGRATE_CLASH' "$1.task" || exit 9
grep -q 'fn shared' "$1.task" || exit 9
printf '\n%s\n' 'pub fn tok_two(x: int) -> [] int { return shared(x) + x + 1; }' >> "$1"
EOT
rec "$rc/p.sh" 0.3 0.3 'pub fn parse_one(x: int) -> [] int { return x + 1; }'
rec "$rc/s.sh" 0.1 0.1 'pub fn store_all(x: int) -> [] int { return tokens.tok_one(x) + tokens.tok_two(x) + parser.parse_one(x) + 3; }'
out=$(runp "$T/plan-wide.json" "$wd" "$rc" "$lg" 4); r=$?
expect "wide: exit code" "$r" 0
expect "wide: verdict" "$(verdict "$out")" done
expect "wide: two was asked twice, the others once" "$(grep -c '^one$' "$lg") $(grep -c '^two$' "$lg") $(grep -c '^p$' "$lg") $(grep -c '^s$' "$lg")" "1 2 1 1"
expect "wide: the second request for two was told about the clash" "$(grep -c 'INTEGRATE_CLASH' "$rc/seen-two.2.task")" 1
expect "wide: the integrations (the unit of the other file is copied)" "$($J "$wd" integrate)" "one:fast:ok p:fast:ok two:merge:no two:fast:ok s:fast:ok"
expect "wide: one shared in tokens.cho" "$(grep -c 'fn shared' "$wd/tokens.cho")" 1
expect "wide: parser.cho has its function only" "$(grep -c 'fn parse_one' "$wd/parser.cho") $(grep -c 'fn tok_' "$wd/parser.cho")" "1 0"
case "$out" in *"$(printf '[INTEGRATE]\ttwo\trequeued')"*) ;; *) echo "FAIL: wide: no [INTEGRATE] two requeued line" >&2; fail=1 ;; esac
expect "wide: the state" "$(order "$wd/state.txt")" "verified one verified two verified p verified s"
rm -rf "${wd:?}" "${rc:?}"

# ---- pub: a function the next module could not call ---------------------------------------------------------------------------------
set -- $(mk); wd=$1; rc=$2; lg=$3
cat > "$rc/digits.1.sh" <<'EOT'
cat >> "$1" <<'EOS'

fn tok_digits(n: int) -> [] int {
    var d = 1;
    var m = n;
    while m >= 10 {
        m = m / 10;
        d = d + 1;
    }
    return d;
}
EOS
EOT
cat > "$rc/digits.2.sh" <<'EOT'
grep -q 'is not declared pub fn in tokens.cho' "$1.acceptance" || exit 9
sed 's/^fn tok_digits/pub fn tok_digits/' "$1" > "$1.new" && cp "$1.new" "$1"
EOT
out=$(runp "$T/plan.json" "$wd" "$rc" "$lg" 1); r=$?
expect "pub: exit code" "$r" 0
expect "pub: digits was asked twice" "$(grep -c '^digits$' "$lg")" 2
case "$out" in *"$(printf '[ACCEPTANCE]\tfail')"*) ;; *) echo "FAIL: pub: the first attempt was not refused" >&2; fail=1 ;; esac
expect "pub: the refusal is in the journal" "$(grep '"kind":"attempt","unit":"digits"' "$wd/journal/events.jsonl" | sed -n 's/.*"outcome":"\([a-z_]*\)".*/\1/p' | tr '\n' ' ')" "acceptance_failed verified "
rm -rf "${wd:?}" "${rc:?}"

# ---- qualified: another module's function without the module name ----------------------------------------------------------------------
set -- $(mk); wd=$1; rc=$2; lg=$3
cat > "$rc/width.1.sh" <<'EOT'
cat >> "$1" <<'EOS'

pub fn parse_width(n: int) -> [] int {
    return tok_digits(n) + 1;
}
EOS
EOT
cat > "$rc/width.2.sh" <<'EOT'
grep -q 'tok_digits' "$1.feedback" || exit 9
sed 's/return tok_digits/return tokens.tok_digits/' "$1" > "$1.new" && cp "$1.new" "$1"
EOT
out=$(runp "$T/plan.json" "$wd" "$rc" "$lg" 1); r=$?
expect "qualified: exit code" "$r" 0
expect "qualified: width was asked twice" "$(grep -c '^width$' "$lg")" 2
expect "qualified: one function in parser.cho" "$(grep -c 'fn parse_width' "$wd/parser.cho")" 1
rm -rf "${wd:?}" "${rc:?}"

# ---- sweep: a change in one file regresses a unit of another ---------------------------------------------------------------------------
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$(runp "$T/plan-sweep.json" "$wd" "$rc" "$lg" 1); r=$?
expect "sweep: the first run: exit code" "$r" 0
# digits again: right for its own examples (12, 0, 1000), wrong for 100; then parser.cho is written again
cat > "$rc/digits.2.sh" <<'EOT'
cat > "$1" <<'EOS'
edition 7;

module tokens;

import std.buffer;

pub fn tok_digits(n: int) -> [] int {
    if n < 10 {
        return 1;
    }
    if n < 1000 {
        return 2;
    }
    return 4;
}
EOS
EOT
cat > "$rc/width.2.sh" <<'EOT'
grep -q 'The unit digits broke this one' "$1.task" || exit 9
cat > "$1" <<'EOS'
edition 7;

module parser;

import tokens;

pub fn parse_width(n: int) -> [] int {
    if n == 100 {
        return 4;
    }
    return tokens.tok_digits(n) + 1;
}
EOS
EOT
out=$(runp "$T/plan-sweep.json" "$wd" "$rc" "$lg" 1 --retry digits --hint "count the digits"); r=$?
expect "sweep: the second run: exit code" "$r" 0
expect "sweep: parser.cho's unit regressed" "$(printf '%s\n' "$out" | grep -c "$(printf '^\[UNIT\]\twidth\tregressed')")" 1
expect "sweep: and was rebuilt" "$(grep -c '^width$' "$lg")" 2
has "sweep: the note names the unit that broke it, in another file" "$rc/seen-width.2.task" "NOTE: The unit digits broke this one"
expect "sweep: verdict" "$(verdict "$out")" done
rm -rf "${wd:?}" "${rc:?}"

# ---- patch: the splice target is the unit's file --------------------------------------------------------------------------------------------
set -- $(mk); wd=$1; rc=$2; lg=$3
mv "$rc/cost.sh" "$d/cost.sh"
out=$(runp "$T/plan.json" "$wd" "$rc" "$lg" 1); r=$?
expect "patch: the first run stops at cost (its agent fails): exit code" "$r" 4
printf 'pub fn store_cost(n: int) -> [] int {\n    return parser.parse_width(n) * 2;\n}\n' > "$d/cost-patch.cho"
out=$(runp "$T/plan.json" "$wd" "$rc" "$lg" 1 --patch cost "$d/cost-patch.cho"); r=$?
case "$out" in *"$(printf '[PATCH]\tcost\tverified')"*) ;; *) echo "FAIL: patch: not verified" >&2; fail=1 ;; esac
expect "patch: the function is in store.cho" "$(grep -c 'fn store_cost' "$wd/store.cho")" 1
expect "patch: ... and nowhere else" "$(cat "$wd/project.cho" "$wd/parser.cho" "$wd/tokens.cho" | grep -c 'fn store_cost')" 0
expect "patch: the patch needed no agent (the unit waiting for it was built)" "$(order "$lg")" "digits width cost total"
rm -rf "${wd:?}" "${rc:?}"

# ---- resume ---------------------------------------------------------------------------------------------------------------------------------
set -- $(mk); wd=$1; rc=$2; lg=$3
mv "$rc/cost.sh" "$d/cost.sh"
out=$(runp "$T/plan.json" "$wd" "$rc" "$lg" 1); r=$?
expect "resume: the agent failing on cost: exit code" "$r" 4
expect "resume: provider_error" "$(verdict "$out")" provider_error
expect "resume: the state keeps the first two" "$(order "$wd/state.txt")" "verified digits verified width"
cp "$d/cost.sh" "$rc/cost.sh"
out=$(runp "$T/plan.json" "$wd" "$rc" "$lg" 4); r=$?
expect "resume: the rerun: exit code" "$r" 0
expect "resume: only cost and total are built" "$(order "$lg")" "digits width cost cost total"
expect "resume: tokens.cho still has one function" "$(grep -c 'fn tok_digits' "$wd/tokens.cho")" 1
rm -rf "${wd:?}" "${rc:?}"

# ---- std: the standard modules a file's signatures name are imported by the scaffold --------------------------------------------------
set -- $(mk); wd=$1; rc=$2; lg=$3
cat > "$rc/first.sh" <<'EOT'
cat >> "$1" <<'EOS'

pub fn tok_first(n: int) -> [] option.Option[int] {
    if n > 0 {
        return option.Option::Some(n);
    }
    return option.Option::None;
}
EOS
EOT
out=$(runp "$T/plan-std.json" "$wd" "$rc" "$lg" 1); r=$?
expect "std: exit code" "$r" 0
has "std: tokens.cho imports std.option (from the signature)" "$wd/tokens.cho" "import std.option;"
expect "std: project.cho is as the driver made it" "$(cat "$wd/project.cho")" "edition 7;"
rm -rf "${wd:?}" "${rc:?}"

# ---- no plan: a file the plan does not declare ----------------------------------------------------------------------------------------------
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$(runp "$T/plan-bad-file.json" "$wd" "$rc" "$lg" 1); r=$?
expect "no plan: exit code" "$r" 3
expect "no plan: verdict" "$(verdict "$out")" no_plan
expect "no plan: the rule" "$(printf '%s\n' "$out" | grep '^\[PLAN_ERROR\]' | cut -f2,3 | tr '\t' ':')" "unknown-file:digits"
expect "no plan: the agent was never asked" "$(wc -l < "$lg" | tr -d ' ')" 0
if [ -f "$wd/tokens.cho" ]; then echo "FAIL: no plan: a file was written" >&2; fail=1; fi
rm -rf "${wd:?}" "${rc:?}"

rm -rf "${d:?}"
if [ "$fail" = 0 ]; then echo "multi-file gate: ok"; exit 0; fi
echo "multi-file gate: FAILED" >&2
exit 1
