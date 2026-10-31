#!/bin/sh
# The repo.patch gate (docs/repo-patch.md): a change request answered for an existing repository checkout. No model, no network, no key; the checker, the
# formatter and the test runner are the real compiler (CANCHO), the agent a stand-in (tests/repochange/agent.sh) that answers from recipe files.
#
#   pure       src/change.cho and the parts of src/splice.cho it uses, one function at a time (tests/programs/change_gate.cho): the paths that may not be
#              written (absolute, `..`, `.git`, outside src/ and tests/, odd bytes), the kinds, the envelope in a reply, its sections, a section into a file
#              (items added or replaced, items removed, a removal of an item that is not there, a new file), the test functions a file adds or changes
#   happy      a feature over two files (src/ and tests/), written unformatted: `cancho fmt` runs on both, the gate passes, change.patch is the diff of the
#              copy against the base and applies to a fresh copy of the repository, the original is byte for byte what it was (also when it is read-only)
#   remove     a rename (kind rename, remove + add, the tests changed to the new name): the old function is gone from the tree; a removal of an item that
#              does not exist is refused and the feedback of the next attempt says so; a removal of an item the tests still call is refused by the
#              compiler (tests-failed) and the feedback says so
#   tests      kind feature or bug with no test added: refused as `no-test-added`, the retry feedback names it; the same reply is accepted for refactor and
#              rename; a changed test function counts
#   bounds     more files than allowed, more bytes than allowed, an absolute path, `..`, `.git`, a file outside src/ and tests/, the same file twice: each
#              refused by its tag, nothing written outside the work directory
#   agent      the agent gives up (exit 11) and is asked again; the agent cannot be reached (exit 7): provider_error, exit 4
#   usage      a repository with a link in src/, no src/, a work directory inside the repository, a relative path, an unknown kind, a missing option: exit 2,
#              nothing run
#   static     the driver never runs git (no `git` word in its code outside comments)
#
# Needs the real cancho as CANCHO and python3 not at all (sh, tar, diff, patch). Exit 0: every case held.
set -u

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
CANCHO=$(command -v "$CANCHO")
root=$(cd "$(dirname "$0")/.." && pwd)
SRC="${REPOPATCH_SRC:-$root/src}"
d=$(mktemp -d -t cc-repopatch-XXXXXX)
trap 'chmod -R u+w "$d" 2>/dev/null; rm -rf "$d"' EXIT
fail=0
expect() { [ "$2" = "$3" ] || { echo "FAIL: $1: wanted '$3', got '$2'" >&2; fail=1; }; }
has() { case "$2" in *"$3"*) ;; *) echo "FAIL: $1: '$3' not in: $(printf '%s' "$2" | head -c 300)" >&2; fail=1 ;; esac; }
hasnt() { case "$2" in *"$3"*) echo "FAIL: $1: '$3' should not be in: $(printf '%s' "$2" | head -c 300)" >&2; fail=1 ;; esac; }

"$CANCHO" build "$root/tests/programs/change_gate.cho" "$SRC/change.cho" "$SRC/splice.cho" --std --backend cranelift -o "$d/gate" >/dev/null 2>"$d/build.err" \
    || { cat "$d/build.err" >&2; echo "pure gate did not build" >&2; exit 2; }
"$CANCHO" build "$root/tests/programs/build.cho" "$SRC/build.cho" "$SRC/project.cho" "$SRC/plan.cho" "$SRC/driver.cho" \
    "$SRC/checker.cho" "$SRC/signature.cho" "$SRC/loop_check.cho" "$SRC/snapshot.cho" "$SRC/trail.cho" \
    "$SRC/acceptance.cho" "$SRC/splice.cho" "$SRC/pool.cho" "$SRC/parallel.cho" "$SRC/library.cho" "$SRC/cases.cho" "$SRC/change.cho" "$SRC/repochange.cho" \
    --std --backend cranelift -o "$d/cb" >/dev/null 2>"$d/build2.err" || { cat "$d/build2.err" >&2; echo "gate did not build" >&2; exit 2; }
G="$d/gate"
F="$root/tests/fixtures/repochange"

