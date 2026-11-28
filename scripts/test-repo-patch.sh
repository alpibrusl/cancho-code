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
#   helpers    a feature's test that reaches the new function through a helper of its own file exercises it
#   not run    a test the change adds in a file the repository does not run (not tests/NAME_test.cho; in a project, of no [[test]]): `test-not-run`
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
 ("exercising-off", "repochange.cho", 'if bytes.equal(kind, "feature") && tests_added > scripts_added {', 'if false && tests_added > scripts_added {'),
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
 ("helpers-not-followed", "repochange.cho", "tests_text = buffer.append(heap, tests_text, buffer.bytes(thr));", "tests_text = buffer.append(heap, tests_text, buffer.bytes(ttr2));"),
 ("helper-of-a-helper-not-followed", "splice.cho", "                                grew = true;\n                                out = buffer.push(heap, out, byte_of(10));", "                                out = buffer.push(heap, out, byte_of(10));"),
 ("every-function-a-helper", "splice.cho", "hit = calls_fn(buffer.bytes(or), file[tf[6 * k + 3]..tf[6 * k + 4]]);", "hit = true;"),
 ("test-not-run-off", "repochange.cho", "    borrow missing as &mr in {\n        if len(buffer.bytes(mr)) > 0 {", "    borrow missing as &mr in {\n        if false {"),
 ("not-run-plain-off", "repochange.cho", "} else if failed == false {", "} else if false {"),
 ("not-run-project-off", "repochange.cho", "rep = not_run(heap, rep, buffer.bytes(sq2), names);", 'rep = not_run(heap, rep, buffer.bytes(sq2), "");'),
 ("bare-name-not-seen", "change.cho", '|| int_of(output[i]) == 32 && i >= 4 && bytes.equal(output[i - 4..i], "test")', '|| false'),
 ("project-not-seen", "repochange.cho", "        if code >= 1 && code <= 3 {\n            tables = code;", "        if false {\n            tables = code;"),
 ("project-build-not-run", "repochange.cho", "    if built && tables % 2 == 1 {\n        let (code, said) = project_run", "    if false {\n        let (code, said) = project_run"),
 ("project-tests-not-run", "repochange.cho", "    if built {\n        let (code, said) = project_run", "    if false {\n        let (code, said) = project_run"),
 ("project-without-tests-accepted", "repochange.cho", "    if tables < 2 {\n        return change.error_line", "    if false {\n        return change.error_line"),
 ("project-probe-file-by-file", "repochange.cho", "                                if project {", "                                if false {"),
 ("names-from-the-preamble", "selection.cho", "            if bytes.equal(request[start..e], mark) {", "            if false {"),
 ("backticks-ignored", "selection.cho", '                    if mark(edges, t, arr, n, d, buffer.bytes(nr), "", false) > 0 {', "                    if false {"),
 ("plain-words-never-name", "selection.cho", '                    } else if mark(edges, t, arr, n, d, buffer.bytes(nr), "", true) > 0 {', "                    } else if true {"),
 ("file-beside-a-name-is-a-seed", "selection.cho", "seeds = mark(edges, t, arr, n, d, buffer.bytes(nr), touch, false);", "seeds = mark(edges, t, arr, n, d, buffer.bytes(nr), touch, true);"),
 ("open-backtick-runs-on", "selection.cho", "        if c == 10 {\n            open = 0 - 1;\n        } else if c == 96 {", "        if c == 96 {"),
 ("script-output-from-the-start", "repochange.cho", "tail_of(heap, d, bytes.trim(buffer.bytes(sq)), 1200)", "head_of(heap, d, bytes.trim(buffer.bytes(sq)), 1200)"),
 ("script-probe-off", "repochange.cho", "            if passed && bug {", "            if false {"),
 ("script-probe-on-the-fix", "repochange.cho", 'b = buffer.append(heap, b, "/base ");', 'b = buffer.append(heap, b, "/tree ");'),
 ("scripts-not-run", "repochange.cho", "    if built_clean && scripts_added > 0 {", "    if false {"),
 ("script-run-in-the-tree", "repochange.cho", '"/check && SCRIPT_PATH="', '"/tree && SCRIPT_PATH="'),
 ("script-anywhere", "change.cho", "    if is_script(path, dir) == false {\n        return path_tag_in(path, srcs);\n    }", ""),
 ("cho-file-is-a-script", "change.cho", 'return len(path) < 4 || bytes.equal(path[len(path) - 4..len(path)], ".cho") == false;', "return true;"),
 ("unchanged-script-counts", "repochange.cho", "if bok == false || bytes.equal(buffer.bytes(btr), buffer.bytes(ntr)) == false {", "if true {"),
 ("script-as-items", "repochange.cho", "                if change.is_script(path, sdir) {\n                    if len(bytes.trim(env[bs..bz])) == 0 {", "                if false {\n                    if len(bytes.trim(env[bs..bz])) == 0 {"),
 ("empty-script-written", "repochange.cho", "                    if len(bytes.trim(env[bs..bz])) == 0 {", "                    if false {"),
 ("scripts-formatted", "repochange.cho", '                        if bytes.ends_with(all[q..e], ".cho") {', "                        if true {"),
 ("script-feature-asked-for-calls", "repochange.cho", 'if bytes.equal(kind, "feature") && tests_added > scripts_added {', 'if bytes.equal(kind, "feature") && tests_added > 0 {'),
 ("shown-scripts-not-shown", "repochange.cho", 'case \\"$show\\" in *\\" $f \\"*) w=1 ;; esac; ', ''),
 ("named-script-not-shown", "repochange.cho", '../request.txt 2>/dev/null && w=1; }', '../request.txt 2>/dev/null && w=0; }'),
 ("every-script-shown", "repochange.cho", "w=0; case", "w=1; case"),
 ("selection-outlines-scripts", "selection.cho", '            if bytes.ends_with(path, ".cho") == false {', "            if false {"),
 ("script-plain-repo-run", "repochange.cho", "    if tables == 0 {\n        return change.error_line(heap, rep, \"script-test-failed\"", "    if false {\n        return change.error_line(heap, rep, \"script-test-failed\""),
 ("scripts-file-not-checked", "repochange.cho", "why = change.scripts_problem(buffer.bytes(ssr));", 'why = "";'),
 ("first-mark-not-the-last", "selection.cho", "                from = i + 1;\n                if from > len(request) {", "                if from == 0 {\n                    from = i + 1;\n                }\n                if from > len(request) {"),
 ("area-not-checked", "change.cho", "    if in_area(path, srcs) == false {\n        return \"path-outside\";", "    if false {\n        return \"path-outside\";"),
 ("file-source-is-a-directory", "change.cho", "if file == false && len(path) > len(one) && bytes.equal(path[0..len(one)], one)", "if len(path) > len(one) && bytes.equal(path[0..len(one)], one)"),
 ("source-prefix-without-slash", "change.cho", "bytes.equal(path[0..len(one)], one) && int_of(path[len(one)]) == 47 {", "bytes.equal(path[0..len(one)], one) {"),
 ("sources-are-src-only", "change.cho", 'return bytes.starts_with(path, "tests/") == false;', 'return bytes.starts_with(path, "src/");'),
 ("stray-glob-taken", "change.cho", "&& glob_in_area(ln[v0..v1], srcs) == false {", "&& false {"),
 ("glob-above-a-source-refused", "change.cho", "if int_of(stem[n - 1]) == 47 && bytes.starts_with(one, stem) {", "if false {"),
 ("bundle-of-src-only", "repochange.cho", "find $(cat ../area.src) tests -type f -name", "find src tests -type f -name"),
 ("lines-of-src-only", "repochange.cho", "for p in $(cat area.src); do diff -ruN base/$p tree/$p; done", "diff -ruN base/src tree/src"),
 ("area-always-src", "repochange.cho", "a=src; if [ -f cancho.toml ] && grep -qE", "a=src; if false && grep -qE"),
 ("tests-in-the-sources", "repochange.cho", " | grep -v -E '^tests(/|$)' | LC_ALL=C sort -u", " | LC_ALL=C sort -u"),
 ("source-words-not-checked", "repochange.cho", 'case \\"$p\\" in /*|.*|*..*|*/.*|*[!A-Za-z0-9_./-]*) exit 1 ;; esac; ', ''),
 ("link-above-not-seen", "repochange.cho", 'q=$p; while [ \\"$q\\" != . ]; do [ ! -L \\"$q\\" ] || exit 1; q=$(dirname \\"$q\\"); done; ', ''),
 ("link-inside-not-seen", "repochange.cho", '[ -z \\"$(find $a tests -type l 2>/dev/null)\\" ] || exit 1; ', ''),
 ("source-not-cancho", "repochange.cho", 'case \\"$p\\" in *.cho) : ;; *) exit 1 ;; esac; ', ''),
 ("text-edges-of-src-only", "textedges.cho", 'bytes.starts_with(t[i..e], "=== FILE ") && bytes.starts_with(t[i..e], "=== FILE tests/") == false', 'bytes.starts_with(t[i..e], "=== FILE src/")'),
]
for name, fn, old, new in M:
    d = os.path.join(work, name)
    shutil.copytree(src, d)
    p = os.path.join(d, fn)
    t = open(p).read()
    if t.count(old) != 1:
        sys.exit("mutant %s: the text to break is in %s %d times, not once" % (name, fn, t.count(old)))
    open(p, "w").write(t.replace(old, new))
