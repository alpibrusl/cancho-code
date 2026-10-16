#!/bin/sh
# The dashboard gate (docs/dashboard.md, docs/parity.md P12): `board <run dir> <board.json> [prices.json]` turns a run directory
# into ONE json file, read-only; docs/board.html shows it.
#
#   scripts/test-board.sh             the gate
#   scripts/test-board.sh --mutants   prove the gate can fail: broken copies of src/board.cho and of docs/board.html must each be RED
#
#   CANCHO     the compiler (default: cancho on PATH)
#   BOARD_SRC  the source of the tool to judge (default: src/board.cho); how --mutants judges a broken copy
#   BOARD_PAGE the page to judge (default: docs/board.html); the same, for the page's logic
#
# What it asserts (a stuck run whose unit failed because the agent gave up, `stuck-agent`, renders in the Stuck column with its `agent:gave-up:cut-off` trail; the journal: fixtures journal, journal-killed, journal-gaps, and a big one made here)
#   - for each fixture run directory under tests/board/ (a done run, a stuck run with refusal history, a run mid-build,
#     a regressed unit, a directory with most files missing, no run.log, an empty directory, and junk), the tool's board.json
#     equals tests/board/expected/<name>.json (compared as JSON, key order free) and also the independent oracle
#     tests/reference/board_ref.py;
#   - on the real fixtures the numbers agree with eval/metrics.py (cost, tokens, shares, efficiency), within rounding;
#   - the run directory is byte-identical (contents, names, mtimes) after the tool ran: it never writes there, and an output
#     path inside the run directory is refused (exit 2) and writes nothing;
#   - usage errors exit 2; a plan found through run.json's `plan` path gives the same board as plan.json beside it;
#   - docs/board.html has the detail panel (dialog, Escape) and the Story view; `--retry`/`--hint` appear in it ONLY in the one marked note that tells
#     a person how to continue a stuck unit (docs/build.md): the note is shown for a stuck unit only, its text is built from board.json's run (brief,
#     provider, model) with a placeholder for what the board cannot know, and a value that is not a plain word is never put in it (run under node
#     when there is one); the board still runs nothing;
#   - the graph and the timeline (docs/dashboard.md): the page's pure logic (the block between the graph-logic markers in
#     docs/board.html: layers, critical path, node placement, timeline rows, the estimate) is run under node, without a browser, on the
#     boards of every fixture, on plans of 1 to 256 units made here, and on odd plans (cycle, unknown dependency, duplicate ids), and
#     compared with the oracle (tests/reference/board_ref.py --layout) and with hand-written expectations (tests/board/expected/
#     page-logic.json); with no node the step is skipped and says so;
#   - a run of a plan with files (fixture multi-file): each unit's `file` is in board.json (only for a plan that has files, so every other board is as it was),
#     the unit being built is read from `<file>.trail.jsonl`; the card, the node and the drawer of the page show it;
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
    mutant() { mutate "$root/src/board.cho" "$work/$1.cho" BOARD_SRC "$@"; }
    pmutant() { mutate "$root/docs/board.html" "$work/$1.html" BOARD_PAGE "$@"; }
    mutate() {
        file=$1; dst=$2; var=$3; name=$4; from=$5; to=$6
        grep -q "// MUTANT:$name" "$file" || { echo "FAIL: no marker MUTANT:$name in $file" >&2; fail=1; return; }
        python3 - "$file" "$dst" "$name" "$from" "$to" <<'PY' || { echo "FAIL: mutant $name: the marked line does not contain the text to change" >&2; fail=1; return; }
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
        if env "$var=$dst" sh "$0" >"$work/$name.out" 2>&1; then
            echo "FAIL: mutant $name survived: the gate passed on a broken $var" >&2; fail=1
        else
            echo "ok: mutant $name is red ($(grep -c '^FAIL' "$work/$name.out") failures)" >&2
        fi
    }
    mutant column  'col_stuck()' 'col_verified()'          # a failed unit is put in the Verified column
    mutant cost    'n_in * tier_in' 'n_in * tier_out'            # the input tokens are priced as output tokens
    mutant refuse  'inside(out, wd)' 'false'               # an output path inside the run directory is no longer refused
    mutant blobcap 'return 32768' 'return 300000'          # a blob is inlined whole, past the cap
    mutant order   'let ix = k;' 'let ix = n - 1 - k;'      # the journal's events come out last first
    mutant partial 'cells[j_partial()] = 1;' 'cells[j_skipped()] = cells[j_skipped()] + 1;'   # a half-written last line is counted as a bad line
    mutant traverse '|| bytes.find(name, "..") >= 0' '|| false'   # a blob name with .. is read
    mutant ufile   'b = key(heap, b, "file");' 'b = key(heap, b, "files");'   # the unit's module file is under another name: the page and the fixture lose it
    # the page's logic (node): each edit breaks one function of the block between the graph-logic markers
    if command -v node >/dev/null 2>&1; then
        pmutant layer    'layer[v] + 1' 'layer[v]'                          # a unit is put in the layer of its dependency, not after it
        pmutant critical 'if (b > best)' 'if (b < best)'                    # the critical path is the shortest chain, not the longest
        pmutant bar      'x0 = x - ms' 'x0 = x'                             # an attempt's bar starts where it ends: its time is lost
        pmutant attemptno 'n: isNum(e.n) ? e.n : null' 'n: 0'               # every bar opens attempt 0
        pmutant unknown  'if (ix[d] === undefined) {' 'if (false) {'       # an unknown dependency is no longer told apart
        pmutant cycle    'unplaced: unplaced, ok: ok' 'unplaced: [], ok: true'   # a cycle is drawn as a plan
        pmutant saved    'X - c.total' 'X + c.total'                        # the bound on what parallel units could save grows with the critical path
    else
        echo "note: no node on PATH: the page-logic mutants were not run" >&2
    fi
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