# ---- pure ---------------------------------------------------------------------------------------------------------------------------------
for spec in 'src/a.cho:ok' 'tests/a_test.cho:ok' 'src/sub/dir/a.cho:ok' '/etc/x.cho:path-absolute' '../x/a.cho:path-dotdot' 'src/../a.cho:path-dotdot' \
            '.git/x.cho:path-git' 'src/.git/a.cho:path-git' 'src/.hidden.cho:path-component' 'lib/a.cho:path-outside' 'README.md:path-outside' \
            'src/a.txt:path-outside' 'src/a b.cho:path-chars' 'src/a;b.cho:path-chars' 'src//a.cho:path-component' 'src/a.cho/:path-component'; do
    p=${spec%%:*}; want=${spec#*:}
    expect "path $p" "$("$G" path "$p")" "$want"
done
expect "path: empty" "$("$G" path "")" "path-length"
expect "kind bug" "$("$G" kind bug)" "ok test"
expect "kind feature" "$("$G" kind feature)" "ok test"
expect "kind refactor" "$("$G" kind refactor)" "ok free"
expect "kind rename" "$("$G" kind rename)" "ok free"
expect "kind other" "$("$G" kind fix | cut -c1-3)" "bad"

expect "envelope: preamble and fence cut" "$("$G" envelope "$F/reply-fenced.txt")" "$(grep -b '^=== FILE src/a.cho' "$F/reply-fenced.txt" | head -1 | cut -d: -f1) $(( $(wc -c < "$F/reply-fenced.txt") - 1 - 4 ))"
expect "envelope: none" "$("$G" envelope "$F/reply-prose.txt")" "-1 -1"
expect "sections" "$("$G" sections "$F/envelope3.txt" | tr '\t\n' ': ')" "src/a.cho:49 tests/a_test.cho:40 src/new.cho:23 "

while IFS='	' read -r name rc sub; do
    case "$name" in ''|'#'*) continue ;; esac
    ex="$F/$name.existing"; [ -f "$ex" ] || ex=-
    out=$("$G" apply "$ex" "$F/$name.body" "src/x.cho" 2>"$d/apply.err"); r=$?
    expect "apply $name: exit" "$r" "$rc"
    [ -z "$sub" ] || has "apply $name: report" "$(cat "$d/apply.err")" "$sub"
    if [ "$r" = 0 ]; then
        [ -f "$F/$name.want" ] && { printf '%s\n' "$out" | cmp -s - "$F/$name.want" || { echo "FAIL: apply $name: the new file is not $name.want" >&2; diff "$F/$name.want" - <<EOF2 >&2
$out
EOF2
        fail=1; }; }
    else
        [ -z "$out" ] || [ "$ex" = - ] || [ "$out" = "$(cat "$ex")" ] || { echo "FAIL: apply $name: an error must leave the file as it was" >&2; fail=1; }
    fi
done < "$F/apply.txt"

expect "remove: two items" "$("$G" remove "$F/rm.existing" "$F/rm.list" 2>&1)" "$(cat "$F/rm.want")"
"$G" remove "$F/rm.existing" "$F/rm.missing" >/dev/null 2>"$d/rm.err"; expect "remove: a missing item is exit 1" "$?" 1
has "remove: a missing item is a SPLICE_ERROR line" "$(cat "$d/rm.err")" "[SPLICE_ERROR]	-	1:patch: remove fn nothere: the file has no such item"
expect "tests: a new test counts" "$("$G" tests "$F/t.base" "$F/t.new")" 1
expect "tests: nothing new" "$("$G" tests "$F/t.base" "$F/t.base")" 0
expect "tests: a changed test counts, a changed helper does not" "$("$G" tests "$F/t.base" "$F/t.changed")" 1
expect "tests: a new file counts every test in it" "$("$G" tests /dev/null "$F/t.new")" 2

# ---- the driver ---------------------------------------------------------------------------------------------------------------------------
R="$root/tests/repochange"
tree_hash() { (cd "$1" && find . -type f | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -c1-16); }
# newrepo -> prints a fresh copy of the fixture repository (with a .git directory that must stay out of the copy)
newrepo() { r=$(mktemp -d -t cc-repopatch-repo-XXXXXX -p "$d"); cp -r "$R/repo/." "$r/"; mkdir "$r/.git"; echo "ref: refs/heads/main" > "$r/.git/HEAD"; echo "$r"; }
newrc() { x=$(mktemp -d -t cc-repopatch-rc-XXXXXX -p "$d"); : > "$x/log"; echo "$x"; }
req="$d/change.txt"; printf 'Add quarter(x): x divided by 4.\n' > "$req"
# run <repo> <recipes> <workdir> <kind> [more options] -> stdout and stderr of the tool
run() {
    rp=$1; rc=$2; w=$3; k=$4; shift 4
    "$d/cb" --repo "$rp" --change "$req" --checker "$CANCHO" --work "$w" --agent "sh $R/agent.sh $rc $rc/log" --provider stand --model m1 --kind "$k" --agent-seconds 120 --test-seconds 120 "$@" 2>&1
}
verdict() { printf '%s\n' "$1" | grep '^\[CHANGE_VERDICT\]' | cut -f2; }
attempts() { printf '%s\n' "$1" | grep '^\[CHANGE_ATTEMPT\]' | cut -f2,3,4 | tr '\t' ':' | tr '\n' ' ' | sed 's/ $//'; }