# REPOPATCH_MUTANTS=a,b runs only the mutants whose name has one of those words in it (to try new ones; the gate runs them all)
only = [w for w in os.environ.get("REPOPATCH_MUTANTS", "").split(",") if w]
open(os.path.join(work, "names"), "w").write("\n".join(m[0] for m in M if not only or any(w in m[0] for w in only)) + "\n")
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
# a test file with no `module` line prints the bare name, after `test ` (and not after another word)
printf 'running 4 tests\ntest test_a ... ok\ntest test_ab ... FAILED\nnot test_c ... ok\ntest test_d ... FAILED\n' > "$d/ps.bare"
expect "passed: a file with no module line prints the bare name" "$("$G" passed "$d/ps.bare" "$d/ps.names" | tr '\n' ' ')" "test_a "
expect "notpassed: the names with no ok line" "$("$G" notpassed "$d/ps.out" "$d/ps.names" | tr '\n' ' ')" "test_ab test_c test_d "
# a test that reaches the new code through a helper of its own file, or through two; a helper that is not called is not followed (the second helper stands before the first in the file: one pass over the file does not find it)
printf 'edition 7;\n\nfn deep(x: int) -> [] int {\n    return m.fresh(x);\n}\n\nfn key_is(x: int) -> [] bool {\n    return deep(x) == 1;\n}\n\nfn other() -> [] int {\n    return m.change();\n}\n\nfn test_one() -> [] int {\n    test.assert(key_is(1));\n    return 0;\n}\n' > "$d/hp.file"
printf 'fn test_one() -> [] int {\n    test.assert(key_is(1));\n    return 0;\n}\n' > "$d/hp.seed"
"$G" helpers "$d/hp.file" "$d/hp.seed" > "$d/hp.out"
printf 'fresh\n' > "$d/hp.fresh"; printf 'change\n' > "$d/hp.change"
expect "helpers: the test alone does not call the new function" "$("$G" exercise "$d/hp.seed" "$d/hp.fresh")" no
expect "helpers: through two helpers of its file it does" "$("$G" exercise "$d/hp.out" "$d/hp.fresh")" yes
expect "helpers: a helper the test does not call is not followed" "$("$G" exercise "$d/hp.out" "$d/hp.change")" no
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
expect "constraints: a glob that is not a relative path" "$(cons 'keep-names /lib/*')" "1 keep-names takes a path under src/ or tests/, with a * only at its end"
# which paths a repository has is known once its sources are: a keep-names path about nothing of them is refused then (change.glob_outside)
expect "constraints: a glob outside src/ and tests/" "$("$G" globarea 'keep-names lib/*' 'src')" "1"
expect "constraints: a glob under src/" "$("$G" globarea 'keep-names src/api/*' 'src')" "0"
expect "constraints: a glob under tests/" "$("$G" globarea 'keep-names tests/*' 'src')" "0"
expect "constraints: a glob under a source of a project" "$("$G" globarea 'keep-names lib/plot/*' 'lib/plot tools/plot')" "0"
expect "constraints: a glob above a source of a project" "$("$G" globarea 'keep-names lib/*' 'lib/plot tools/plot')" "0"
expect "constraints: a glob that only starts like a source" "$("$G" globarea 'keep-names lib/plotter/*' 'lib/plot tools/plot')" "1"
expect "constraints: a glob that names a source file" "$("$G" globarea 'keep-names lib/a.cho' 'lib/a.cho')" "0"
expect "constraints: src/ is no source of a project that has none" "$("$G" globarea 'keep-names src/*' 'lib/plot')" "1"
# the area of a project: what its sources name, and tests/ (change.path_tag_in)
for spec in 'lib/plot/a.cho:ok' 'lib/plot/sub/a.cho:ok' 'tools/plot/main.cho:ok' 'tests/a_test.cho:ok' 'one/file.cho:ok' 'src/a.cho:path-outside' \
            'lib/a.cho:path-outside' 'lib/plotter/a.cho:path-outside' 'lib/plot.cho:path-outside' 'one/file.cho/x.cho:path-outside' 'one/other.cho:path-outside' \
            'generated/x.cho:path-outside' 'lib/plot/../a.cho:path-dotdot' 'lib/plot/a.txt:path-outside' 'lib/plot:path-outside'; do
    p=${spec%%:*}; want=${spec#*:}
    expect "area path $p" "$("$G" patharea "$p" "lib/plot tools/plot one/file.cho")" "$want"
done
expect "constraints: a * in the middle" "$(cons 'keep-names tests/*_test.cho')" "1 keep-names takes a path under src/ or tests/, with a * only at its end"
expect "constraints: a .. in a glob" "$(cons 'keep-names tests/../x')" "1 keep-names takes a path under src/ or tests/, with a * only at its end"

# the violations: records of a change that renamed a test, added two items and a helper
printf 'src/d.cho\tR\tfn\tedit_count\t1\t5\nsrc/d.cho\tA\tfn\tedit_distance\t1\t5\nsrc/d.cho\tA\tfn\tdiff_lcs\t0\t40\nsrc/d.cho\tC\tfn\tdiff_stat\t1\t9\ntests/d_test.cho\tR\tfn\ttest_edit_count_1\t1\t3\ntests/d_test.cho\tA\tfn\ttest_edit_distance_1\t1\t3\ntests/d_test.cho\tC\tfn\ttest_other\t1\t3\ntests/d_test.cho\tR\tfn\thelper_x\t0\t3\n' > "$d/vi.rec"
viol() { printf '%s\n' "$1" > "$d/c.txt"; "$G" violate "$d/c.txt" "$d/vi.rec" "${2:-0}" | cut -f2,4 | tr '\t\n' ' :' | sed 's/:$//'; }
expect "violations: keep-names tests/* names the removed tests and helpers" "$(viol 'keep-names tests/*')" "constraint-keep-names these functions were removed or renamed, and the request keeps their names: test_edit_count_1, helper_x"
expect "violations: keep-names of a src file: its removed function" "$(viol 'keep-names src/d.cho')" "constraint-keep-names these functions were removed or renamed, and the request keeps their names: edit_count"
expect "violations: keep-names of another file: nothing" "$(viol 'keep-names src/other.cho')" ""
expect "violations: changing a test is not removing it" "$(viol 'keep-names tests/d_test.cho' | grep -c test_other)" 0
expect "violations: max-added-items counts the additions in src/ only" "$(viol 'max-added-items 1')" "constraint-max-added-items the change adds 2 items to the sources (edit_distance, diff_lcs); at most 1"
expect "violations: max-added-items met" "$(viol 'max-added-items 2')" ""
expect "violations: max-added-items 0" "$(viol 'max-added-items 0' | cut -d' ' -f1)" "constraint-max-added-items"
expect "violations: max-added-lines" "$(viol 'max-added-lines 10' 41)" "constraint-max-added-lines the change adds 41 lines to the sources; at most 10"
expect "violations: max-added-lines met exactly" "$(viol 'max-added-lines 41' 41)" ""
expect "violations: only-items names what is outside the list, in src/ only" "$(viol 'only-items edit_distance,diff_stat')" "constraint-only-items the change touches items of the sources the request does not allow: edit_count, diff_lcs"
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
# a test that calls the new function through a helper of its own file does call it
rp=$(newrepo); rc=$(newrc); w="$d/w-exercising-helper"
printf '=== FILE src/mathx.cho\npub fn quarter(x: int) -> [] int { return x / 4; }\n=== FILE tests/mathx_test.cho\nfn quarter_is(x: int, want: int) -> [] bool { return mathx.quarter(x) == want; }\npub fn test_quarter_by_helper() -> [] int { test.assert(quarter_is(9, 2)); return 0; }\n' > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" feature --attempts 1); expect "exercising: a test that calls the new function through a helper of its file passes" "$(attempts "$out")" "1:passed"
# a test in a file the repository does not run proves nothing: refused by name, the retry (in a file that is run) passes
rp=$(newrepo); rc=$(newrc); w="$d/w-notrun"
printf '=== FILE src/mathx.cho\npub fn quarter(x: int) -> [] int { return x / 4; }\n=== FILE tests/extra.cho\nedition 7;\n\nmodule extra;\n\nimport mathx;\nimport std.test;\n\npub fn test_quarter_wrong() -> [] int { test.assert(mathx.quarter(9) == 99); return 0; }\n' > "$rc/reply.1"
printf '%s\n' "$QUARTER" > "$rc/reply.2"
out=$(run "$rp" "$rc" "$w" feature); expect "not run: a test in a file the gate does not run is refused, the retry passes" "$(attempts "$out")" "1:refused:test-not-run 2:passed"
has "not run: the feedback names the tag" "$(cat "$rc/feedback.2")" "test-not-run"
has "not run: and the test" "$(cat "$rc/feedback.2")" "test_quarter_wrong"
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
has "max-added-lines: the feedback has the counts" "$(cat "$rc/feedback.2")" "adds 7 lines to the sources; at most 4"
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
# a project: a new test file that is in no [[test]] never runs: refused, whatever it asserts
rp=$(newproject); rc=$(newrc); w="$d/w-proj-notrun"
printf '%s\n=== FILE tests/other_test.cho\nedition 7;\n\nmodule other_test;\n\nimport mathx;\nimport std.test;\n\npub fn test_double_is_wrong() -> [] int { test.assert(mathx.double(2) == 99); return 0; }\n' "$PLUS" > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" refactor --attempts 1); expect "project: a test in a file of no [[test]] is test-not-run" "$(attempts "$out")" "1:refused:test-not-run"
has "project: the refusal names the test" "$out" "test_double_is_wrong"
# a project whose test file has no `module` line prints bare test names: the base probe still sees a test that passes on the base
rp=$(newproject); rc=$(newrc); w="$d/w-proj-bug-bare"
sed -i.bak 's|return x / 2;|return x / 3;|' "$rp/src/mathx.cho"; rm -f "$rp/src/mathx.cho.bak"
sed -i.bak -e 's|mathx.half(9) == 4|mathx.half(9) == 3|' -e '/^module mathx_test;$/d' "$rp/tests/mathx_test.cho"; rm -f "$rp/tests/mathx_test.cho.bak"
printf '%s\npub fn test_half_zero() -> [] int { test.assert(mathx.half(0) == 0); return 0; }\n' "$HALF" > "$rc/reply.1"
printf '%s\npub fn test_half_ten() -> [] int { test.assert(mathx.half(10) == 5); return 0; }\n' "$HALF" > "$rc/reply.2"
out=$(run "$rp" "$rc" "$w" bug); expect "project, bug, no module line: a test that passes on the base is refused, the retry passes" "$(attempts "$out")" "1:refused:test-passes-on-base 2:passed"
# ---- script tests: what is wrong in a program's main is proven by a script that runs the built program (docs/repo-patch.md, "Script tests") ----
# the project's program exits 1 instead of 0 (the bug is in `main`, which no test function can call); tests/scripts/ holds scripts run with sh
scriptproject() {
    r=$(newproject)
    sed -i.bak 's|return mathx.triple(1) - 3;|return mathx.triple(1) - 2;|' "$r/src/main.cho"; rm -f "$r/src/main.cho.bak"
    mkdir -p "$r/tests/scripts"
    printf '# the program is there after a build\n[ -x ./build/mathproj ]\n' > "$r/tests/scripts/ok.sh"
    printf '# a long script nobody asked about\necho a-line-only-long-has\n' > "$r/tests/scripts/long.sh"
    echo "$r"
}
printf 'tests/scripts\nsh "$SCRIPT_PATH"\ntests/scripts/ok.sh\n' > "$d/scripts.txt"
MAIN='=== FILE src/main.cho
fn main(world: World) -> [] int { release(world); return mathx.triple(1) - 3; }'
EXITS='=== FILE tests/scripts/exit.sh
# the program says 0
: > tests/scripts/junk.out
./build/mathproj'
rp=$(scriptproject); rc=$(newrc); w="$d/w-script-ok"; printf '%s\n%s\n' "$MAIN" "$EXITS" > "$rc/reply.1"
before=$(tree_hash "$rp")
out=$(run "$rp" "$rc" "$w" bug --attempts 1 --script-tests "$d/scripts.txt"); expect "script: a bug in main, proven by a script that fails on the base: done" "$(attempts "$out")" "1:passed"
expect "script: the repository is untouched" "$(tree_hash "$rp")" "$before"
has "script: the script is in the patch" "$(cat "$w/change.patch")" "+./build/mathproj"
hasnt "script: what the script wrote when it ran is not in the patch" "$(cat "$w/change.patch")" "tree/tests/scripts/junk.out"
[ -e "$w/tree/tests/scripts/junk.out" ] && { echo "FAIL: script: the script ran in the tree the patch is made from" >&2; fail=1; }
has "script: the task says there are script tests and how one is run" "$(cat "$rc/task.1")" 'sh "$SCRIPT_PATH"'
has "script: a script that is always shown is shown whole" "$(cat "$rc/bundle.1")" "[ -x ./build/mathproj ]"
has "script: another script is named, not shown" "$(cat "$rc/bundle.1")" "=== FILE tests/scripts/long.sh
# a script test, not shown"
hasnt "script: another script is not shown" "$(cat "$rc/bundle.1")" "a-line-only-long-has"
# the request names a script: it is shown
printf 'The program exits 1. See tests/scripts/long.sh for how it is run.\n' > "$d/change-names-script.txt"
rp=$(scriptproject); rc=$(newrc); w="$d/w-script-named"; printf '%s\n%s\n' "$MAIN" "$EXITS" > "$rc/reply.1"
out=$(req="$d/change-names-script.txt"; run "$rp" "$rc" "$w" bug --attempts 1 --script-tests "$d/scripts.txt")
has "script: a script the request names is shown" "$(cat "$rc/bundle.1")" "a-line-only-long-has"
# a script that passes on the base proves nothing; one that fails on the fixed tree is a failed test
rp=$(scriptproject); rc=$(newrc); w="$d/w-script-base"
printf '%s\n=== FILE tests/scripts/exit.sh\n[ -x ./build/mathproj ]\n' "$MAIN" > "$rc/reply.1"; printf '%s\n%s\n' "$MAIN" "$EXITS" > "$rc/reply.2"
out=$(run "$rp" "$rc" "$w" bug --script-tests "$d/scripts.txt"); expect "script, bug: a script that passes on the base is refused, the retry passes" "$(attempts "$out")" "1:refused:test-passes-on-base 2:passed"
has "script, bug: the refusal names the script" "$(grep CHANGE_ERROR "$w/run.log")" "test-passes-on-base	tests/scripts/exit.sh"
rp=$(scriptproject); rc=$(newrc); w="$d/w-script-fails"
printf '%s\n=== FILE tests/scripts/exit.sh\necho the-script-said-this\nexit 3\n' "$MAIN" > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" bug --attempts 1 --script-tests "$d/scripts.txt"); expect "script: a script that fails on the changed tree is script-test-failed" "$(attempts "$out")" "1:refused:script-test-failed"
has "script: the refusal has what the script said" "$out" "the-script-said-this"
# a script that says a lot: the refusal has the end of it, which is where what went wrong is
rp=$(scriptproject); rc=$(newrc); w="$d/w-script-long"
printf '%s\n=== FILE tests/scripts/exit.sh\ni=0; while [ $i -lt 200 ]; do echo line-$i-of-a-long-output; i=$((i + 1)); done\necho the-last-thing-said\nexit 3\n' "$MAIN" > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" bug --attempts 1 --script-tests "$d/scripts.txt")
has "script: a long output is cut at its start, not its end" "$out" "the-last-thing-said"
hasnt "script: a long output is cut at its start" "$out" "line-0-of-a-long-output"
# a script the change leaves as it was is not a test of the change
rp=$(scriptproject); rc=$(newrc); w="$d/w-script-same"
printf '%s\n=== FILE tests/scripts/ok.sh\n# the program is there after a build\n[ -x ./build/mathproj ]\n' "$MAIN" > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" bug --attempts 1 --script-tests "$d/scripts.txt"); expect "script: a script written back as it was is no test" "$(attempts "$out")" "1:refused:no-test-added"
# a feature whose only test is a script is not asked which function its tests call
rp=$(scriptproject); rc=$(newrc); w="$d/w-script-feature"
printf '=== FILE src/mathx.cho\npub fn quad(x: int) -> [] int { return x * 4; }\n%s\n%s\n' "$MAIN" "$EXITS" > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" feature --attempts 1 --script-tests "$d/scripts.txt"); expect "script: a feature with a script for its test" "$(attempts "$out")" "1:passed"
# where a script may be written: under the script directory only, and only when the caller named one
rp=$(scriptproject); rc=$(newrc); w="$d/w-script-off"; printf '%s\n%s\n' "$MAIN" "$EXITS" > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" bug --attempts 1); expect "script: without --script-tests a script is a path that may not be written" "$(attempts "$out")" "1:refused:path-outside"
rp=$(scriptproject); rc=$(newrc); w="$d/w-script-else"; printf '%s\n=== FILE tests/other/exit.sh\n./build/mathproj\n' "$MAIN" > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" bug --attempts 1 --script-tests "$d/scripts.txt"); expect "script: a script outside the script directory" "$(attempts "$out")" "1:refused:path-outside"
rp=$(scriptproject); rc=$(newrc); w="$d/w-script-dots"; printf '%s\n=== FILE tests/scripts/../../x.sh\n./build/mathproj\n' "$MAIN" > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" bug --attempts 1 --script-tests "$d/scripts.txt"); expect "script: .. in the path of a script" "$(attempts "$out")" "1:refused:path-dotdot"
[ -e "$w/x.sh" ] && { echo "FAIL: script: a path with .. was written" >&2; fail=1; }
rp=$(scriptproject); rc=$(newrc); w="$d/w-script-hidden"; printf '%s\n=== FILE tests/scripts/.hidden.sh\n./build/mathproj\n' "$MAIN" > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" bug --attempts 1 --script-tests "$d/scripts.txt"); expect "script: a hidden script" "$(attempts "$out")" "1:refused:path-component"
rp=$(scriptproject); rc=$(newrc); w="$d/w-script-empty"; printf '%s\n=== FILE tests/scripts/exit.sh\n\n' "$MAIN" > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" bug --attempts 1 --script-tests "$d/scripts.txt"); expect "script: an empty script" "$(attempts "$out")" "1:refused:script-empty"
# a .cho file of the script directory is still the compiler's: items, not a whole file
rp=$(scriptproject); rc=$(newrc); w="$d/w-script-cho"; printf '%s\n=== FILE tests/scripts/x.cho\nthis is not cancho\n' "$MAIN" > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" bug --attempts 1 --script-tests "$d/scripts.txt")
hasnt "script: a .cho file under the script directory is not written whole" "$(attempts "$out")" "passed"
[ -e "$w/tree/tests/scripts/x.cho" ] && grep -q 'this is not cancho' "$w/tree/tests/scripts/x.cho" && { echo "FAIL: script: a .cho file was written whole" >&2; fail=1; }
# script tests are for a project: there is nothing built to run in a repository checked file by file
rp=$(newrepo); rc=$(newrc); w="$d/w-script-plain"; mkdir -p "$rp/tests/scripts"; printf '=== FILE src/mathx.cho\npub fn double(x: int) -> [] int { return x + x; }\n=== FILE tests/scripts/t.sh\nexit 0\n' > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" refactor --attempts 1 --script-tests "$d/scripts.txt"); expect "script: not in a project" "$(attempts "$out")" "1:refused:script-test-failed"
has "script: not in a project: the refusal says so, nothing was run" "$out" "this repository is not a project"
# a selection keeps a script as the bundle has it
rp=$(bigrepo); rc=$(newrc); w="$d/w-script-sel"; mkdir -p "$rp/tests/scripts"; printf '# the program is there after a build\n[ -x ./build/mathproj ]\n' > "$rp/tests/scripts/ok.sh"; printf '%s\n' "$DOUBLE" > "$rc/reply.1"
printf 'Make `double` add the number to itself instead of multiplying.\n' > "$d/change-script-sel.txt"
out=$(req="$d/change-script-sel.txt"; run "$rp" "$rc" "$w" refactor --attempts 1 --max-bundle 3500 --script-tests "$d/scripts.txt"); expect "script, selection: verdict" "$(verdict "$out")" done
has "script, selection: it is a selection" "$out" "[CHANGE_SELECTION]"
has "script, selection: the script that is always shown is whole" "$(cat "$rc/bundle.1")" "[ -x ./build/mathproj ]"
# --script-tests is three lines, checked before anything runs
sbad() { printf "$2" > "$d/sbad.txt"; rp=$(scriptproject); rc=$(newrc); o=$(run "$rp" "$rc" "$d/w-sbad" bug --attempts 1 --script-tests "$d/sbad.txt"); has "script usage: $1" "$o" "--script-tests: "; [ -e "$rc/bundle.1" ] && { echo "FAIL: script usage: $1: the agent was called" >&2; fail=1; }; }
sbad "a directory that is not under tests/" 'src/scripts\nsh "$SCRIPT_PATH"\n\n'
sbad "tests itself" 'tests/\nsh "$SCRIPT_PATH"\n\n'
sbad ".. in the directory" 'tests/../x\nsh "$SCRIPT_PATH"\n\n'
sbad "no command" 'tests/scripts\n\n\n'
sbad "a shown script of another directory" 'tests/scripts\nsh "$SCRIPT_PATH"\ntests/other/ok.sh\n'

# a cancho.toml with neither table is not a project: the repository is checked file by file, as before
rp=$(newrepo); rc=$(newrc); w="$d/w-proj-plain"; printf '%s\n' "$PLUS" > "$rc/reply.1"; printf '[package]\nname = "plain"\n' > "$rp/cancho.toml"
out=$(run "$rp" "$rc" "$w" refactor --attempts 1); expect "a cancho.toml with no [[bin]] or [[test]]: checked file by file" "$(attempts "$out")" "1:passed"

# ---- a project whose sources are not in src/ (docs/repo-patch.md, "The sources of a project") -------------------------------------------------
# lib/mathx and tools/mathproj hold the code, cancho.toml names them, there is no src/ at all; extra/ is a directory the project does not name
newlibproject() {
    r=$(newproject)
    mkdir -p "$r/lib/mathx" "$r/tools/mathproj" "$r/extra"
    mv "$r/src/mathx.cho" "$r/lib/mathx/mathx.cho"; mv "$r/src/main.cho" "$r/tools/mathproj/main.cho"; rmdir "$r/src"
    printf 'edition 7;\n\nmodule notes;\n\npub fn unnamed_by_the_project() -> [] int {\n    return 0;\n}\n' > "$r/extra/notes.cho"
    sed -i.bak -e 's|sources = \["src/mathx.cho", "src/main.cho"\]|sources = ["lib/mathx", "tools/mathproj"]|' \
        -e 's|sources = \["src/mathx.cho", "tests/mathx_test.cho"\]|sources = ["lib/mathx", "tests/mathx_test.cho"]|' "$r/cancho.toml"; rm -f "$r/cancho.toml.bak"
    echo "$r"
}
LPLUS='=== FILE lib/mathx/mathx.cho
pub fn double(x: int) -> [] int { return x + x; }'
rp=$(newlibproject); rc=$(newrc); w="$d/w-lib-ok"; printf '%s\n' "$LPLUS" > "$rc/reply.1"
out=$(run "$rp" "$rc" "$w" refactor --attempts 1); expect "sources: a project with lib/ and tools/ and no src/: done" "$(attempts "$out")" "1:passed"
expect "sources: the area is what cancho.toml names outside tests/" "$(cat "$w/area.src" | tr -s ' ' | sed 's/ $//')" "lib/mathx tools/mathproj"
has "sources: the library is shown" "$(cat "$rc/bundle.1")" "=== FILE lib/mathx/mathx.cho"
has "sources: the program is shown" "$(cat "$rc/bundle.1")" "=== FILE tools/mathproj/main.cho"
has "sources: the tests are shown" "$(cat "$rc/bundle.1")" "=== FILE tests/mathx_test.cho"
hasnt "sources: a directory the project does not name is not shown" "$(cat "$rc/bundle.1")" "extra/notes.cho"
has "sources: the patch is of the library" "$(cat "$w/change.patch")" "tree/lib/mathx/mathx.cho"
# what the project does not name may not be written: extra/, and src/ (which this project does not have)
for outside in extra/notes.cho src/new.cho cancho.toml; do
    rp=$(newlibproject); rc=$(newrc); w="$d/w-lib-out-$(echo "$outside" | tr '/.' '__')"
    printf '%s\n=== FILE %s\nedition 7;\n\nmodule notes;\n\npub fn written() -> [] int {\n    return 1;\n}\n' "$LPLUS" "$outside" > "$rc/reply.1"
    out=$(run "$rp" "$rc" "$w" refactor --attempts 1); expect "sources: $outside is outside the area" "$(attempts "$out")" "1:refused:path-outside"
    has "sources: the refusal of $outside names the sources" "$(grep CHANGE_ERROR "$w/run.log")" "lib/mathx tools/mathproj"
    [ -e "$w/tree/src" ] && { echo "FAIL: sources: a refused path was written ($outside)" >&2; fail=1; }
done
# the checks that told src/ from tests/ now tell the sources from tests/: a bug's probe, a feature's exercising test, the added lines
rp=$(newlibproject); rc=$(newrc); w="$d/w-lib-bug"
sed -i.bak 's|return x / 2;|return x / 3;|' "$rp/lib/mathx/mathx.cho"; rm -f "$rp/lib/mathx/mathx.cho.bak"
sed -i.bak 's|mathx.half(9) == 4|mathx.half(9) == 3|' "$rp/tests/mathx_test.cho"; rm -f "$rp/tests/mathx_test.cho.bak"
LHALF='=== FILE lib/mathx/mathx.cho
pub fn half(x: int) -> [] int { return x / 2; }
=== FILE tests/mathx_test.cho
pub fn test_half() -> [] int { test.assert(mathx.half(9) == 4); return 0; }'
printf '%s\npub fn test_half_zero() -> [] int { test.assert(mathx.half(0) == 0); return 0; }\n' "$LHALF" > "$rc/reply.1"
printf '%s\npub fn test_half_ten() -> [] int { test.assert(mathx.half(10) == 5); return 0; }\n' "$LHALF" > "$rc/reply.2"
out=$(run "$rp" "$rc" "$w" bug); expect "sources, bug: a test that passes on the base is refused, the retry passes" "$(attempts "$out")" "1:refused:test-passes-on-base 2:passed"
rp=$(newlibproject); rc=$(newrc); w="$d/w-lib-feature"
LSIX='=== FILE lib/mathx/mathx.cho
pub fn sextuple(x: int) -> [] int { return x * 6; }'
printf '%s\n=== FILE tests/mathx_test.cho\npub fn test_half_again() -> [] int { test.assert(mathx.half(8) == 4); return 0; }\n' "$LSIX" > "$rc/reply.1"
printf '%s\n=== FILE tests/mathx_test.cho\npub fn test_sextuple() -> [] int { test.assert(mathx.sextuple(2) == 12); return 0; }\n' "$LSIX" > "$rc/reply.2"
out=$(run "$rp" "$rc" "$w" feature); expect "sources, feature: a test that does not call the new function of lib/ is refused, one that does passes" "$(attempts "$out")" "1:refused:test-not-exercising 2:passed"
rp=$(newlibproject); rc=$(newrc); w="$d/w-lib-lines"
printf 'max-added-lines 4\n' > "$CF"
printf '=== FILE lib/mathx/mathx.cho\npub fn sextuple(x: int) -> [] int {\n    let a = x;\n    let b = x;\n    let c = a + b;\n    return c * 3;\n}\n' > "$rc/reply.1"
printf '=== FILE lib/mathx/mathx.cho\npub fn sextuple(x: int) -> [] int { return x * 6; }\n' > "$rc/reply.2"
out=$(run "$rp" "$rc" "$w" refactor --constraints "$CF"); expect "sources: the added lines are counted in lib/" "$(attempts "$out")" "1:refused:constraint-max-added-lines 2:passed"
has "sources: the count is of the library's lines" "$(cat "$rc/feedback.2")" "adds 7 lines to the sources; at most 4"
rp=$(newlibproject); rc=$(newrc); w="$d/w-lib-glob"; printf '%s\n' "$LPLUS" > "$rc/reply.1"
printf 'keep-names src/*\n' > "$CF"
out=$(run "$rp" "$rc" "$w" refactor --attempts 1 --constraints "$CF"); rcode=$?
expect "sources: a keep-names path about nothing of the project is a usage error" "$rcode" 2
has "sources: the usage error names the line and the sources" "$out" "--constraints line 1"
[ -e "$w" ] && { echo "FAIL: sources: a work directory was made for a usage error" >&2; fail=1; }
printf 'keep-names lib/*\n' > "$CF"; w="$d/w-lib-glob2"
out=$(run "$rp" "$rc" "$w" refactor --attempts 1 --constraints "$CF"); expect "sources: a keep-names path above a source is taken" "$(attempts "$out")" "1:passed"
# a project file that names what is not there, what is outside the repository, or a link: the repository is refused before anything is made
badsources() { # name, the sources line of the [[bin]], a command to run in the repository first
    rp=$(newlibproject); rc=$(newrc); w="$d/w-lib-bad-$1"; printf '%s\n' "$LPLUS" > "$rc/reply.1"
    ( cd "$rp" && eval "$3" )
    sed -i.bak "s|sources = \[\"lib/mathx\", \"tools/mathproj\"\]|sources = $2|" "$rp/cancho.toml"; rm -f "$rp/cancho.toml.bak"
    out=$(run "$rp" "$rc" "$w" refactor --attempts 1); rcode=$?
    expect "sources: $1 is repo-invalid (exit)" "$rcode" 2
    has "sources: $1 is repo-invalid" "$out" "repo-invalid"
    [ -s "$rc/log" ] && { echo "FAIL: sources: the agent was run for $1" >&2; fail=1; }
}
badsources missing '["lib/mathx", "tools/gone"]' ':'
badsources dotdot '["lib/mathx", "../elsewhere"]' ':'
badsources absolute '["lib/mathx", "/etc"]' ':'
badsources hidden '["lib/mathx", ".secret"]' 'mkdir .secret'
badsources link '["lib/mathx", "tools/mathproj", "linked"]' 'ln -s extra linked'
badsources link-above '["lib/mathx", "tools/mathproj", "up/extra"]' 'mkdir real && cp -r extra real/extra && ln -s real up'
badsources link-inside '["lib/mathx", "tools/mathproj"]' 'ln -s ../../extra/notes.cho lib/mathx/notes.cho'
badsources not-cancho '["lib/mathx", "tools/mathproj", "README.txt"]' 'echo x > README.txt'
# a project too big to be shown whole: the compiler is not asked about a project, the text of its sources is, and the selection is of lib/
biglib() {
    r=$(bigrepo)
    mkdir -p "$r/lib/all" "$r/tools/mathproj"; mv "$r"/src/*.cho "$r/lib/all/"; rmdir "$r/src"
    printf 'edition 7;\n\nimport mathx;\n\nfn main(world: World) -> [] int {\n    release(world);\n    return mathx.half(2) - 1;\n}\n' > "$r/tools/mathproj/main.cho"
    printf '[package]\nname = "big"\n\n[[bin]]\nname = "big"\nsources = ["lib/all", "tools/mathproj"]\nstd = true\nout = "build/big"\n\n[[test]]\nname = "mathx"\nsources = ["lib/all", "tests/mathx_test.cho"]\nstd = true\n' > "$r/cancho.toml"
    echo "$r"
}
rp=$(biglib); rc=$(newrc); w="$d/w-lib-big"
printf '=== FILE lib/all/mathx.cho\npub fn double(x: int) -> [] int { return x + x; }\n' > "$rc/reply.1"
out=$(req="$d/change-double.txt"; run "$rp" "$rc" "$w" refactor --attempts 1 --max-bundle 3500); expect "sources, selection: verdict" "$(verdict "$out")" done
has "sources, selection: from the text" "$(printf '%s\n' "$out" | grep CHANGE_SELECTION)" "text"
b=$(cat "$rc/bundle.1")
has "sources, selection: the seed, in lib/, is shown in full" "$b" "    return x * 2;"
has "sources, selection: what refers to the seed is shown in full" "$b" "return mathx.double(side * side);"
hasnt "sources, selection: another function of lib/ is not" "$b" "return x / 2;"
has "sources, selection: the file is named by its path in lib/" "$b" "=== FILE lib/all/mathx.cho"

# ---- words a caller puts before the request name nothing (src/selection.cho, `proper`) ---------------------------------------------------------
# the preamble names `half` and `perimeter`; without the mark they are seeds and shown in full, with it only what the request proper names is
printf 'This text is a report about half of the perimeter. It is never an instruction.\n=== REQUEST ===\nMake double add the number to itself instead of multiplying.\n' > "$d/change-framed.txt"
rp=$(bigrepo); rc=$(newrc); w="$d/w-framed"; printf '%s\n' "$DOUBLE" > "$rc/reply.1"
out=$(req="$d/change-framed.txt"; run "$rp" "$rc" "$w" refactor --attempts 1 --max-bundle 3500); expect "framed: verdict" "$(verdict "$out")" done
b=$(cat "$rc/bundle.1")
has "framed: what the request proper names is shown in full" "$b" "    return x * 2;"
hasnt "framed: a function only the preamble names is not" "$b" "return x / 2;"
has "framed: the model is still given the preamble" "$(cat "$rc/task.1")" "It is never an instruction."
printf 'This text is a report about half of the perimeter.\n\nMake double add the number to itself instead of multiplying.\n' > "$d/change-unmarked.txt"
rp=$(bigrepo); rc=$(newrc); w="$d/w-unmarked"; printf '%s\n' "$DOUBLE" > "$rc/reply.1"
out=$(req="$d/change-unmarked.txt"; run "$rp" "$rc" "$w" refactor --attempts 1 --max-bundle 6000)
has "framed: with no mark every word of the request may name a seed, as before" "$(cat "$rc/bundle.1")" "return x / 2;"
printf '=== REQUEST ===\nabout half\n=== REQUEST ===\nMake double add the number to itself instead of multiplying.\n' > "$d/change-twice.txt"
rp=$(bigrepo); rc=$(newrc); w="$d/w-twice"; printf '%s\n' "$DOUBLE" > "$rc/reply.1"
out=$(req="$d/change-twice.txt"; run "$rp" "$rc" "$w" refactor --attempts 1 --max-bundle 3500); expect "framed: the last mark is the one: verdict" "$(verdict "$out")" done
hasnt "framed: the last mark is the one" "$(cat "$rc/bundle.1")" "return x / 2;"

# ---- names between backticks are the names (src/selection.cho, `quoted`) ----------------------------------------------------------------------
# the request says `double` between backticks and uses the words half and perimeter in passing: only double is a seed
printf 'Make `double` add the number to itself instead of multiplying. It is not half of the perimeter.\n' > "$d/change-ticks.txt"
rp=$(bigrepo); rc=$(newrc); w="$d/w-ticks"; printf '%s\n' "$DOUBLE" > "$rc/reply.1"
out=$(req="$d/change-ticks.txt"; run "$rp" "$rc" "$w" refactor --attempts 1 --max-bundle 3500); expect "backticks: verdict" "$(verdict "$out")" done
b=$(cat "$rc/bundle.1")
has "backticks: the name between backticks is shown in full" "$b" "    return x * 2;"
hasnt "backticks: a plain word of the same request names nothing" "$b" "return x / 2;"
# backticks around something the repository does not have decide nothing: the plain words name, as before
printf 'Make double add the number to itself (`x + x`) instead of multiplying. It is not half of the perimeter.\n' > "$d/change-ticks-none.txt"
rp=$(bigrepo); rc=$(newrc); w="$d/w-ticks-none"; printf '%s\n' "$DOUBLE" > "$rc/reply.1"
out=$(req="$d/change-ticks-none.txt"; run "$rp" "$rc" "$w" refactor --attempts 1 --max-bundle 6000); expect "backticks that name nothing: verdict" "$(verdict "$out")" done
b=$(cat "$rc/bundle.1")
has "backticks that name nothing: a plain word still names" "$b" "    return x * 2;"
has "backticks that name nothing: every plain word, as before" "$b" "return x / 2;"
# a file named beside a declaration says where: it does not make a seed of everything in the file
printf 'In `src/mathx.cho`, make `double` add the number to itself instead of multiplying.\n' > "$d/change-ticks-file.txt"
rp=$(bigrepo); rc=$(newrc); w="$d/w-ticks-file"; printf '%s\n' "$DOUBLE" > "$rc/reply.1"
out=$(req="$d/change-ticks-file.txt"; run "$rp" "$rc" "$w" refactor --attempts 1 --max-bundle 3500); expect "a file beside a name: verdict" "$(verdict "$out")" done
b=$(cat "$rc/bundle.1")
has "a file beside a name: the name is shown in full" "$b" "    return x * 2;"
hasnt "a file beside a name: the rest of the file is not" "$b" "return x / 2;"
# a file between backticks with no declaration beside it names all of the file, as before
printf 'In `src/mathx.cho`, doubling is to add the number to itself instead of multiplying.\n' > "$d/change-ticks-fileonly.txt"
rp=$(bigrepo); rc=$(newrc); w="$d/w-ticks-fileonly"; printf '%s\n' "$DOUBLE" > "$rc/reply.1"
out=$(req="$d/change-ticks-fileonly.txt"; run "$rp" "$rc" "$w" refactor --attempts 1 --max-bundle 6000); expect "a file alone: verdict" "$(verdict "$out")" done
has "a file alone between backticks: all of it is shown" "$(cat "$rc/bundle.1")" "return x / 2;"
# a backtick left open ends with its line
printf 'See `double of the number.\nMake `half` exact.\n' > "$d/change-ticks-open.txt"
rp=$(bigrepo); rc=$(newrc); w="$d/w-ticks-open"; printf '%s\n' "$DOUBLE" > "$rc/reply.1"
out=$(req="$d/change-ticks-open.txt"; run "$rp" "$rc" "$w" refactor --attempts 1 --max-bundle 3500)
has "an open backtick ends with its line: the span of the next line is whole" "$(cat "$rc/bundle.1")" "return x / 2;"

# static: the driver never runs git
code=$(grep -v '^[[:space:]]*//' "$SRC/repochange.cho" "$SRC/selection.cho" "$SRC/textedges.cho" "$SRC/change.cho" | grep -E 'git (push|commit|add|checkout|clone|apply|fetch)|"git |/git ' | head -3)
expect "static: no git in the driver" "$code" ""

[ $fail -eq 0 ] && echo "repo.patch gate: ok"
exit $fail
