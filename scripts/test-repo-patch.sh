#!/bin/sh
# The repo.patch gate (docs/repo-patch.md): a change request answered for an existing repository checkout. No model, no network, no key; the checker, the
# formatter and the test runner are the real compiler (CANCHO), the agent a stand-in (tests/repochange/agent.sh) that answers from recipe files.
#
#   pure       src/change.cho and the parts of src/splice.cho it uses, one function at a time (tests/programs/change_gate.cho): the paths that may not be
#              written (absolute, `..`, `.git`, outside src/ and tests/, odd bytes), the kinds, the envelope in a reply, its sections, a section into a file
#              (items added or replaced, a replaced item keeping the comment above it unless the reply brings one, items removed, a removal of an item that is not there, a new file), the test functions a file adds or changes
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
#   selection  a repository over --max-bundle: what the request names and what is one step from it shown in full, the rest as signatures; a change to
#              a function whose body was not shown refused (`item-not-shown`) and shown in the next attempt; --touch; level 1; still too big and a
#              request that names nothing refused before the agent runs; a repository that fits shown whole as before (needs a cancho with `ids --edges`)
#   text       the compiler does not answer `ids --edges` (a checker without it; a repository with an error in it): the selection is made from the
#              text (src/textedges.cho), says so, and is the one the compiler's answer gives; the error is then fixed through the selection
#   project    a repository whose cancho.toml has a [[bin]] or a [[test]] (here with a `main` under src/): the gate is the project's own `cancho build`
#              (`build-failed`) and `cancho test` (`tests-failed`), a project with no [[test]] is `no-tests`, the base probe of a bug runs the project's
#              tests, and a cancho.toml with neither table changes nothing
#   static     the driver never runs git (no `git` word in its code outside comments)
#
#   tests that prove something, the shape of a change: see docs/repo-patch.md (`test-passes-on-base` for a bug, `test-not-exercising` for a feature,
#              `--constraints FILE`: `constraint-keep-names`, `constraint-max-added-items`, `constraint-max-added-lines`, `constraint-only-items`)
#
#   scripts/test-repo-patch.sh --mutants   prove the gate can fail: a copy of src/ with one rule broken must be RED, for every rule above (needs python3)
#
# Needs the real cancho as CANCHO and python3 not at all (sh, tar, diff, patch), except for --mutants. Exit 0: every case held.
set -u

if [ "${1:-}" = "--mutants" ]; then
    work=$(mktemp -d -t cc-repopatch-mut-XXXXXX)
    trap 'rm -rf "$work"' EXIT
    root=$(cd "$(dirname "$0")/.." && pwd)
    python3 - "$root/src" "$work" <<'PY' || exit 1
import sys, os, shutil
src, work = sys.argv[1:3]
M = [
 ("probe-off", "repochange.cho", 'if clean && bytes.equal(kind, "bug") {', 'if false && bytes.equal(kind, "bug") {'),
 ("probe-on-the-fix", "repochange.cho", 'cp = buffer.append(heap, cp, "/base ");', 'cp = buffer.append(heap, cp, "/tree ");'),
 ("passed-never-seen", "change.cho", 'bytes.equal(output[i + 1 + len(name)..i + 8 + len(name)], " ... ok")', 'bytes.equal(output[i + 1 + len(name)..i + 8 + len(name)], " ... xx")'),
 ("exercising-off", "repochange.cho", 'if bytes.equal(kind, "feature") && tests_added > 0 {', 'if false && tests_added > 0 {'),
 ("call-without-paren", "change.cho", "if j < len(text) && int_of(text[j]) == 40 {", "if j < len(text) {"),
 ("call-inside-a-word", "change.cho", "(i == 0 || ident_byte(int_of(text[i - 1])) == false)", "true"),
 ("public-or-not", "change.cho", '&& bytes.equal(ln[f0..f1], "1") {', '&& true {'),
 ("removed-not-seen", "splice.cho", "if kept == false {\n                            out = delta_line", "if false {\n                            out = delta_line"),
 ("constraints-off", "repochange.cho", "    if len(constraints) > 0 {\n        var added_lines = 0;", "    if false {\n        var added_lines = 0;"),
 ("keep-names", "change.cho", 'if bytes.equal(status, "R") && bytes.equal(ln[c0..c1], "fn") {', 'if false {'),
 ("max-added-items", "change.cho", "n_added > max_items {", "n_added > max_items + 1000 {"),
 ("max-added-lines", "change.cho", "added_lines > max_lines {", "false {"),
 ("lines-not-counted", "change.cho", 'return limit_of(heap, ctext, "max-added-lines") >= 0;', 'return limit_of(heap, ctext, "max-added-lines") >= 100000000;'),
 ("only-items", "change.cho", "in_list(only, name) == false {", "false {"),
 ("bad-constraint-accepted", "repochange.cho", "            if bad > 0 {\n                var m", "            if false {\n                var m"),
 ("blind-change-accepted", "repochange.cho", "        if hok {\n            var blind", "        if false {\n            var blind"),
 ("never-widened", "repochange.cho", 'if selected && bytes.find(buffer.bytes(rq2), "\\titem-not-shown\\t") >= 0 {', 'if false {'),
 ("nothing-near", "selection.cho", "d[2 * j + 1] = 2;", "d[2 * j + 1] = 0;"),
 ("no-seed-from-the-request", "selection.cho", "len(name) >= 4 && has_word(request, name)", "false"),
 ("touch-ignored", "selection.cho", "if listed(touch, name) ||", "if false ||"),
 ("every-body-shown", "selection.cho", 'if d[2 * i + 1] > 0 || bytes.equal(text_of(edges, t, node, "kind"), "fn") == false {', "if true {"),
 ("tests-never-shown", "selection.cho", "} else if bytes.starts_with(path, \"tests/\") && test_wanted(edges, t, d, n, path, body) {", "} else if false {"),
 ("level-1-off", "selection.cho", "if level > 0 && wanted == false {", "if false {"),
 ("limit-not-held", "repochange.cho", "} else if len(buffer.bytes(sr)) > most {", "} else if false {"),
 ("text-edges-not-made", "repochange.cho", "let said2 = textedges.edges(heap, buffer.bytes(alr));", "let said2 = buffer.empty(heap, 16);"),
 ("text-said-to-be-the-compiler", "repochange.cho", 'by = "text";', 'by = "compiler";'),
 ("text-refers-to-nothing", "textedges.cho", "if j >= 0 && j != i && seen[j] != i + 1 {", "if false {"),
 ("text-body-not-followed", "textedges.cho", "while open && qe < bb {", "while false {"),
 ("text-imports-not-read", "textedges.cho", "if bytes.equal(t[aa..ab], alias) {", "if false {"),
 ("comment-not-kept", "splice.cho", "if keep && tp[6 * pk + 5] == tp[6 * pk + 1] {", "if false {"),
 ("comment-kept-beside-a-new-one", "splice.cho", "if keep && tp[6 * pk + 5] == tp[6 * pk + 1] {", "if keep {"),
 ("project-not-seen", "repochange.cho", "        if code >= 1 && code <= 3 {\n            tables = code;", "        if false {\n            tables = code;"),
 ("project-build-not-run", "repochange.cho", "    if built && tables % 2 == 1 {\n        let (code, said) = project_run", "    if false {\n        let (code, said) = project_run"),
 ("project-tests-not-run", "repochange.cho", "    if built {\n        let (code, said) = project_run", "    if false {\n        let (code, said) = project_run"),
 ("project-without-tests-accepted", "repochange.cho", "    if tables < 2 {\n        return change.error_line", "    if false {\n        return change.error_line"),
 ("project-probe-file-by-file", "repochange.cho", "                                if project {", "                                if false {"),
]
for name, fn, old, new in M:
    d = os.path.join(work, name)
    shutil.copytree(src, d)
    p = os.path.join(d, fn)
    t = open(p).read()
    if t.count(old) != 1:
        sys.exit("mutant %s: the text to break is in %s %d times, not once" % (name, fn, t.count(old)))
    open(p, "w").write(t.replace(old, new))