QUARTER='=== FILE src/mathx.cho
pub fn quarter(x: int) -> [] int { return x / 4; }
=== FILE tests/mathx_test.cho
pub fn test_quarter() -> [] int { test.assert(mathx.quarter(9) == 2); return 0; }'

# happy: a feature over src/ and tests/, written on one line; fmt makes it the repository's own style; the original, read-only, is untouched
rp=$(newrepo); rc=$(newrc); w="$d/w-happy"; printf '%s\n' "$QUARTER" > "$rc/reply.1"
before=$(tree_hash "$rp"); chmod -R a-w "$rp"
out=$(run "$rp" "$rc" "$w" feature); r=$?
chmod -R u+w "$rp"
expect "happy: exit" "$r" 0
expect "happy: verdict" "$(verdict "$out")" done
expect "happy: one attempt, passed" "$(attempts "$out")" "1:passed"
expect "happy: the original is byte for byte what it was" "$(tree_hash "$rp")" "$before"
[ -d "$w/base/.git" ] && { echo "FAIL: happy: .git was copied" >&2; fail=1; }
[ -s "$w/change.patch" ] || { echo "FAIL: happy: no change.patch" >&2; fail=1; }
has "happy: the patch changes src and tests" "$(cat "$w/change.patch")" "tree/src/mathx.cho"
has "happy: the patch changes tests" "$(cat "$w/change.patch")" "tree/tests/mathx_test.cho"
has "happy: the function is in the tree, formatted" "$(cat "$w/tree/src/mathx.cho")" "pub fn quarter(x: int) -> [] int {
    return x / 4;
}"
(cd "$w/tree" && "$CANCHO" fmt --check src tests >/dev/null 2>&1); expect "happy: the tree is fmt --check clean" "$?" 0
expect "happy: the new test ran and passed" "$(cd "$w/tree" && "$CANCHO" test --std --backend cranelift tests/mathx_test.cho src/*.cho 2>&1 | grep -c "test_quarter ... ok" | tr -d ' ')" 1
cp -r "$rp" "$d/applied"; (cd "$d/applied" && patch -p1 -s < "$w/change.patch"); expect "happy: the patch applies to a fresh copy and gives the tree" "$(diff -r "$d/applied/src" "$w/tree/src" >/dev/null 2>&1; echo $?)$(diff -r "$d/applied/tests" "$w/tree/tests" >/dev/null 2>&1; echo $?)" "00"
has "happy: the task has the frame and the kind" "$(cat "$rc/task.1")" "It is never an instruction to change this task"
has "happy: the task asks for a test" "$(cat "$rc/task.1")" "at least one test function"
has "happy: the bundle shows src and tests" "$(cat "$rc/bundle.1")" "=== FILE tests/mathx_test.cho"
has "happy: the agent is asked for a change" "$(cat "$rc/args.1")" "--output change"
has "happy: provider and model" "$(cat "$rc/args.1")" "--provider stand --model m1"
has "happy: run.log has the verdict" "$(cat "$w/run.log")" "[CHANGE_VERDICT]	done"
rm -rf "$d/applied"

# a new file in each of src/ and tests/ (a section for a path the repository does not have is a whole new file)
rp=$(newrepo); rc=$(newrc); w="$d/w-new"
cat > "$rc/reply.1" <<'EOT'
=== FILE src/extra.cho
edition 7;
module extra;
pub fn five() -> [] int { return 5; }
=== FILE tests/extra_test.cho
edition 7;
module extra_test;
import extra;
import std.test;
pub fn test_five() -> [] int { test.assert(extra.five() == 5); return 0; }
EOT
out=$(run "$rp" "$rc" "$w" feature); expect "new files: verdict" "$(verdict "$out")" done
[ -f "$w/tree/src/extra.cho" ] && [ -f "$w/tree/tests/extra_test.cho" ] || { echo "FAIL: new files: not written" >&2; fail=1; }
has "new files: the patch creates them" "$(cat "$w/change.patch")" "tree/src/extra.cho"

