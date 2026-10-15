#!/bin/sh
# The dashboard gate (docs/dashboard.md, docs/parity.md P12): `board <run dir> <board.json> [prices.json]` turns a run directory
# into ONE json file, read-only; docs/board.html shows it.
#
#   scripts/test-board.sh             the gate
#   scripts/test-board.sh --mutants   prove the gate can fail: three broken copies of src/board.cho must each be RED
#
#   CANCHO     the compiler (default: cancho on PATH)
#   BOARD_SRC  the source of the tool to judge (default: src/board.cho); how --mutants judges a broken copy
#
# What it asserts
#   - for each fixture run directory under tests/board/ (a done run, a stuck run with refusal history, a run mid-build,
#     a regressed unit, a directory with most files missing, no run.log, an empty directory, and junk), the tool's board.json
#     equals tests/board/expected/<name>.json (compared as JSON, key order free) and also the independent oracle
#     tests/reference/board_ref.py;
#   - on the real fixtures the numbers agree with eval/metrics.py (cost, tokens, shares, efficiency), within rounding;
#   - the run directory is byte-identical (contents, names, mtimes) after the tool ran: it never writes there, and an output
#     path inside the run directory is refused (exit 2) and writes nothing;
#   - usage errors exit 2; a plan found through run.json's `plan` path gives the same board as plan.json beside it;
#   - docs/board.html makes no request to another host, has no build step, no write path, reads board.json and offers a file picker.
set -u

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
src="${BOARD_SRC:-$root/src/board.cho}"

if [ "${1:-}" = "--mutants" ]; then
    work=$(mktemp -d -t cc-board-mut-XXXXXX)
    trap 'rm -rf "$work"' EXIT
    fail=0
    # Each mutation is one edit of the source; the gate on the broken copy must fail. Every edit is anchored on a marker
    # comment in src/board.cho (`// MUTANT:<name>`) so that a refactor which loses the line is itself a red.
    mutant() {
        name=$1; from=$2; to=$3
        grep -q "// MUTANT:$name" "$root/src/board.cho" || { echo "FAIL: no marker MUTANT:$name in src/board.cho" >&2; fail=1; return; }
        python3 - "$root/src/board.cho" "$work/$name.cho" "$name" "$from" "$to" <<'PY' || { echo "FAIL: mutant $name: the marked line does not contain the text to change" >&2; fail=1; return; }
import sys
src, dst, name, a, b = sys.argv[1:6]
out, hit = [], 0
for line in open(src).read().split("\n"):
    if "// MUTANT:" + name in line:
        if a not in line:
            sys.exit(1)
        line, hit = line.replace(a, b), hit + 1
    out.append(line)
sys.exit(0 if hit == 1 and open(dst, "w").write("\n".join(out)) else 1)
PY
        if BOARD_SRC="$work/$name.cho" sh "$0" >"$work/$name.out" 2>&1; then
            echo "FAIL: mutant $name survived: the gate passed on a broken tool" >&2; fail=1
        else
            echo "ok: mutant $name is red ($(grep -c '^FAIL' "$work/$name.out") failures)" >&2
        fi
    }
    mutant column  'col_stuck()' 'col_verified()'          # a failed unit is put in the Verified column
    mutant cost    'n_in * tier_in' 'n_in * tier_out'            # the input tokens are priced as output tokens
    mutant refuse  'inside(out, wd)' 'false'               # an output path inside the run directory is no longer refused
    exit $fail
fi

exe=$(mktemp -t cc-board-XXXXXX)
work=$(mktemp -d -t cc-board-work-XXXXXX)
trap 'rm -rf "$work" "$exe"' EXIT
"$CANCHO" build "$root/tests/programs/board.cho" "$src" "$root/src/plan.cho" \
    --std --backend cranelift -o "$exe" >"$work/build.log" 2>&1 || { cat "$work/build.log" >&2; echo "FAIL: the board tool did not build" >&2; exit 1; }

fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }
expect() { [ "$2" = "$3" ] || bad "$1: wanted '$3', got '$2'"; }

# A JSON file, canonical (sorted keys, one value per line), so two files are equal iff they hold the same JSON.
norm() { python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), indent=1, sort_keys=True))' "$1"; }
# The run directory as bytes, names and mtimes: one hash.
tree() {
    python3 - "$1" <<'PY'
import hashlib, os, sys
h = hashlib.sha256()
for d, dirs, files in os.walk(sys.argv[1]):
    dirs.sort()
    h.update(("D" + os.path.relpath(d, sys.argv[1]) + "\0" + str(os.stat(d).st_mtime_ns) + "\0").encode())
    for f in sorted(files):
        p = os.path.join(d, f)
        h.update(("F" + os.path.relpath(p, sys.argv[1]) + "\0" + str(os.stat(p).st_mtime_ns) + "\0").encode())
        h.update(open(p, "rb").read())
print(h.hexdigest())
PY
}
prices="$root/tests/board/prices.json"