open(os.path.join(work, "names"), "w").write("\n".join(m[0] for m in M) + "\n")
PY
    fail=0
    while read -r name; do
        if REPOPATCH_SRC="$work/$name" sh "$0" >/dev/null 2>"$work/$name.err"; then
            echo "FAIL: mutant $name is green" >&2; fail=1
        elif grep -q '^FAIL:' "$work/$name.err"; then
            echo "ok: mutant $name is red"
        else
            echo "FAIL: mutant $name is red for the wrong reason (no case failed: $(head -c 200 "$work/$name.err"))" >&2; fail=1
        fi
    done < "$work/names"
    [ "$fail" = 0 ] && echo "repo.patch mutants: all red"
    exit "$fail"
fi

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

"$CANCHO" build "$root/tests/programs/change_gate.cho" "$SRC/change.cho" "$SRC/splice.cho" --std -o "$d/gate" >/dev/null 2>"$d/build.err" \
    || { cat "$d/build.err" >&2; echo "pure gate did not build" >&2; exit 2; }
"$CANCHO" build "$root/tests/programs/build.cho" "$SRC/build.cho" "$SRC/project.cho" "$SRC/plan.cho" "$SRC/driver.cho" \
    "$SRC/checker.cho" "$SRC/signature.cho" "$SRC/loop_check.cho" "$SRC/snapshot.cho" "$SRC/trail.cho" \
    "$SRC/acceptance.cho" "$SRC/splice.cho" "$SRC/pool.cho" "$SRC/parallel.cho" "$SRC/library.cho" "$SRC/cases.cho" "$SRC/change.cho" "$SRC/repochange.cho" "$SRC/selection.cho" "$SRC/textedges.cho" \
    --std -o "$d/cb" >/dev/null 2>"$d/build2.err" || { cat "$d/build2.err" >&2; echo "gate did not build" >&2; exit 2; }
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

# the shape of a change, from the items of a file against its base (splice.item_delta), the tests it adds (changed_test_items), what the tests call
cat > "$d/dl.base" <<'EOT'
edition 7;

module m;

struct Point { x: int }

pub fn keep() -> [] int {
    return 1;
}

pub fn change() -> [] int {
    return 1;
}

fn gone() -> [] int {
    return 1;
}
EOT
cat > "$d/dl.new" <<'EOT'
edition 7;

module m;

struct Point { x: int }

pub fn keep() -> [] int {
    return 1;
}

pub fn change() -> [] int {
    return 2;
}

pub fn fresh(a: int) -> [] int {
    return a;
}

fn helper() -> [] int {
    let x = 1;
    return x;
}

pub fn test_t() -> [] int {
    return 0;
}
EOT
tab=$(printf '\t')
expect "delta: added, replaced and removed items, kept ones left out" "$("$G" delta "$d/dl.base" "$d/dl.new" src/m.cho | tr '\t' ' ' | tr '\n' ';')" "src/m.cho C fn change 1 3;src/m.cho A fn fresh 1 3;src/m.cho A fn helper 0 4;src/m.cho A fn test_t 1 3;src/m.cho R fn gone 0 3;"
expect "delta: a new file is all additions" "$("$G" delta - "$d/dl.base" src/n.cho | tr '\t' ' ' | tr '\n' ';')" "src/n.cho A type Point 0 1;src/n.cho A fn keep 1 3;src/n.cho A fn change 1 3;src/n.cho A fn gone 0 3;"
expect "delta: nothing changed, nothing said" "$("$G" delta "$d/dl.base" "$d/dl.base" src/m.cho)" ""
"$G" delta "$d/dl.base" "$d/dl.new" src/m.cho > "$d/dl.rec"
expect "public fns: the added and replaced public functions only" "$("$G" publicfns "$d/dl.rec" | tr '\n' ' ')" "change fresh test_t "
printf 'src/a.cho\tA\tfn\tx\t1\t1\ntests/a_test.cho\tA\tfn\ty\t1\t1\nsrc/a.cho\tR\tfn\tz\t1\t1\nsrc/a.cho\tA\ttype\tw\t1\t1\n' > "$d/pf.rec"
expect "public fns: not tests/, not removed, not a type" "$("$G" publicfns "$d/pf.rec" | tr '\n' ' ')" "x "
expect "test items: the names of the tests a file adds" "$("$G" testitems "$F/t.base" "$F/t.new" names | tr '\n' ' ')" "test_two "
txt=$("$G" testitems "$F/t.base" "$F/t.changed" text)
has "test items: the text of a changed test is the item, from its keyword" "$txt" "pub fn test_one() -> [] int {"
has "test items: and has its body" "$txt" "test.assert(true);"
hasnt "test items: and not a changed helper" "$txt" "helper"
expect "test items: a changed test is named" "$("$G" testitems "$F/t.base" "$F/t.changed" names)" "test_one"