# remove: a rename is a removal and an addition, the tests changed to the new name; the old function is gone
rp=$(newrepo); rc=$(newrc); w="$d/w-rename"
cat > "$rc/reply.1" <<'EOT'
=== FILE src/mathx.cho
remove fn half
pub fn halve(x: int) -> [] int { return x / 2; }
=== FILE tests/mathx_test.cho
pub fn test_half() -> [] int { test.assert(mathx.halve(9) == 4); return 0; }
EOT
out=$(run "$rp" "$rc" "$w" rename); expect "rename: verdict" "$(verdict "$out")" done
hasnt "rename: the old function is gone" "$(cat "$w/tree/src/mathx.cho")" "fn half"
has "rename: the new one is there" "$(cat "$w/tree/src/mathx.cho")" "fn halve"
has "rename: the old one is removed in the patch" "$(cat "$w/change.patch")" "-pub fn half"

# a removal of an item that does not exist: the splice error, the same way as the others; the retry is told
rp=$(newrepo); rc=$(newrc); w="$d/w-missing"
printf '=== FILE src/mathx.cho\nremove fn nothere\n' > "$rc/reply.1"
cp "$rc/reply.1" "$rc/reply.2"; sed -i 's/nothere/half/' "$rc/reply.2"; cat >> "$rc/reply.2" <<'EOT'
pub fn halve(x: int) -> [] int {
    return x / 2;
}
=== FILE tests/mathx_test.cho
pub fn test_half() -> [] int {
    test.assert(mathx.halve(9) == 4);
    return 0;
}
EOT
out=$(run "$rp" "$rc" "$w" rename); expect "missing: verdict" "$(verdict "$out")" done
expect "missing: refused once, then passed" "$(attempts "$out")" "1:refused:rejected 2:passed"
has "missing: the error is a SPLICE_ERROR line" "$out" "[SPLICE_ERROR]	-	1:patch: remove fn nothere: the file has no such item"
has "missing: the retry feedback says so" "$(cat "$rc/feedback.2")" "remove fn nothere"

# a removal of an item the tests still call: the compiler's refusal, not an analyser of ours
rp=$(newrepo); rc=$(newrc); w="$d/w-dangling"
printf '=== FILE src/mathx.cho\nremove fn half\n' > "$rc/reply.1"
cp "$rc/reply.1" "$rc/reply.2"; cat >> "$rc/reply.2" <<'EOT'
=== FILE tests/mathx_test.cho
remove fn test_half
EOT
out=$(run "$rp" "$rc" "$w" refactor); expect "dangling: verdict" "$(verdict "$out")" done
expect "dangling: refused by the tests, then passed" "$(attempts "$out")" "1:refused:tests-failed 2:passed"
has "dangling: the feedback has the compiler's words" "$(cat "$rc/feedback.2")" "tests-failed"
hasnt "dangling: the second tree has no test of half" "$(cat "$w/tree/tests/mathx_test.cho")" "test_half"