# ---- the journal: bounded blobs (a blob is cut at the cap on a character boundary; the total is bounded; the rest is marked) ----------------
mkdir -p "$work/big/journal/blobs"
python3 - "$work/big" <<'PY'
import json, os, sys
d = sys.argv[1]
b = os.path.join(d, "journal", "blobs")
open(os.path.join(b, "multi.txt"), "wb").write(b"a" * 32767 + "\u00e9".encode() + b"b" * 7000)   # the cap falls inside the 2-byte character
ev = [{"t_ms": 0, "kind": "attempt", "unit": "u", "n": 0, "reply": "multi.txt"}]
for i in range(70):
    open(os.path.join(b, "f%d.txt" % i), "wb").write(("%02d" % i).encode() + b"x" * 29998)
    ev.append({"t_ms": i + 1, "kind": "attempt", "unit": "u", "n": i + 1, "reply": "f%d.txt" % i})
open(os.path.join(d, "journal", "events.jsonl"), "w").write("".join(json.dumps(e) + "\n" for e in ev))
open(os.path.join(d, "run.log"), "w").write("[UNIT]\tu\tbuilding\n")
PY
before=$(tree "$work/big")
"$exe" "$work/big" "$work/big.json" "$prices" >/dev/null 2>&1; expect "big journal: exit code" "$?" 0
expect "big journal: the run directory is byte-identical afterwards" "$(tree "$work/big")" "$before"
python3 "$root/tests/reference/board_ref.py" "$work/big" "$prices" > "$work/big.ref.json"
norm "$work/big.json" > "$work/big.got"; norm "$work/big.ref.json" > "$work/big.want"
diff -q "$work/big.want" "$work/big.got" >/dev/null || bad "big journal: board.json differs from the oracle"
python3 - "$work/big.json" <<'PY' || fail=1
import json, os, sys
raw = open(sys.argv[1], "rb").read()
j = json.loads(raw)["journal"]
bl, bad = j["blobs"], []
m = bl["multi.txt"]
if not (m["truncated"] and m["bytes"] == 39769 and len(m["text"]) == 32767 and m["text"].endswith("a")):
    bad.append("multi.txt: wanted cut at the character boundary before the cap, got truncated=%s bytes=%s chars=%s" % (m["truncated"], m["bytes"], len(m["text"])))