printf 'test.assert(m.fresh(2) == 2);\n' > "$d/ex.call"; printf 'fresh\nchange\n' > "$d/ex.names"; : > "$d/ex.none"
expect "exercise: a call of one of the names" "$("$G" exercise "$d/ex.call" "$d/ex.names")" yes
printf 'test.assert(m.keep() == 1); let fresh_one = 1; test_fresh(3); fresher(2); fresh;\n' > "$d/ex.nocall"
expect "exercise: other calls, a longer name, a name that is not called: no" "$("$G" exercise "$d/ex.nocall" "$d/ex.names")" no
printf 'let a = fresh (4);\n' > "$d/ex.space"; expect "exercise: a space before the parenthesis" "$("$G" exercise "$d/ex.space" "$d/ex.names")" yes
expect "exercise: nothing to call is a pass" "$("$G" exercise "$d/ex.nocall" "$d/ex.none")" yes
printf 'running 4 tests\ntest m_test.test_a ... ok\ntest m_test.test_ab ... FAILED\ntest m_test.test_b ... ok\ntest m_test.test_d ... FAILED\n' > "$d/ps.out"
printf 'test_a\ntest_ab\ntest_c\ntest_d\n' > "$d/ps.names"
expect "passed: only the names with an ok line, not a longer name" "$("$G" passed "$d/ps.out" "$d/ps.names" | tr '\n' ' ')" "test_a "
printf 'tests/m_test.cho:3:1: error: `x` is not a function\n' > "$d/ps.err"; expect "passed: a compile error passes none" "$("$G" passed "$d/ps.err" "$d/ps.names")" ""

cons() { printf '%s\n' "$1" > "$d/c.txt"; "$G" constraint "$d/c.txt" | tr '\t' ' '; }
expect "constraints: all four kinds, with comments and blanks" "$(printf '# a comment\n\nkeep-names tests/*\nkeep-names src/diff.cho\nmax-added-items 2\nmax-added-lines 40\nonly-items a,b_2,c\n' > "$d/c.txt"; "$G" constraint "$d/c.txt")" ok
expect "constraints: an empty file is fine" "$(: > "$d/c.txt"; "$G" constraint "$d/c.txt")" ok
expect "constraints: unknown line" "$(cons 'max-lines 3')" "1 unknown constraint (keep-names, max-added-items, max-added-lines, only-items)"
expect "constraints: the line number" "$(printf 'max-added-items 3\n\nbogus\n' > "$d/c.txt"; "$G" constraint "$d/c.txt" | tr '\t' ' ' | cut -c1-9)" "3 unknown"
expect "constraints: a number is a number" "$(cons 'max-added-items many')" "1 max-added-items takes a number"
expect "constraints: a number is given" "$(cons 'max-added-lines')" "1 max-added-lines takes a number"
expect "constraints: a number, twice" "$(printf 'max-added-lines 3\nmax-added-lines 4\n' > "$d/c.txt"; "$G" constraint "$d/c.txt" | tr '\t' ' ')" "2 max-added-lines is given twice"
expect "constraints: only-items twice" "$(printf 'only-items a\nonly-items b\n' > "$d/c.txt"; "$G" constraint "$d/c.txt" | tr '\t' ' ')" "2 only-items is given twice"
expect "constraints: only-items with an empty name" "$(cons 'only-items a,,b')" "1 only-items takes item names separated by commas"
expect "constraints: only-items with a bad name" "$(cons 'only-items a;b')" "1 only-items takes item names separated by commas"
expect "constraints: a glob outside src/ and tests/" "$(cons 'keep-names lib/*')" "1 keep-names takes a path under src/ or tests/, with a * only at its end"
expect "constraints: a * in the middle" "$(cons 'keep-names tests/*_test.cho')" "1 keep-names takes a path under src/ or tests/, with a * only at its end"
expect "constraints: a .. in a glob" "$(cons 'keep-names tests/../x')" "1 keep-names takes a path under src/ or tests/, with a * only at its end"

# the violations: records of a change that renamed a test, added two items and a helper
printf 'src/d.cho\tR\tfn\tedit_count\t1\t5\nsrc/d.cho\tA\tfn\tedit_distance\t1\t5\nsrc/d.cho\tA\tfn\tdiff_lcs\t0\t40\nsrc/d.cho\tC\tfn\tdiff_stat\t1\t9\ntests/d_test.cho\tR\tfn\ttest_edit_count_1\t1\t3\ntests/d_test.cho\tA\tfn\ttest_edit_distance_1\t1\t3\ntests/d_test.cho\tC\tfn\ttest_other\t1\t3\ntests/d_test.cho\tR\tfn\thelper_x\t0\t3\n' > "$d/vi.rec"
viol() { printf '%s\n' "$1" > "$d/c.txt"; "$G" violate "$d/c.txt" "$d/vi.rec" "${2:-0}" | cut -f2,4 | tr '\t\n' ' :' | sed 's/:$//'; }
expect "violations: keep-names tests/* names the removed tests and helpers" "$(viol 'keep-names tests/*')" "constraint-keep-names these functions were removed or renamed, and the request keeps their names: test_edit_count_1, helper_x"
expect "violations: keep-names of a src file: its removed function" "$(viol 'keep-names src/d.cho')" "constraint-keep-names these functions were removed or renamed, and the request keeps their names: edit_count"
expect "violations: keep-names of another file: nothing" "$(viol 'keep-names src/other.cho')" ""
expect "violations: changing a test is not removing it" "$(viol 'keep-names tests/d_test.cho' | grep -c test_other)" 0
expect "violations: max-added-items counts the additions in src/ only" "$(viol 'max-added-items 1')" "constraint-max-added-items the change adds 2 items to src/ (edit_distance, diff_lcs); at most 1"
expect "violations: max-added-items met" "$(viol 'max-added-items 2')" ""
expect "violations: max-added-items 0" "$(viol 'max-added-items 0' | cut -d' ' -f1)" "constraint-max-added-items"
expect "violations: max-added-lines" "$(viol 'max-added-lines 10' 41)" "constraint-max-added-lines the change adds 41 lines to src/; at most 10"
expect "violations: max-added-lines met exactly" "$(viol 'max-added-lines 41' 41)" ""
expect "violations: only-items names what is outside the list, in src/ only" "$(viol 'only-items edit_distance,diff_stat')" "constraint-only-items the change touches items of src/ the request does not allow: edit_count, diff_lcs"
expect "violations: only-items met" "$(viol 'only-items edit_count,edit_distance,diff_lcs,diff_stat')" ""
expect "violations: several at once, in a fixed order" "$(printf 'keep-names src/d.cho\nmax-added-items 1\nmax-added-lines 3\nonly-items diff_stat\n' > "$d/c.txt"; "$G" violate "$d/c.txt" "$d/vi.rec" 41 | cut -f2 | tr '\n' ' ')" "constraint-keep-names constraint-max-added-items constraint-max-added-lines constraint-only-items "

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
expect "happy: the new test ran and passed" "$(cd "$w/tree" && "$CANCHO" test --std tests/mathx_test.cho src/*.cho 2>&1 | grep -c "test_quarter ... ok" | tr -d ' ')" 1
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
cp "$rc/reply.1" "$rc/reply.2"; sed -i.bak 's/nothere/half/' "$rc/reply.2"; rm -f "$rc/reply.2.bak"; cat >> "$rc/reply.2" <<'EOT'
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
# a changed test function counts (a feature that makes a test stricter and calls the new function in it)
rp=$(newrepo); rc=$(newrc); w="$d/w-changedtest"
printf '=== FILE src/mathx.cho\npub fn quarter(x: int) -> [] int { return x / 4; }\n=== FILE tests/mathx_test.cho\npub fn test_double() -> [] int { test.assert(mathx.double(4) == 8); test.assert(mathx.quarter(8) == 2); return 0; }\n' > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" feature --attempts 1); expect "changed test: counts" "$(verdict "$out")" done