# tests: a feature with no test is refused by name and the retry is told; the same reply passes as a refactor
rp=$(newrepo); rc=$(newrc); w="$d/w-notest"
printf '=== FILE src/mathx.cho\npub fn quarter(x: int) -> [] int { return x / 4; }\n' > "$rc/reply.1"; cp "$rc/reply.1" "$rc/reply.2"
out=$(run "$rp" "$rc" "$w" feature --attempts 2); r=$?
expect "no test: stuck, exit 1" "$r$(verdict "$out")" "1stuck"
expect "no test: both attempts refused by name" "$(attempts "$out")" "1:refused:no-test-added 2:refused:no-test-added"
has "no test: the retry feedback names it" "$(cat "$rc/feedback.2")" "no-test-added"
has "no test: and says what to do" "$(cat "$rc/feedback.2")" "add a test that fails without the change"
[ -e "$w/change.patch" ] && { echo "FAIL: no test: a change.patch for a refused change" >&2; fail=1; }
rp=$(newrepo); rc=$(newrc); w="$d/w-notest-bug"; cp "$d/../$(basename "$rc")/reply.1" /dev/null 2>/dev/null
printf '=== FILE src/mathx.cho\npub fn quarter(x: int) -> [] int { return x / 4; }\n' > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" bug --attempts 1); expect "no test: a bug needs one too" "$(attempts "$out")" "1:refused:no-test-added"
rp=$(newrepo); rc=$(newrc); w="$d/w-notest-refactor"; printf '=== FILE src/mathx.cho\npub fn quarter(x: int) -> [] int { return x / 4; }\n' > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" refactor --attempts 1); expect "no test: a refactor does not" "$(verdict "$out")" done
rp=$(newrepo); rc=$(newrc); w="$d/w-notest-rename"; printf '=== FILE src/mathx.cho\npub fn quarter(x: int) -> [] int { return x / 4; }\n' > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" rename --attempts 1); expect "no test: a rename does not" "$(verdict "$out")" done
# a changed test function counts (a bug fix that makes a test stricter)
rp=$(newrepo); rc=$(newrc); w="$d/w-changedtest"
printf '=== FILE tests/mathx_test.cho\npub fn test_double() -> [] int { test.assert(mathx.double(4) == 8); test.assert(mathx.double(0) == 0); return 0; }\n' > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" bug --attempts 1); expect "changed test: counts" "$(verdict "$out")" done

# a test that fails on the code is the gate's refusal
rp=$(newrepo); rc=$(newrc); w="$d/w-failing"
printf '=== FILE tests/mathx_test.cho\npub fn test_double() -> [] int { test.assert(mathx.double(4) == 9); return 0; }\n' > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" bug --attempts 1); expect "failing test: refused" "$(attempts "$out")" "1:refused:tests-failed"

# bounds
bound() { # <name> <tag> <envelope text> [options]
    nm=$1; tg=$2; body=$3; shift 3
    rp=$(newrepo); rc=$(newrc); w="$d/w-b-$nm"; printf '%s\n' "$body" > "$rc/reply.1"
    sentinel="$d/outside-$nm.cho"; rm -f "$sentinel"
    before=$(tree_hash "$rp")
    out=$(run "$rp" "$rc" "$w" refactor --attempts 1 "$@")
    expect "bounds $nm: refused by tag" "$(attempts "$out")" "1:refused:$tg"
    expect "bounds $nm: the original is untouched" "$(tree_hash "$rp")" "$before"
    [ -e "$sentinel" ] && { echo "FAIL: bounds $nm: wrote outside" >&2; fail=1; }
    [ -e "$w/change.patch" ] && { echo "FAIL: bounds $nm: a change.patch" >&2; fail=1; }
    return 0
}
bound absolute path-absolute "=== FILE $d/outside-absolute.cho
edition 7;
fn a() -> [] int { return 1; }"
bound dotdot path-dotdot "=== FILE src/../../outside-dotdot.cho
edition 7;
fn a() -> [] int { return 1; }"
bound git path-git "=== FILE .git/hooks/x.cho
edition 7;
fn a() -> [] int { return 1; }"
bound outside path-outside "=== FILE README.md
hello"
bound outside2 path-outside "=== FILE scripts/x.cho
edition 7;
fn a() -> [] int { return 1; }"
bound duplicate path-duplicate "=== FILE src/mathx.cho
pub fn a() -> [] int { return 1; }
=== FILE src/mathx.cho
pub fn b() -> [] int { return 2; }"
bound toomany too-many-files "=== FILE src/mathx.cho
pub fn a() -> [] int { return 1; }
=== FILE tests/mathx_test.cho
pub fn test_a() -> [] int { return 0; }" --max-files 1
bound toolarge change-too-large "=== FILE src/mathx.cho
pub fn a() -> [] int { return 1; }
// padding padding padding padding padding padding padding padding padding" --max-bytes 40
bound empty envelope-empty "I could not find anything to change."
bound conflict path-conflict "=== FILE src/mathx.cho/inner.cho
edition 7;
fn a() -> [] int { return 1; }"
bound removenew remove-in-new-file "=== FILE src/brand_new.cho
remove fn a"
bound nosyntax remove-syntax "=== FILE src/mathx.cho
remove half"
bound noedition new-file-no-edition "=== FILE src/brand_new.cho
fn a() -> [] int { return 1; }"