kept = sum(len(v["text"].encode()) for v in bl.values() if v and "text" in v)
if kept > j["limits"]["total_bytes"]:
    bad.append("the blobs kept are %d bytes, more than the budget %d" % (kept, j["limits"]["total_bytes"]))
if j["blobs_omitted"] < 1 or not any(v == {"omitted": True} for v in bl.values()):
    bad.append("no blob was marked omitted although the budget was exceeded")
if len(raw) > j["limits"]["total_bytes"] + 262144:
    bad.append("board.json is %d bytes: not bounded by the budget" % len(raw))
if [e["n"] for e in j["events"]] != list(range(71)) and [e.get("n") for e in j["events"]][1:] != list(range(1, 71)):
    bad.append("events are not in file order")
for x in bad:
    print("FAIL: big journal: " + x, file=sys.stderr)
sys.exit(1 if bad else 0)
PY

# ---- the page ----------------------------------------------------------------------------------------------------------------------
page="${BOARD_PAGE:-$root/docs/board.html}"
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
    # the detail panel: a dialog, closed by Escape, with the journal's missing parts said out loud and no way to act on a unit
    grep -q 'role="dialog"' "$page" || bad "docs/board.html has no detail panel (role=dialog)"
    grep -q "Escape" "$page" || bad "docs/board.html: the detail panel does not close on Escape"
    grep -q "not recorded" "$page" || bad "docs/board.html does not say 'not recorded' for what the journal lacks"
    grep -q 'id="view-story"' "$page" || bad "docs/board.html has no Story view"
    # `--retry` and `--hint` are named by the page in exactly one place: the note between the retry-note markers
    expect "docs/board.html: one retry note (begin marker)" "$(grep -c 'retry-note:begin' "$page")" 1
    expect "docs/board.html: one retry note (end marker)" "$(grep -c 'retry-note:end' "$page")" 1
    first=$(grep -n 'retry-note:begin' "$page" | head -1 | cut -d: -f1); last=$(grep -n 'retry-note:end' "$page" | head -1 | cut -d: -f1)
    [ -n "$first" ] && [ -n "$last" ] || { first=0; last=0; }
    grep -nE -- '--retry|--hint' "$page" | cut -d: -f1 >"$work/retry.lines"
    [ -s "$work/retry.lines" ] || bad "docs/board.html does not show the command to retry a stuck unit"
    while read -r ln; do
        { [ "$ln" -gt "$first" ] && [ "$ln" -lt "$last" ]; } || bad "docs/board.html names --retry/--hint outside the retry note (line $ln)"
    done < "$work/retry.lines"
    grep -q 'if (u.column === "stuck") body.appendChild(retryNote(' "$page" || bad "docs/board.html: the retry note is not shown for a stuck unit only"
    [ "$(grep -c 'retryNote(' "$page")" = 2 ] || bad "docs/board.html: the retry note is built in more than one place"
    if command -v node >/dev/null 2>&1; then
        sed -n "$((first + 1)),$((last - 1))p" "$page" > "$work/retry-note.js"
        node - "$work/retry-note.js" "$root/tests/board/expected/stuck.json" "$root/tests/board/expected/continued.json" <<'JS' || fail=1