# a test that fails on the code is the gate's refusal
rp=$(newrepo); rc=$(newrc); w="$d/w-failing"
printf '=== FILE tests/mathx_test.cho\npub fn test_double() -> [] int { test.assert(mathx.double(4) == 9); return 0; }\n' > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" bug --attempts 1); expect "failing test: refused" "$(attempts "$out")" "1:refused:tests-failed"

# a bug fix: the tests it adds or changes must FAIL on the base (the code as it was), pass on the fix. The base here has the bug `half` = x / 3
newbug() { r=$(newrepo); sed -i.bak 's|return x / 2;|return x / 3;|' "$r/src/mathx.cho"; rm -f "$r/src/mathx.cho.bak"; echo "$r"; }
FIX='=== FILE src/mathx.cho
pub fn half(x: int) -> [] int { return x / 2; }'
rp=$(newbug); rc=$(newrc); w="$d/w-bug-ok"
printf '%s\n=== FILE tests/mathx_test.cho\npub fn test_half_ten() -> [] int { test.assert(mathx.half(10) == 5); return 0; }\n' "$FIX" > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" bug --attempts 1); expect "bug: a test that fails on the base and passes on the fix: done" "$(attempts "$out")" "1:passed"
expect "bug: the base is not touched by the probe" "$(grep -c 'x / 3' "$w/base/src/mathx.cho")" 1
expect "bug: the fix is in the tree" "$(grep -c 'x / 2' "$w/tree/src/mathx.cho")" 1
rp=$(newbug); rc=$(newrc); w="$d/w-bug-pass"
printf '%s\n=== FILE tests/mathx_test.cho\npub fn test_half_zero() -> [] int { test.assert(mathx.half(0) == 0); return 0; }\n' "$FIX" > "$rc/reply.1"
printf '%s\n=== FILE tests/mathx_test.cho\npub fn test_half_ten() -> [] int { test.assert(mathx.half(10) == 5); return 0; }\n' "$FIX" > "$rc/reply.2"
out=$(run "$rp" "$rc" "$w" bug); expect "bug: a test that passes on the base is refused by name, the retry passes" "$(attempts "$out")" "1:refused:test-passes-on-base 2:passed"
has "bug: the refusal names the test" "$out" "test_half_zero"
has "bug: the feedback names the tag, the test and what to do" "$(cat "$rc/feedback.2")" "test-passes-on-base"
has "bug: the feedback names the test" "$(cat "$rc/feedback.2")" "test_half_zero"
has "bug: the feedback says what to do" "$(cat "$rc/feedback.2")" "must fail without the fix"
rp=$(newbug); rc=$(newrc); w="$d/w-bug-mixed"
printf '%s\n=== FILE tests/mathx_test.cho\npub fn test_half_zero() -> [] int { test.assert(mathx.half(0) == 0); return 0; }\npub fn test_half_ten() -> [] int { test.assert(mathx.half(10) == 5); return 0; }\n' "$FIX" > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" bug --attempts 1); expect "bug: one test that fails on the base is not enough: every added test must" "$(attempts "$out")" "1:refused:test-passes-on-base"
has "bug: the one that passes is named" "$out" "test_half_zero"
hasnt "bug: the one that fails on the base is not" "$(grep CHANGE_ERROR "$w/run.log")" "test_half_ten"
rp=$(newbug); rc=$(newrc); w="$d/w-bug-nocompile"
cat > "$rc/reply.1" <<'EOT'
=== FILE src/mathx.cho
pub fn half(x: int) -> [] int { return x / 2; }
pub fn tenth(x: int) -> [] int { return x / 10; }
=== FILE tests/mathx_test.cho
pub fn test_tenth() -> [] int { test.assert(mathx.tenth(30) == 3); return 0; }
EOT
out=$(run "$rp" "$rc" "$w" bug --attempts 1); expect "bug: a test that does not compile on the base fails there: done" "$(attempts "$out")" "1:passed"
rp=$(newbug); rc=$(newrc); w="$d/w-bug-nofix"
printf '=== FILE tests/mathx_test.cho\npub fn test_half_ten() -> [] int { test.assert(mathx.half(10) == 5); return 0; }\n' > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" bug --attempts 1); expect "bug: a test and no fix is the tests' refusal, not the base probe's" "$(attempts "$out")" "1:refused:tests-failed"
# a feature is not run against the base
rp=$(newrepo); rc=$(newrc); w="$d/w-feature-nobase"; printf '%s\n' "$QUARTER" > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" feature --attempts 1); expect "feature: no base probe" "$(attempts "$out")" "1:passed"
[ -e "$w/probe" ] && { echo "FAIL: feature: a base probe was run" >&2; fail=1; }

# a feature: the tests it adds must call what it adds
rp=$(newrepo); rc=$(newrc); w="$d/w-notexercising"
printf '=== FILE src/mathx.cho\npub fn quarter(x: int) -> [] int { return x / 4; }\n=== FILE tests/mathx_test.cho\npub fn test_double_again() -> [] int { test.assert(mathx.double(5) == 10); return 0; }\n' > "$rc/reply.1"
printf '%s\n' "$QUARTER" > "$rc/reply.2"
out=$(run "$rp" "$rc" "$w" feature); expect "exercising: a test that does not call the new function is refused by name, the retry passes" "$(attempts "$out")" "1:refused:test-not-exercising 2:passed"
has "exercising: the feedback names the tag and the function" "$(cat "$rc/feedback.2")" "test-not-exercising"
has "exercising: and the function" "$(cat "$rc/feedback.2")" "quarter"
rp=$(newrepo); rc=$(newrc); w="$d/w-exercising-replaced"
printf '=== FILE src/mathx.cho\npub fn double(x: int) -> [] int { return x + x; }\n=== FILE tests/mathx_test.cho\npub fn test_double_seven() -> [] int { test.assert(mathx.double(7) == 14); return 0; }\n' > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" feature --attempts 1); expect "exercising: a replaced public function counts as the thing to call" "$(attempts "$out")" "1:passed"
rp=$(newrepo); rc=$(newrc); w="$d/w-exercising-replaced-no"
printf '=== FILE src/mathx.cho\npub fn double(x: int) -> [] int { return x + x; }\n=== FILE tests/mathx_test.cho\npub fn test_half_seven() -> [] int { test.assert(mathx.half(14) == 7); return 0; }\n' > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" feature --attempts 1); expect "exercising: a test of another function does not" "$(attempts "$out")" "1:refused:test-not-exercising"
rp=$(newrepo); rc=$(newrc); w="$d/w-exercising-private"
printf '=== FILE src/mathx.cho\nfn secret(x: int) -> [] int { return x; }\n=== FILE tests/mathx_test.cho\npub fn test_half_seven() -> [] int { test.assert(mathx.half(14) == 7); return 0; }\n' > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" feature --attempts 1); expect "exercising: a change that adds no public function has nothing to call" "$(attempts "$out")" "1:passed"
rp=$(newrepo); rc=$(newrc); w="$d/w-exercising-bug"
printf '=== FILE src/mathx.cho\npub fn quarter(x: int) -> [] int { return x / 4; }\n=== FILE tests/mathx_test.cho\npub fn test_double_again() -> [] int { test.assert(mathx.double(5) == 10); return 0; }\n' > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" refactor --attempts 1); expect "exercising: not asked of a refactor" "$(attempts "$out")" "1:passed"