# a file past 2000 lines that grew is refused; a change that leaves a file under it is not
rp=$(newrepo); rc=$(newrc); w="$d/w-long"
{ echo '=== FILE src/big.cho'; echo 'edition 7;'; echo 'module big;'; i=0; while [ $i -lt 2100 ]; do echo "// line $i"; i=$((i + 1)); done; echo 'pub fn one() -> [] int { return 1; }'; } > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" refactor --attempts 1 --max-bytes 100000); expect "long: refused" "$(attempts "$out")" "1:refused:file-too-long"

# fmt: a reply the formatter cannot read is refused as fmt-failed, with the formatter's words in the retry
rp=$(newrepo); rc=$(newrc); w="$d/w-fmt"
printf '=== FILE src/mathx.cho\npub fn broken(x: int) -> [] int { return x +; }\n' > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" refactor --attempts 1); expect "fmt: refused" "$(attempts "$out")" "1:refused:fmt-failed"

# the agent: gives up twice (exit 11) and is asked again; cannot be reached (exit 7): provider_error
rp=$(newrepo); rc=$(newrc); w="$d/w-gaveup"; echo 11 > "$rc/exit.1"; echo 11 > "$rc/exit.2"; printf '%s\n' "$QUARTER" > "$rc/reply.3"
out=$(run "$rp" "$rc" "$w" feature); r=$?
expect "gave up: done on the third" "$r$(attempts "$out")" "01:refused:agent-gave-up 2:refused:agent-gave-up 3:passed"
has "gave up: the retry is told" "$(cat "$rc/feedback.2")" "agent-gave-up"
rp=$(newrepo); rc=$(newrc); w="$d/w-away"; echo 7 > "$rc/exit.1"
out=$(run "$rp" "$rc" "$w" feature); r=$?
expect "away: provider_error, exit 4" "$r$(verdict "$out")" "4provider_error"

# usage
usage() { # <name> <repo> <extra args...>
    nm=$1; rp=$2; shift 2; rc=$(newrc); w="$d/w-u-$nm"
    out=$(run "$rp" "$rc" "$w" feature "$@"); r=$?
    expect "usage $nm: exit 2" "$r" 2
    [ -s "$rc/log" ] && { echo "FAIL: usage $nm: the agent was run" >&2; fail=1; }
    [ -e "$w/base" ] && { echo "FAIL: usage $nm: a work directory was made" >&2; fail=1; }
    return 0
}
rp=$(newrepo); ln -s /etc "$rp/src/etc"; usage link "$rp"
rp=$(newrepo); rm -rf "$rp/src"; usage nosrc "$rp"
rp=$(newrepo); rc=$(newrc); out=$(run "$rp" "$rc" "$rp/work" feature); expect "usage work-in-repo: exit 2" "$?" 2
expect "usage work-in-repo: nothing made" "$(ls "$rp" | tr '\n' ' ')" "src tests "
rp=$(newrepo); rc=$(newrc); out=$(run "$rp" "$rc" "$d/w-u-kind" bogus); expect "usage kind: exit 2" "$?" 2
out=$("$d/cb" --repo relative/dir --change "$req" --checker "$CANCHO" --work "$d/w-u-rel" --agent x --provider p --model m 2>&1); expect "usage relative: exit 2" "$?" 2
out=$("$d/cb" --repo "$(newrepo)" --change "$req" --checker "$CANCHO" --work "$d/w-u-noagent" --provider p --model m 2>&1); expect "usage no agent: exit 2" "$?" 2
out=$("$d/cb" --repo "$(newrepo)" --change "$req" --checker "$CANCHO" --work "$d/w-u-opt" --agent x --provider p --model m --bogus 1 2>&1); expect "usage unknown option: exit 2" "$?" 2
: > "$d/empty.txt"; out=$("$d/cb" --repo "$(newrepo)" --change "$d/empty.txt" --checker "$CANCHO" --work "$d/w-u-empty" --agent x --provider p --model m 2>&1); expect "usage empty request: exit 2" "$?" 2
[ -e "$d/w-u-empty" ] && { echo "FAIL: usage empty request: a work directory was made" >&2; fail=1; }

# static: the driver never runs git
code=$(grep -v '^[[:space:]]*//' "$SRC/repochange.cho" "$SRC/change.cho" | grep -E 'git (push|commit|add|checkout|clone|apply|fetch)|"git |/git ' | head -3)
expect "static: no git in the driver" "$code" ""

[ $fail -eq 0 ] && echo "repo.patch gate: ok"
exit $fail