const fs = require("fs");
const code = fs.readFileSync(process.argv[2], "utf8");
const retryCommand = new Function(code + "; return retryCommand;")();
const stuck = JSON.parse(fs.readFileSync(process.argv[3], "utf8")), cont = JSON.parse(fs.readFileSync(process.argv[4], "utf8"));
const want = [
  [retryCommand(stuck.run, "parse"), 'build <checker> <brief.txt> <workdir> <agent-command> --provider anthropic --model claude-haiku-5-5 --retry parse --hint "<what you know about this unit>"'],
  [retryCommand(cont.run, "parse"), 'build <checker> /runs/tokens/brief.txt <workdir> <agent-command> --provider anthropic --model claude-haiku-5-5 --retry parse --hint "<what you know about this unit>"'],
  [retryCommand({ brief: "x; rm -rf /", provider: "a b", model: "$(id)" }, "u"), 'build <checker> <brief.txt> <workdir> <agent-command> --provider <provider> --model <model> --retry u --hint "<what you know about this unit>"'],
  [retryCommand(null, "u"), 'build <checker> <brief.txt> <workdir> <agent-command> --provider <provider> --model <model> --retry u --hint "<what you know about this unit>"'],
];
let bad = 0;
for (const [got, w] of want) if (got !== w) { console.error("FAIL: retry note: wanted\n  " + w + "\ngot\n  " + got); bad = 1; }
process.exit(bad);
JS
    else
        echo "note: no node on PATH: the retry note's text was not run" >&2
    fi
    # it only reads: no way to send anything anywhere
    grep -nE "method: *['\"](POST|PUT|DELETE|PATCH)|XMLHttpRequest|sendBeacon|WebSocket|\.send\(|localStorage|sessionStorage|document\.cookie|<form" "$page" >"$work/write" && { bad "docs/board.html has a write path:"; head -5 "$work/write" >&2; }
    # the graph and the timeline: two more views, each with its place in the page; the logic sits in ONE marked block of pure functions
    grep -q 'id="view-graph"' "$page" || bad "docs/board.html has no Graph view"
    grep -q 'id="view-timeline"' "$page" || bad "docs/board.html has no Timeline view"
    grep -q 'id="tab-graph"' "$page" && grep -q 'id="tab-timeline"' "$page" || bad "docs/board.html: the Graph and Timeline views have no tab"
    grep -q 'not a DAG' "$page" || bad "docs/board.html does not say when the dependencies are not a DAG"
    grep -q 'setAttribute("tabindex", "0")' "$page" && grep -q 'setAttribute("role", "button")' "$page" || bad "docs/board.html: the graph's nodes are not keyboard accessible (tabindex, role=button)"
    grep -q '"Enter"' "$page" || bad "docs/board.html: a graph node does not open on Enter"
    grep -q 'marker-end' "$page" || bad "docs/board.html: the graph's edges have no arrowheads"
    grep -qi 'Estimate' "$page" || bad "docs/board.html: the timeline has no estimate line"
    expect "docs/board.html: one graph-logic block (begin)" "$(grep -c 'graph-logic:begin' "$page")" 1
    expect "docs/board.html: one graph-logic block (end)" "$(grep -c 'graph-logic:end' "$page")" 1
    gfirst=$(grep -n 'graph-logic:begin' "$page" | head -1 | cut -d: -f1); glast=$(grep -n 'graph-logic:end' "$page" | head -1 | cut -d: -f1)
    [ -n "$gfirst" ] && [ -n "$glast" ] || { gfirst=0; glast=0; }
    sed -n "$((gfirst + 1)),$((glast - 1))p" "$page" > "$work/graph-logic.js"
    [ -s "$work/graph-logic.js" ] || bad "docs/board.html: the graph-logic block is empty"
    # pure: nothing in it touches the page, the network or the clock
    grep -nE 'document|window|location|fetch\(|\$\(|Date|Math\.random|innerHTML|setTimeout|setInterval' "$work/graph-logic.js" >"$work/impure" && { bad "docs/board.html: the graph-logic block is not pure:"; head -5 "$work/impure" >&2; }
    # the module file of a unit (docs/multi-file.md) is on its card, in its drawer and on its graph node
    grep -q 'el("span", "chip file", u.file)' "$page" || bad "docs/board.html: a card does not show the unit's file"
    grep -q 'chip("file", u.file)' "$page" || bad "docs/board.html: the unit panel does not show the unit's file"
    grep -q '" in " + u.file' "$page" && grep -q 'u.function + (u.file' "$page" || bad "docs/board.html: a graph node does not show the unit's file"
    # the Timeline is a drawing of the journal: no way to write it either way, and a 'parallel' flag is not offered (units run one after another today)
    grep -nEi -- '--parallel|--jobs|--concurren' "$page" >"$work/par" && { bad "docs/board.html suggests a flag for parallel units:"; head -3 "$work/par" >&2; }
    if command -v node >/dev/null 2>&1; then
        mkdir -p "$work/pl"
        for f in "$work"/graph-*.json "$work"/journal.json "$work"/stuck.json "$work"/done.json "$work"/continued.json "$work"/journal-gaps.json "$work"/journal-killed.json \
                 "$work"/missing.json "$work"/regressed.json "$work"/building.json "$work"/nolog.json "$work"/big.json; do
            [ -f "$f" ] || continue
            n=$(basename "$f" .json)
            cp "$f" "$work/pl/$n.json"
            python3 "$root/tests/reference/board_ref.py" --layout "$f" > "$work/pl/$n.layout.json" || bad "$n: the oracle could not lay the board out"
        done
        # the boards on the landing page (made before the graph existed) lay out too
        for f in "$root"/docs/demo/*.json; do
            [ -f "$f" ] || continue
            n="demo-$(basename "$f" .json)"
            cp "$f" "$work/pl/$n.json"
            python3 "$root/tests/reference/board_ref.py" --layout "$f" > "$work/pl/$n.layout.json" || bad "$n: the oracle could not lay the board out"
        done
        # plans of 1 to 256 units, made here: a chain, a wide one, a layered one, a diamond lattice; and 300 units (the tool keeps 256)
        python3 - "$work" <<'PY'
import json, os, random, sys
w = sys.argv[1]
def plan(name, n, deps):
    d = os.path.join(w, "sz-" + name)
    os.makedirs(d)
    units = [{"id": "u%d" % i, "signature": "fn f%d[&r](x: &r [byte]) -> [] bool" % i, "examples": [], "deps": deps(i)} for i in range(n)]
    open(os.path.join(d, "plan.json"), "w").write(json.dumps({"name": name, "units": units}))
    log = ["[PLAN]\tvalid"]
    for i in range(min(n, 40)):
        log += ["[UNIT]\tu%d\tbuilding" % i, "[UNIT]\tu%d\tverified" % i]
        open(os.path.join(d, "trail-u%d.jsonl" % i), "w").write(json.dumps({"attempt": 0, "agent_ms": 1000 + 37 * i, "outcome": "verified", "sig": "", "decision": "verified"}) + "\n")
    open(os.path.join(d, "run.log"), "w").write("\n".join(log) + "\n")
rnd = random.Random(3)
plan("one", 1, lambda i: [])
plan("chain", 256, lambda i: ["u%d" % (i - 1)] if i else [])
plan("wide", 256, lambda i: [])
plan("mesh", 256, lambda i: ["u%d" % (i - k) for k in (1, 2, 3, 7) if i - k >= 0])
plan("rand", 256, lambda i: ["u%d" % j for j in sorted(rnd.sample(range(i), min(i, rnd.choice([0, 1, 2, 4]))))])
plan("over", 300, lambda i: ["u%d" % (i - 1)] if i else [])
PY
        for d in "$work"/sz-*/; do
            n=$(basename "$d")
            "$exe" "$d" "$work/pl/$n.json" "$prices" >/dev/null 2>&1 || { bad "$n: the tool failed on a plan of this size"; continue; }
            python3 "$root/tests/reference/board_ref.py" --layout "$work/pl/$n.json" > "$work/pl/$n.layout.json"
        done
        expect "300 units: the tool keeps 256" "$(python3 -c 'import json,sys; b=json.load(open(sys.argv[1])); print(len(b["units"]), b["truncated"])' "$work/pl/sz-over.json")" "256 True"
        node "$root/tests/board/page-logic.test.js" "$work/graph-logic.js" "$work/pl" "$root/tests/board/expected/page-logic.json" || fail=1
    else
        echo "note: no node on PATH: the page's graph and timeline logic was not run (only its text was checked)" >&2
    fi
    # one static file: no build step
    grep -qE 'require\(|import .* from |webpack|node_modules' "$page" && bad "docs/board.html needs a build step"
fi

[ "$fail" = 0 ] && echo "test-board: ok" >&2
exit $fail