# constraints on the shape of a change (--constraints FILE)
CF="$d/constraints.txt"
# a rename of the test functions against keep-names tests/*; the retry keeps them
rp=$(newrepo); rc=$(newrc); w="$d/w-keep"
printf '# keep the tests as they are\n\nkeep-names tests/*\n' > "$CF"
cat > "$rc/reply.1" <<'EOT'
=== FILE src/mathx.cho
remove fn half
pub fn halve(x: int) -> [] int { return x / 2; }
=== FILE tests/mathx_test.cho
remove fn test_half
pub fn test_halve() -> [] int { test.assert(mathx.halve(9) == 4); return 0; }
EOT
cp "$rc/reply.1" "$rc/reply.3"
cat > "$rc/reply.2" <<'EOT'
=== FILE src/mathx.cho
remove fn half
pub fn halve(x: int) -> [] int { return x / 2; }
=== FILE tests/mathx_test.cho
pub fn test_half() -> [] int { test.assert(mathx.halve(9) == 4); return 0; }
EOT
out=$(run "$rp" "$rc" "$w" rename --constraints "$CF"); expect "keep-names: a renamed test is refused by name, the retry that keeps it passes" "$(attempts "$out")" "1:refused:constraint-keep-names 2:passed"
has "keep-names: the feedback names the tag and the test" "$(cat "$rc/feedback.2")" "constraint-keep-names"
has "keep-names: the test" "$(cat "$rc/feedback.2")" "test_half"
has "keep-names: the task shows the constraint to the model" "$(cat "$rc/task.1")" "keep-names tests/*"
rp=$(newrepo); rc=$(newrc); w="$d/w-keep-none"; printf '=== FILE src/mathx.cho\npub fn quarter(x: int) -> [] int { return x / 4; }\n' > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" refactor --attempts 1); hasnt "no constraints: the task has none" "$(cat "$rc/task.1")" "constraints on the shape"
# max-added-items: two new items against a limit of one, then one
rp=$(newrepo); rc=$(newrc); w="$d/w-items"
printf 'max-added-items 1\n' > "$CF"
printf '=== FILE src/mathx.cho\npub fn quarter(x: int) -> [] int { return x / 4; }\nfn helper(x: int) -> [] int { return x; }\n' > "$rc/reply.1"
printf '=== FILE src/mathx.cho\npub fn quarter(x: int) -> [] int { return x / 4; }\n' > "$rc/reply.2"
out=$(run "$rp" "$rc" "$w" refactor --constraints "$CF"); expect "max-added-items: two items against one is refused, one passes" "$(attempts "$out")" "1:refused:constraint-max-added-items 2:passed"
has "max-added-items: the feedback names the items" "$(cat "$rc/feedback.2")" "quarter, helper"
rp=$(newrepo); rc=$(newrc); w="$d/w-items-tests"
printf '=== FILE src/mathx.cho\npub fn quarter(x: int) -> [] int { return x / 4; }\n=== FILE tests/mathx_test.cho\npub fn test_quarter() -> [] int { test.assert(mathx.quarter(8) == 2); return 0; }\npub fn test_quarter2() -> [] int { test.assert(mathx.quarter(12) == 3); return 0; }\n' > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" feature --attempts 1 --constraints "$CF"); expect "max-added-items: the tests added do not count against it" "$(attempts "$out")" "1:passed"
# max-added-lines
rp=$(newrepo); rc=$(newrc); w="$d/w-lines"
printf 'max-added-lines 4\n' > "$CF"
cat > "$rc/reply.1" <<'EOT'
=== FILE src/mathx.cho
pub fn quarter(x: int) -> [] int {
    let a = x / 2;
    let b = a / 2;
    let c = b;
    return c;
}
EOT
printf '=== FILE src/mathx.cho\npub fn quarter(x: int) -> [] int { return x / 4; }\n' > "$rc/reply.2"
out=$(run "$rp" "$rc" "$w" refactor --constraints "$CF"); expect "max-added-lines: seven added lines against four is refused, a short one passes" "$(attempts "$out")" "1:refused:constraint-max-added-lines 2:passed"
has "max-added-lines: the feedback has the counts" "$(cat "$rc/feedback.2")" "adds 7 lines to src/; at most 4"
# only-items
rp=$(newrepo); rc=$(newrc); w="$d/w-only"
printf 'only-items half\n' > "$CF"
printf '=== FILE src/mathx.cho\npub fn double(x: int) -> [] int { return x + x; }\n' > "$rc/reply.1"
printf '=== FILE src/mathx.cho\npub fn half(x: int) -> [] int { return x / 2 + 0; }\n=== FILE tests/mathx_test.cho\npub fn test_half() -> [] int { test.assert(mathx.half(9) == 4); return 0; }\n' > "$rc/reply.2"
out=$(run "$rp" "$rc" "$w" refactor --constraints "$CF"); expect "only-items: a change to another item is refused, a change to the item passes (its tests may change)" "$(attempts "$out")" "1:refused:constraint-only-items 2:passed"
has "only-items: the feedback names the item" "$(cat "$rc/feedback.2")" "double"
# the constraints are checked with the other refusals, all reported together
rp=$(newrepo); rc=$(newrc); w="$d/w-together"
printf 'only-items half\nmax-added-items 0\n' > "$CF"
printf '=== FILE src/mathx.cho\npub fn quarter(x: int) -> [] int { return x / 4; }\n' > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" feature --attempts 1 --constraints "$CF"); expect "constraints: with no-test-added, in one report" "$(attempts "$out")" "1:refused:no-test-added,constraint-max-added-items,constraint-only-items"