# ---- each fixture: the tool, the golden file, the oracle -------------------------------------------------------------
for dir in "$root"/tests/board/*/; do
    name=$(basename "$dir")
    [ "$name" = expected ] && continue
    out="$work/$name.json"
    before=$(tree "$dir")
    "$exe" "$dir" "$out" "$prices" >"$work/$name.stdout" 2>"$work/$name.stderr"; rc=$?
    expect "$name: exit code" "$rc" 0
    after=$(tree "$dir")
    expect "$name: the run directory is byte-identical afterwards" "$after" "$before"
    if [ ! -f "$out" ]; then bad "$name: no board.json written"; continue; fi
    norm "$out" > "$work/$name.got" 2>"$work/$name.err" || { bad "$name: board.json is not JSON"; continue; }
    norm "$root/tests/board/expected/$name.json" > "$work/$name.want"
    diff -u "$work/$name.want" "$work/$name.got" > "$work/$name.diff" || { bad "$name: board.json differs from tests/board/expected/$name.json"; head -40 "$work/$name.diff" >&2; }
    python3 "$root/tests/reference/board_ref.py" "$dir" "$prices" > "$work/$name.ref.json"
    norm "$work/$name.ref.json" > "$work/$name.refn"
    diff -q "$work/$name.want" "$work/$name.refn" >/dev/null || bad "$name: the oracle (tests/reference/board_ref.py) no longer reproduces tests/board/expected/$name.json"
    [ -s "$work/$name.stdout" ] && bad "$name: the tool printed on stdout"
done

# ---- the numbers are eval/metrics.py's -------------------------------------------------------------------------------
for name in done stuck building regressed; do
    python3 "$root/eval/metrics.py" "$root/tests/board/$name" --prices "$prices" --json > "$work/$name.metrics.json" 2>/dev/null || { bad "$name: eval/metrics.py failed"; continue; }
    python3 - "$work/$name.metrics.json" "$work/$name.json" "$name" <<'PY' || fail=1
import json, sys
m, b, name = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), sys.argv[3]
bm = b["metrics"]
bad = []
def near(label, want, got, tol):
    if want is None or got is None:
        ok = want is None and got is None
    else:
        ok = abs(want - got) <= tol
    if not ok:
        bad.append("%s: eval/metrics.py says %s, the board says %s" % (label, want, got))
near("cost_usd", m["cost_usd"], bm["cost_usd"], 1e-9)
near("cost_per_verified_unit", m.get("cost_per_verified_unit"), bm["cost_per_verified_unit"], 1e-6)
for k in ("in", "out", "cache_write", "cache_read", "thinking"):
    near("tokens." + k, m["tokens"][k], bm["tokens"][k], 0)
near("visible_out", m["visible_out"], bm["visible_out"], 0)
near("thinking_share", m["thinking_share"], bm["thinking_share"], 1e-4)
near("efficiency", m["efficiency"], bm["efficiency"], 1.5e-4)
near("efficiency_calls", m["efficiency_calls"], bm["efficiency_calls"], 1.5e-4)
near("efficiency_visible", m["efficiency_visible"], bm["efficiency_visible"], 1.5e-4)
near("calls", m["calls"], bm["calls"], 0)
near("units_verified", m["units_verified"], bm["units_verified"], 0)
if b["run"]["verdict"] != m["project_verdict"] and not (b["run"]["verdict"] is None and m["project_verdict"] == ""):
    bad.append("verdict: %r vs %r" % (m["project_verdict"], b["run"]["verdict"]))
if m.get("audit") != bm["audit"]:
    bad.append("audit: %r vs %r" % (m.get("audit"), bm["audit"]))
cards = {u["id"]: u for u in b["units"]}
for uid, pu in m["per_unit"].items():
    c = cards.get(uid)
    if c is None:
        bad.append("unit %s is in eval/metrics.py and not on the board" % uid); continue
    near("unit %s cost" % uid, pu["cost"], c["cost_usd"], 1e-9)
    near("unit %s out" % uid, pu["out"], c["tokens"]["out"], 0)
    near("unit %s thinking" % uid, pu["thinking"], c["tokens"]["thinking"], 0)
for x in bad:
    print("FAIL: %s: %s" % (name, x), file=sys.stderr)
sys.exit(1 if bad else 0)
PY
done

# ---- no price table: the money is unknown, not zero ---------------------------------------------------------------------
"$exe" "$root/tests/board/done" "$work/noprices.json" >/dev/null 2>&1; expect "no prices: exit code" "$?" 0
expect "no prices: cost is null" "$(python3 -c 'import json,sys; b=json.load(open(sys.argv[1])); print(b["metrics"]["cost_usd"], b["units"][0]["cost_usd"], b["metrics"]["tokens"]["out"])' "$work/noprices.json")" "None None 9618"

# ---- the run directory is not written, even when asked ---------------------------------------------------------------------
cp -R "$root/tests/board/done" "$work/rd"
before=$(tree "$work/rd")
"$exe" "$work/rd" "$work/rd/board.json" "$prices" >/dev/null 2>&1; expect "output inside the run dir: exit code" "$?" 2
[ -e "$work/rd/board.json" ] && bad "output inside the run dir: the tool wrote into the run directory"
expect "output inside the run dir: directory unchanged" "$(tree "$work/rd")" "$before"
"$exe" "$work/rd/" "$work/rd/sub/../board.json" >/dev/null 2>&1; expect "output path with ..: exit code" "$?" 2
[ -e "$work/rd/board.json" ] && bad "output path with ..: wrote into the run directory"

# ---- usage ---------------------------------------------------------------------------------------------------------------------
"$exe" >/dev/null 2>&1; expect "usage: no argument" "$?" 2
"$exe" "$work/rd" >/dev/null 2>&1; expect "usage: no output file" "$?" 2
"$exe" "$work/../rd" "$work/o.json" >/dev/null 2>&1; expect "usage: .. in the run dir" "$?" 2
"$exe" "$work/rd" "$work/no-such-dir/o.json" >/dev/null 2>&1; expect "usage: output cannot be written" "$?" 1
"$exe" "$work/rd" "$work/o.json" "$work/no-such-prices.json" >/dev/null 2>&1; expect "a prices file that is not there is no prices, not an error" "$?" 0

# ---- the plan found through run.json ---------------------------------------------------------------------------------------------
mkdir -p "$work/elsewhere"
cp "$root/tests/board/done/plan.json" "$work/elsewhere/plan.json"
rm -f "$work/rd/plan.json"
python3 - "$work/rd/run.json" "$work/elsewhere/plan.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["plan"] = sys.argv[2]
json.dump(d, open(sys.argv[1], "w"))
PY
"$exe" "$work/rd" "$work/viajson.json" "$prices" >/dev/null 2>&1; expect "plan via run.json: exit code" "$?" 0
norm "$work/viajson.json" > "$work/viajson.got"
python3 - "$work/viajson.got" "$work/done.want" <<'PY' || bad "plan via run.json: the board differs from the one with plan.json beside it"
import json, sys
a, b = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
a["run"]["seconds"] = b["run"]["seconds"]
sys.exit(0 if a == b else 1)
PY

# ---- the page ----------------------------------------------------------------------------------------------------------------------
page="$root/docs/board.html"
if [ ! -f "$page" ]; then
    bad "docs/board.html does not exist"
else
    # no request to another host: no absolute URL at all, no protocol-relative one, no import, no external script or stylesheet
    grep -nE 'https?:|//[a-z0-9.-]+\.[a-z]{2,}|@import|<script[^>]*src=|<link[^>]*href=|<iframe|<img[^>]*src="[^d]' "$page" >"$work/ext" && { bad "docs/board.html refers to something outside the page:"; head -5 "$work/ext" >&2; }
    # it reads: fetches board.json (relative), has a file picker and drag-and-drop for file://
    grep -q 'fetch(' "$page" || bad "docs/board.html does not fetch board.json"
    grep -q 'board\.json' "$page" || bad "docs/board.html does not name board.json"
    grep -q 'type="file"' "$page" || bad "docs/board.html has no file picker"
    grep -q 'drop' "$page" || bad "docs/board.html has no drag-and-drop"
    grep -q 'prefers-color-scheme' "$page" || bad "docs/board.html does not follow the colour scheme"
    grep -q 'name="viewport"' "$page" || bad "docs/board.html has no viewport (phone width)"
    # it only reads: no way to send anything anywhere
    grep -nE "method: *['\"](POST|PUT|DELETE|PATCH)|XMLHttpRequest|sendBeacon|WebSocket|\.send\(|localStorage|sessionStorage|document\.cookie|<form" "$page" >"$work/write" && { bad "docs/board.html has a write path:"; head -5 "$work/write" >&2; }
    # one static file: no build step
    grep -qE 'require\(|import .* from |webpack|node_modules' "$page" && bad "docs/board.html needs a build step"
fi

[ "$fail" = 0 ] && echo "test-board: ok" >&2
exit $fail
