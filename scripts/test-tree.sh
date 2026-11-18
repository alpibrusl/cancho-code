#!/bin/sh
# The module-tree gate (docs/hierarchical.md, issue #76): `treecheck` on one fixture per rule (tests/trees), with the rule and the node of every
# [TREE_ERROR] line asserted in order, the verdict and the exit code. tests/trees/expected.txt is the table: name, allowed authority ("-" for
# none), exit code, then rule:node pairs. Also: a valid tree prints its summary and `[TREE]<TAB>valid`; every error line has four fields; the
# usage cases exit 2.
#
#   scripts/test-tree.sh --mutants   prove the gate can fail: a copy of src/tree.cho with one rule broken must be RED, for every rule
set -u

if [ "${1:-}" = "--mutants" ]; then
    work=$(mktemp -d -t cc-tree-mut-XXXXXX)
    trap 'rm -rf "$work"' EXIT
    root=$(cd "$(dirname "$0")/.." && pwd)
    python3 - "$root/src/tree.cho" "$work" <<'PY' || exit 1
import sys
src, work = sys.argv[1:3]
text = open(src).read()
M = [
 ("coverage", "if !claimed && len(rid) > 0 {", "if false {"),
 ("cycle", "if done[k] == 0 && !reported {", "if false {"),
 ("unknown-dep", 'if find_id(src, tape, sibs, d) < 0 {\n                    b = note(heap, b, "unknown-dep"', 'if false {\n                    b = note(heap, b, "unknown-dep"'),
 ("interface-order", "&& !arr_has(src, tape, deps, prov) {", "&& false {"),
 ("authority", "} else if !list_has(allow, c) {", "} else if false {"),
 ("authority-widens", 'depth == 2 && !arr_has(src, tape, strs_field(src, tape, parent, "needs"), c)', "false"),
 ("unknown-capability", "if !list_has(capabilities(), c) {", "if false {"),
 ("sub-claims", '} else if !arr_has(src, tape, strs_field(src, tape, parent, "claims"), c) {', "} else if false {"),
 ("unknown-claim", 'if find_id(src, tape, json.get(src, tape, 0, "requirements"), c) < 0 {', "if false {"),
 ("empty-claims", "if json.count(tape, claims) == 0 {", "if false {"),
 ("fan-out", "fn fan_max() -> [] int { return 8; }", "fn fan_max() -> [] int { return 80; }"),
 ("leaf-size", "fn leaf_max() -> [] int { return 12; }", "fn leaf_max() -> [] int { return 120; }"),
 ("total-units", "fn units_max() -> [] int { return 60; }", "fn units_max() -> [] int { return 600; }"),
 ("too-deep", "} else if depth == 2 {\n        b = note(heap, b, \"too-deep\"", "} else if depth == 3 {\n        b = note(heap, b, \"too-deep\""),
 ("duplicate-module", "if module_node(src, tape, id) != m {", "if false {"),
 ("interface-unused", "if !used {", "if false {"),
 ("interface-self", "if bytes.equal(prov, id) {", "if false {"),
 ("unknown-provider", "if find_id(src, tape, mods, prov) < 0 {", "if false {"),
 ("unknown-interface", "if q < 0 {\n            b = note(heap, b, \"unknown-interface\"", "if false {\n            b = note(heap, b, \"unknown-interface\""),
 ("duplicate-interface", "if find_id(src, tape, ifaces, id) != i {", "if false {"),
 ("requirement-dup", "} else if find_id(src, tape, reqs, id) != i {", "} else if false {"),
]
import os
bad = 0
for name, a, b in M:
    if text.count(a) != 1:
        print("FAIL: mutant %s: the text to change occurs %d times" % (name, text.count(a)), file=sys.stderr); bad = 1; continue
    os.makedirs("%s/%s" % (work, name))
    open("%s/%s/tree.cho" % (work, name), "w").write(text.replace(a, b))
sys.exit(bad)
PY
    fail=0
    for d in "$work"/*/; do
        name=$(basename "$d")
        TREE_SRC="$d" sh "$0" >"$work/$name.out" 2>&1; rc=$?
        if [ "$rc" = 0 ]; then
            echo "FAIL: mutant $name survived: the gate passed on a broken tree.cho" >&2; fail=1
        elif [ "$rc" != 1 ]; then
            echo "FAIL: mutant $name: exit $rc, not a red verdict (the copy did not build?)" >&2; fail=1
        else
            echo "ok: mutant $name is red"
        fi
    done
    [ "$fail" = 0 ] && echo "tree mutants: all red"
    exit "$fail"
fi

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
SRC="${TREE_SRC:-$root/src}"   # a directory to take src/ from: how the mutation runs judge a broken copy
exe=$(mktemp -t cc-tree-XXXXXX)
"$CANCHO" build "$root/tests/programs/treecheck.cho" "$SRC/tree.cho" --std -o "$exe" >/dev/null 2>"$exe.err" \
    || { cat "$exe.err" >&2; echo "gate did not build" >&2; exit 2; }

fail=0
expect() { [ "$2" = "$3" ] || { echo "FAIL: $1: wanted '$3', got '$2'" >&2; fail=1; }; }

grep -v '^#' "$root/tests/trees/expected.txt" | grep -v '^$' > "$exe.table"
while IFS= read -r line; do
    name=$(printf '%s' "$line" | awk '{print $1}')
    allow=$(printf '%s' "$line" | awk '{print $2}')
    want_rc=$(printf '%s' "$line" | awk '{print $3}')
    want=$(printf '%s' "$line" | awk '{ s = ""; for (i = 4; i <= NF; i++) s = s (i > 4 ? " " : "") $i; print s }')
    [ "$allow" = "-" ] && allow=""
    out=$("$exe" "$root/tests/trees/$name.json" "$allow" 2>&1); rc=$?
    expect "$name: exit code" "$rc" "$want_rc"
    got=$(printf '%s\n' "$out" | grep '^\[TREE_ERROR\]' | awk -F'\t' '{print $2 ":" $3}' | tr '\n' ' ' | sed 's/ $//')
    expect "$name: errors" "$got" "$want"
    printf '%s\n' "$out" | grep '^\[TREE_ERROR\]' | while IFS= read -r e; do
        n=$(printf '%s' "$e" | awk -F'\t' '{print NF}'); m=$(printf '%s' "$e" | awk -F'\t' '{print $4}')
        [ "$n" = 4 ] && [ -n "$m" ] || { echo "FAIL: $name: malformed error line: $e" >&2; exit 1; }
    done || fail=1
    if [ "$want_rc" = 0 ]; then
        expect "$name: verdict" "$(printf '%s\n' "$out" | tail -1)" "$(printf '[TREE]\tvalid')"
    else
        expect "$name: verdict" "$(printf '%s\n' "$out" | tail -1)" "$(printf '[TREE]\tinvalid')"
    fi
done < "$exe.table"

expect "valid: summary" "$("$exe" "$root/tests/trees/valid.json" fs_write | head -1)" "$(printf '[TREE_SUMMARY]\tmodules=2\tunits=11\tdepth=1')"
expect "valid-depth2: summary" "$("$exe" "$root/tests/trees/valid-depth2.json" fs_write | head -1)" "$(printf '[TREE_SUMMARY]\tmodules=4\tunits=18\tdepth=2')"
"$exe" >/dev/null 2>&1; expect "usage: no argument" "$?" 2
"$exe" "$root/tests/trees/nothing-here.json" >/dev/null 2>&1; expect "usage: no file" "$?" 2

rm -f "$exe" "$exe.err" "$exe.table"
[ "$fail" = 0 ] && echo "tree gate: ok"
exit "$fail"