# constraints: a line that is not one, a file that is not there, a relative path: usage errors, nothing run
cusage() { # <name> <file text>
    nm=$1; printf '%s\n' "$2" > "$CF"; rp=$(newrepo); rc=$(newrc); w="$d/w-cu-$nm"
    out=$(run "$rp" "$rc" "$w" feature --constraints "$CF"); r=$?
    expect "constraints usage $nm: exit 2" "$r" 2
    has "constraints usage $nm: the line is named" "$out" "--constraints line $3"
    [ -s "$rc/log" ] && { echo "FAIL: constraints usage $nm: the agent was run" >&2; fail=1; }
    [ -e "$w/base" ] && { echo "FAIL: constraints usage $nm: a work directory was made" >&2; fail=1; }
    return 0
}
cusage unknown 'max-added-items 3
frobnicate 2' 2
cusage number 'max-added-lines lots' 1
cusage glob 'keep-names lib/*' 1
cusage twice 'only-items a
only-items b' 2
rp=$(newrepo); rc=$(newrc); out=$(run "$rp" "$rc" "$d/w-cu-missing" feature --constraints "$d/no-such-file.txt"); expect "constraints usage: a file that is not there: exit 2" "$?" 2
rp=$(newrepo); rc=$(newrc); out=$(run "$rp" "$rc" "$d/w-cu-rel" feature --constraints relative.txt); expect "constraints usage: a relative path: exit 2" "$?" 2

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

# ---- a selection: a repository too big to be shown whole (docs/repo-patch.md, "A selection"; src/selection.cho) ------------------------------------
# The fixture with more in it (src/shapes.cho calls mathx.double; src/other.cho is 24 functions nothing here is about), and --max-bundle set under its size.
bigrepo() {
    r=$(newrepo)
cat > "$r/src/shapes.cho" <<'EOT'
edition 7;

module shapes;

import mathx;

// The area of a square, twice.
pub fn area(side: int) -> [] int {
    return mathx.double(side * side);
}

pub fn perimeter(side: int) -> [] int {
    let four = 4;
    return side * four;
}
EOT
cat > "$r/tests/shapes_test.cho" <<'EOT'
edition 7;

module shapes_test;

import shapes;
import std.test;

pub fn test_area() -> [] int {
    test.assert(shapes.area(3) == 18);
    return 0;
}
EOT
{ printf 'edition 7;\n\nmodule other;\n'; n=0; while [ $n -lt 24 ]; do v=pub; [ $((n % 2)) = 0 ] || v=; printf '\n%sfn noise_%s(x: int) -> [] int {\n    let a = x + %s;\n    let b = a * 3;\n    let c = b - a;\n    return c + %s;\n}\n' "${v:+pub }" "$n" "$n" "$n"; n=$((n + 1)); done; } > "$r/src/other.cho"
cat > "$r/tests/other_test.cho" <<'EOT'
edition 7;

module other_test;

import other;
import std.test;

pub fn test_noise() -> [] int {
    test.assert(other.noise_0(1) == 2);
    return 0;
}
EOT
    echo "$r"
}
keep_req=$req
req="$d/change-double.txt"; printf 'Make double add the number to itself instead of multiplying.\n' > "$req"
DOUBLE='=== FILE src/mathx.cho
pub fn double(x: int) -> [] int { return x + x; }'
if "$CANCHO" ids --std --edges "$R/repo/src/mathx.cho" >/dev/null 2>&1; then
    # the request names `double`: it and what refers to it (shapes.area) are shown in full, with their tests; of the rest, the signatures
    rp=$(bigrepo); rc=$(newrc); w="$d/w-sel"; printf '%s\n' "$DOUBLE" > "$rc/reply.1"
    out=$(run "$rp" "$rc" "$w" refactor --max-bundle 3500); expect "selection: exit" "$?" 0
    expect "selection: verdict" "$(verdict "$out")" done
    has "selection: the run says what it selected (one seed, level 0)" "$out" "[CHANGE_SELECTION]	1	$(wc -c < "$w/bundle.src" | tr -d ' ')	0	compiler"
    [ "$(wc -c < "$w/bundle.all")" -gt 3500 ] && [ "$(wc -c < "$w/bundle.src")" -le 3500 ] || { echo "FAIL: selection: the whole is not over the limit, or the selection is" >&2; fail=1; }
    b=$(cat "$rc/bundle.1")
    has "selection: the seed is shown in full" "$b" "pub fn double(x: int) -> [] int {
    return x * 2;
}"
    has "selection: what refers to the seed is shown in full" "$b" "return mathx.double(side * side);"
    has "selection: another function is its signature" "$b" "pub fn half(x: int) -> [] int {
    // body not shown: 3 lines
}"
    hasnt "selection: and not its body" "$b" "return x / 2;"
    hasnt "selection: a function nothing is about is not shown" "$b" "let b = a * 3;"
    has "selection: a private function is still named" "$b" "fn noise_1(x: int) -> [] int {"
    has "selection: comments and imports stay" "$b" "// The area of a square, twice."
    has "selection: the tests of the seed's file are shown" "$b" "test.assert(mathx.half(9) == 4);"
    has "selection: the tests of a near file are shown" "$b" "test.assert(shapes.area(3) == 18);"
    has "selection: another test file is outlined" "$b" "=== FILE tests/other_test.cho
// NOT SHOWN: only the first line of each function of this file is below."
    hasnt "selection: and its bodies are not shown" "$b" "other.noise_0(1)"
    expect "selection: the hidden functions are listed" "$(grep -c . "$w/bundle.hidden" | tr -d ' ')" 28
    has "selection: the change is in the tree" "$(cat "$w/tree/src/mathx.cho")" "return x + x;"

    # a change to a function whose body was not shown is refused, and the next attempt is shown it
    rp=$(bigrepo); rc=$(newrc); w="$d/w-sel-blind"
    printf '=== FILE src/mathx.cho\npub fn half(x: int) -> [] int { return (x - x %% 2) / 2; }\n' > "$rc/reply.1"; cp "$rc/reply.1" "$rc/reply.2"
    out=$(run "$rp" "$rc" "$w" refactor --max-bundle 3500)
    expect "selection blind: refused, then passed" "$(attempts "$out")" "1:refused:item-not-shown 2:passed"
    has "selection blind: the feedback names the function" "$(cat "$rc/feedback.2")" "[CHANGE_ERROR]	item-not-shown	src/mathx.cho	half: the body of this function was not shown"
    hasnt "selection blind: the first bundle did not show it" "$(cat "$rc/bundle.1")" "return x / 2;"
    has "selection blind: the second one does" "$(cat "$rc/bundle.2")" "return x / 2;"
    expect "selection blind: the run says both selections" "$(printf '%s\n' "$out" | grep -c '^\[CHANGE_SELECTION\]' | tr -d ' ')" 2

    # --touch names what to show when the request names nothing
    printf 'The lower bound wins when the bounds cross.\n' > "$d/change-vague.txt"; req="$d/change-vague.txt"
    rp=$(bigrepo); rc=$(newrc); w="$d/w-sel-empty"; printf '%s\n' "$DOUBLE" > "$rc/reply.1"
    out=$(run "$rp" "$rc" "$w" refactor --max-bundle 3500); expect "selection empty: exit 2" "$?" 2
    has "selection empty: the tag" "$out" "[CHANGE_ERROR]	selection-empty	-	"
    expect "selection empty: the agent was not run" "$(wc -l < "$rc/log" | tr -d ' ')" 0
    rp=$(bigrepo); rc=$(newrc); w="$d/w-sel-touch"
    printf '=== FILE src/mathx.cho\npub fn clamp(x: int, lo: int, hi: int) -> [] int { if x < lo { return lo; } if x > hi { return hi; } return x + 0; }\n' > "$rc/reply.1"
    out=$(run "$rp" "$rc" "$w" refactor --max-bundle 3500 --touch clamp); expect "selection touch: verdict" "$(verdict "$out")" done
    has "selection touch: the named function is shown" "$(cat "$rc/bundle.1")" "    if x > hi {"
    req="$d/change-double.txt"

    # level 1: when the signatures of everything are still too much, a file nothing is about is its public signatures
    rp=$(bigrepo); rc=$(newrc); w="$d/w-sel-l1"; printf '%s\n' "$DOUBLE" > "$rc/reply.1"
    out=$(run "$rp" "$rc" "$w" refactor --max-bundle 2500); expect "selection level 1: verdict" "$(verdict "$out")" done
    has "selection level 1: said" "$out" "[CHANGE_SELECTION]	1	$(wc -c < "$w/bundle.src" | tr -d ' ')	1"
    b=$(cat "$rc/bundle.1")
    has "selection level 1: public signatures only" "$b" "// NOT SHOWN: only the signatures of the public declarations of this file are below.
pub fn noise_0(x: int) -> [] int
pub fn noise_2(x: int) -> [] int"
    hasnt "selection level 1: no private one" "$b" "fn noise_1("
    has "selection level 1: the seed's file is as at level 0" "$b" "    // body not shown: 9 lines"

    # still too much: refused before the agent is run
    rp=$(bigrepo); rc=$(newrc); w="$d/w-sel-big"; printf '%s\n' "$DOUBLE" > "$rc/reply.1"
    out=$(run "$rp" "$rc" "$w" refactor --max-bundle 600); expect "selection too big: exit 2" "$?" 2
    has "selection too big: the tag" "$out" "[CHANGE_ERROR]	bundle-too-large	-	"
    expect "selection too big: the agent was not run" "$(wc -l < "$rc/log" | tr -d ' ')" 0

    # a repository that fits is shown whole, as before: no selection, nothing hidden
    rp=$(bigrepo); rc=$(newrc); w="$d/w-sel-whole"; printf '%s\n' "$DOUBLE" > "$rc/reply.1"
    out=$(run "$rp" "$rc" "$w" refactor); expect "whole: verdict" "$(verdict "$out")" done
    hasnt "whole: no selection" "$out" "[CHANGE_SELECTION]"
    has "whole: every body is shown" "$(cat "$rc/bundle.1")" "let b = a * 3;"
    [ -e "$w/bundle.hidden" ] && { echo "FAIL: whole: a list of hidden functions was written" >&2; fail=1; }
else
    echo "note: this cancho has no \`ids --edges\`: the selection cases by the compiler are not run, only the ones by the text" >&2
fi

# ---- the compiler does not answer: the selection from the text (docs/repo-patch.md, "When the compiler does not answer"; src/textedges.cho) -------
# a checker whose `ids` fails, and is the real one for everything else
printf '#!/bin/sh\ncase "$1" in ids) echo "no ids here" >&2; exit 1 ;; esac\nexec "%s" "$@"\n' "$CANCHO" > "$d/noids.sh"; chmod +x "$d/noids.sh"
rp=$(bigrepo); rc=$(newrc); w="$d/w-text"; printf '%s\n' "$DOUBLE" > "$rc/reply.1"
out=$(CANCHO="$d/noids.sh"; run "$rp" "$rc" "$w" refactor --max-bundle 3500); expect "text: exit" "$?" 0
expect "text: verdict" "$(verdict "$out")" done
has "text: the run says the selection is from the text" "$out" "[CHANGE_SELECTION]	1	$(wc -c < "$w/bundle.src" | tr -d ' ')	0	text"
hasnt "text: no refusal" "$out" "selection-failed"
b=$(cat "$rc/bundle.1")
has "text: the seed is shown in full" "$b" "    return x * 2;"
has "text: what refers to the seed through an import is shown in full" "$b" "return mathx.double(side * side);"
hasnt "text: another function is not" "$b" "return x / 2;"
has "text: and says how long it is" "$b" "    // body not shown: "
hasnt "text: a function nothing is about is not shown" "$b" "let b = a * 3;"
expect "text: the hidden functions are listed" "$(grep -c . "$w/bundle.hidden" | tr -d ' ')" 28
if [ -f "$d/w-sel/bundle.src" ]; then
    cmp -s "$d/w-sel/bundle.src" "$w/bundle.src" || { echo "FAIL: text: the selection is not the one the compiler's answer gives" >&2; fail=1; }
    [ "$(sort "$d/w-sel/bundle.hidden")" = "$(sort "$w/bundle.hidden")" ] || { echo "FAIL: text: the hidden functions are not the compiler's" >&2; fail=1; }
fi
# a function that was not shown is still refused, and shown next
rp=$(bigrepo); rc=$(newrc); w="$d/w-text-blind"
printf '%s\n' '=== FILE src/mathx.cho' 'pub fn half(x: int) -> [] int { return x / 2 + 0; }' > "$rc/reply.1"; printf '%s\n' "$DOUBLE" > "$rc/reply.2"
out=$(CANCHO="$d/noids.sh"; run "$rp" "$rc" "$w" refactor --max-bundle 3500)
expect "text blind: refused, then passed" "$(attempts "$out")" "1:refused:item-not-shown 2:passed"
# a repository with an error in it: the real compiler does not answer for it, the text does, and the change that mends it passes
rp=$(bigrepo); rc=$(newrc); w="$d/w-text-broken"
printf '\npub fn broken(x: int) -> [] int {\n    return nothing_here(x);\n}\n' >> "$rp/src/other.cho"
printf 'Make double add the number to itself, and make broken return its argument.\n' > "$d/change-broken.txt"
printf '%s\n' "$DOUBLE" '=== FILE src/other.cho' 'pub fn broken(x: int) -> [] int { return x; }' > "$rc/reply.1"
out=$(req="$d/change-broken.txt"; run "$rp" "$rc" "$w" refactor --max-bundle 3500); expect "text, broken repository: exit" "$?" 0
expect "text, broken repository: verdict" "$(verdict "$out")" done
has "text, broken repository: two seeds, from the text" "$out" "[CHANGE_SELECTION]	2	$(wc -c < "$w/bundle.src" | tr -d ' ')	0	text"
has "text, broken repository: the function with the error is shown" "$(cat "$rc/bundle.1")" "    return nothing_here(x);"
has "text, broken repository: what the compiler said is kept" "$(cat "$w/edges.err")" "error"
has "text, broken repository: mended in the tree" "$(cat "$w/tree/src/other.cho")" "    return x;"
rp=$(bigrepo); rc=$(newrc); out=$(run "$rp" "$rc" "$d/w-u-touch" refactor --touch src/mathx.cho); expect "usage --touch with a path: exit 2" "$?" 2
rp=$(bigrepo); rc=$(newrc); out=$(run "$rp" "$rc" "$d/w-u-maxb" refactor --max-bundle 0); expect "usage --max-bundle 0: exit 2" "$?" 2
req=$keep_req

# ---- a project: a repository with a cancho.toml that has [[bin]] or [[test]] (docs/repo-patch.md, "A project") ---------------------------------
# src/ holds a `main` (which `cancho test tests/X_test.cho src/*.cho` refuses), so only the project's own `cancho build` and `cancho test` can check it.
newproject() {
    r=$(newrepo)
cat > "$r/src/main.cho" <<'EOT'
edition 7;

import mathx;

fn main(world: World) -> [] int {
    release(world);
    return mathx.triple(1) - 3;
}
EOT
cat >> "$r/src/mathx.cho" <<'EOT'

// Three times the number: only `main` calls it.
pub fn triple(x: int) -> [] int {
    return x * 3;
}
EOT
cat > "$r/cancho.toml" <<'EOT'
[package]
name = "mathproj"

[[bin]]
name = "mathproj"
sources = ["src/mathx.cho", "src/main.cho"]
std = true
out = "build/mathproj"

[[test]]
name = "mathx"
sources = ["src/mathx.cho", "tests/mathx_test.cho"]
std = true
EOT
    echo "$r"
}
PLUS='=== FILE src/mathx.cho
pub fn double(x: int) -> [] int { return x + x; }'
rp=$(newproject); rc=$(newrc); w="$d/w-proj-ok"; printf '%s\n' "$PLUS" > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" refactor --attempts 1); expect "project: a main in src/ and the project's own tests: done" "$(attempts "$out")" "1:passed"
[ -x "$w/check/build/mathproj" ] || { echo "FAIL: project: cancho build did not run on a copy of the tree" >&2; fail=1; }
[ -e "$w/tree/build" ] && { echo "FAIL: project: the build wrote into the tree" >&2; fail=1; }
hasnt "project: what the build wrote is not in the patch" "$(cat "$w/change.patch")" "build/mathproj"
rp=$(newproject); rc=$(newrc); w="$d/w-proj-build"
printf '=== FILE src/mathx.cho\nremove fn triple\n' > "$rc/reply.1"; printf '%s\n' "$PLUS" > "$rc/reply.2"
out=$(run "$rp" "$rc" "$w" refactor); expect "project: a change the tests pass and the program does not build with is build-failed, the retry passes" "$(attempts "$out")" "1:refused:build-failed 2:passed"
has "project: the feedback has the tag" "$(cat "$rc/feedback.2")" "build-failed"
rp=$(newproject); rc=$(newrc); w="$d/w-proj-tests"
printf '=== FILE src/mathx.cho\npub fn double(x: int) -> [] int { return x + 1; }\n' > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" refactor --attempts 1); expect "project: a failing [[test]] set is tests-failed" "$(attempts "$out")" "1:refused:tests-failed"
has "project: the refusal is the project's, not a test file's" "$(grep CHANGE_ERROR "$w/run.log")" "tests-failed	cancho.toml"
rp=$(newproject); rc=$(newrc); w="$d/w-proj-notests"; printf '%s\n' "$PLUS" > "$rc/reply.1"
sed -i.bak '/^\[\[test\]\]/,$d' "$rp/cancho.toml"; rm -f "$rp/cancho.toml.bak"
out=$(run "$rp" "$rc" "$w" refactor --attempts 1); expect "project: no [[test]] table is no-tests" "$(attempts "$out")" "1:refused:no-tests"
# a bug in a project: the probe on the base runs the project's tests
rp=$(newproject); rc=$(newrc); w="$d/w-proj-bug"
sed -i.bak 's|return x / 2;|return x / 3;|' "$rp/src/mathx.cho"; rm -f "$rp/src/mathx.cho.bak"
sed -i.bak 's|mathx.half(9) == 4|mathx.half(9) == 3|' "$rp/tests/mathx_test.cho"; rm -f "$rp/tests/mathx_test.cho.bak"
HALF='=== FILE src/mathx.cho
pub fn half(x: int) -> [] int { return x / 2; }
=== FILE tests/mathx_test.cho
pub fn test_half() -> [] int { test.assert(mathx.half(9) == 4); return 0; }'
printf '%s\npub fn test_half_zero() -> [] int { test.assert(mathx.half(0) == 0); return 0; }\n' "$HALF" > "$rc/reply.1"
printf '%s\npub fn test_half_ten() -> [] int { test.assert(mathx.half(10) == 5); return 0; }\n' "$HALF" > "$rc/reply.2"
out=$(run "$rp" "$rc" "$w" bug); expect "project, bug: a test that passes on the base is refused by name, the retry passes" "$(attempts "$out")" "1:refused:test-passes-on-base 2:passed"
has "project, bug: the refusal names the test" "$out" "test_half_zero"
# a cancho.toml with neither table is not a project: the repository is checked file by file, as before
rp=$(newrepo); rc=$(newrc); w="$d/w-proj-plain"; printf '%s\n' "$PLUS" > "$rc/reply.1"; printf '[package]\nname = "plain"\n' > "$rp/cancho.toml"
out=$(run "$rp" "$rc" "$w" refactor --attempts 1); expect "a cancho.toml with no [[bin]] or [[test]]: checked file by file" "$(attempts "$out")" "1:passed"

# static: the driver never runs git
code=$(grep -v '^[[:space:]]*//' "$SRC/repochange.cho" "$SRC/selection.cho" "$SRC/textedges.cho" "$SRC/change.cho" | grep -E 'git (push|commit|add|checkout|clone|apply|fetch)|"git |/git ' | head -3)
expect "static: no git in the driver" "$code" ""

[ $fail -eq 0 ] && echo "repo.patch gate: ok"
exit $fail
