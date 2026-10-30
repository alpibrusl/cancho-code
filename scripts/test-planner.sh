#!/bin/sh
# The planner gate: `cancho-agent --mode plan` (src/cancho_agent.cho) asks a model for a PLAN (docs/plan.md) instead of a program, and the plan
# check (src/plan.cho, in process, no model) decides. Against a plain-HTTP stub that speaks Ollama's /api/generate, so no key, no GPU, no spend:
#
#   plan      a valid plan inside prose and a fence is written (the same plan as JSON, one newline after, units without `cases` untouched); one request; the prompt
#             holds the guide, the task and the required signatures
#   feedback  a rejected plan is not written; the NEXT request carries the plan check's own report and the rejected plan; a good second plan is written
#   brief names  a function the brief names (`- name(...) : ...`) that round 1 renames is refused IN THE ROUND, every missing name at once, with the exact action
#             (the text "declare fn <name> with exactly this name"); round 2 fixes it and is written; both rounds are in the journal
#   cases     a unit's `cases` (data) are expanded into its `tests` by src/cases.cho before the plan check; an expansion error is fed back like a plan-check error; the plan written has tests and no cases
#   fallback  a signature `cases` cannot express: the report says to delete the unit's cases and write tests (and which types cases can express); a plan that does is accepted; the guide's own tests example compiles, passes, and fails when a value is flipped
#   ceiling   every round rejected: exit 1, nothing written, the file that was there is untouched, the last report is on stderr
#   questions {"status":"unclear"} / {"status":"too_big"}: exit 3, the model's object is saved beside the output, no plan is written, one request
#   no json   prose without an object, and a reply cut off by the bound, are rounds that fail and are retried; neither is ever written
#   review    a second, blind pass; a case survives only if the reviewer re-derives it; "agreed with none" rejects the plan; a MISCOUNTED answer (a slip of the reviewer) is retried once, told what was wrong, and if it fails again the plan is kept UNREVIEWED and says so on stderr
#   cut off   a plan cut off by the bound is asked again with the bound doubled (at most 32000); an empty cut-off reply is told its thinking used the bound
#   usage     --usage-log records one line per call with the round's outcome (rejected | written | no_plan | cut_off | needs_input)
#   journal   --journal <dir> records every model call of the plan stage (docs/journal.md): one `plan_call` event per call with the prompt and the raw reply as
#             blobs, tokens, time, stop reason, outcome and what the checks refused; the primer once; a `plan_review` with the cases the reviewer dropped and why
#   required  no --guide / no --brief / no output path: exit 2 before any request
set -u
CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "no python3 on PATH" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
C="${CANCHO_PACKAGES:-}"
[ -d "$C" ] || C="$(dirname "$(dirname "$(dirname "$(command -v "$CANCHO")")")")/packages"
[ -d "$C" ] || { echo "no cancho packages found; set CANCHO_PACKAGES" >&2; exit 2; }
fail=0
expect() { [ "$2" = "$3" ] || { echo "FAIL: $1: wanted '$3', got '$2'" >&2; fail=1; }; }
d=$(mktemp -d -t cc-planner-XXXXXX)
exe="$d/agent"
"$CANCHO" build "$root/src/cancho_agent.cho" "$root/src/anthropic.cho" "$root/src/ollama.cho" "$root/src/prompt.cho" "$root/src/planprompt.cho" "$root/src/plan.cho" "$root/src/cases.cho" "$root/src/review.cho" "$root/src/splice.cho" "$root/src/provider.cho" "$root/src/reply.cho" "$root/src/calls.cho" "$root/src/memory.cho" "$root/src/signature.cho" \
    "$root/vendor/fetch_io.cho" "$C"/http-client/*.cho "$C"/tls/*.cho "$C"/x509/*.cho --std -o "$exe" >/dev/null 2>"$d/build.err" \
    || { cat "$d/build.err" >&2; echo "gate did not build" >&2; exit 2; }
"$CANCHO" build "$root/tests/programs/plancheck.cho" "$root/src/plan.cho" --std -o "$d/plancheck" >/dev/null 2>&1 || { echo "plancheck did not build" >&2; exit 2; }

cat > "$d/stub.py" <<'PY'
import http.server, json, sys
out = sys.argv[1]
n = 0
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        global n
        n += 1
        body = self.rfile.read(int(self.headers["Content-Length"]))
        open(out + "/request.%d.json" % n, "wb").write(body)
        open(out + "/count", "w").write(str(n))
        try: reply = open(out + "/response.%d.txt" % n).read()
        except OSError: reply = open(out + "/response.txt").read()
        try: reason = open(out + "/response.%d.reason" % n).read().strip()
        except OSError: reason = "stop"
        data = json.dumps({"response": reply, "done_reason": reason, "eval_count": 7, "prompt_eval_count": 9}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(data)))
        self.end_headers(); self.wfile.write(data)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(out + "/port", "w").write(str(s.server_address[1]))
s.serve_forever()
PY
start() { rm -f "$d/port" "$d/count" "$d"/request.*.json "$d"/response*; python3 "$d/stub.py" "$d" & stub=$!
          n=0; while [ ! -s "$d/port" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done; port=$(cat "$d/port")
          n=0; while ! python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 1).close()" 2>/dev/null && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done; }
stop() { kill $stub 2>/dev/null; wait $stub 2>/dev/null; }
count() { cat "$d/count" 2>/dev/null || echo 0; }
plan() { env -i CANCHO_AGENT_BIN="$exe" /bin/sh "$root/scripts/cancho-agent.sh" --provider ollama --model stub-model --port "$port" --mode plan "$@" "$d/out/plan.json"; }
prompt_of() { python3 -c "import json; print(json.load(open('$d/request.$1.json'))['prompt'])"; }

GOOD='{"name": "clampy", "units": [{"id": "clamp", "signature": "fn clampy(x: int, lo: int, hi: int) -> [] int", "description": "x limited to [lo, hi].", "examples": ["clampy(5, 1, 3) == 3"], "deps": []}]}'
BAD='{"name": "clampy", "units": [{"id": "clamp", "signature": "fn clampy(x: int, lo: int, hi: int) -> [] int", "examples": [], "deps": []}]}'
mkdir -p "$d/out"
printf '# Guide\nWrite a plan as JSON.\n' > "$d/guide.md"
printf 'Write clampy(x, lo, hi): limit x to [lo, hi].\n' > "$d/brief.txt"
printf 'fn clampy(x: int, lo: int, hi: int) -> [] int\n' > "$d/contract.txt"
G="--guide $d/guide.md --brief $d/brief.txt"

# plan
start; printf 'Here is the plan:\n```json\n%s\n```\nGood luck.\n' "$GOOD" > "$d/response.txt"; rm -f "$d/out/plan.json"
plan $G --contract "$d/contract.txt" >"$d/o" 2>"$d/e"; rc=$?
expect "plan: exit code ($(head -c 200 "$d/e"))" "$rc" 0
printf '%s\n' "$GOOD" > "$d/want.json"
same() { python3 -c "import json,sys; sys.exit(0 if json.load(open('$1')) == json.load(open('$2')) and open('$1').read().endswith('}\n') else 1)"; }
same "$d/out/plan.json" "$d/want.json" || { echo "FAIL: plan: the file is not the model's plan (as JSON) and one newline" >&2; fail=1; }
expect "plan: one request" "$(count)" 1
"$d/plancheck" "$d/out/plan.json" >/dev/null 2>&1 || { echo "FAIL: plan: the written plan does not pass plancheck" >&2; fail=1; }
P=$(prompt_of 1)
for want in "# Guide" "=== THE TASK ===" "limit x to [lo, hi]" "=== REQUIRED PUBLIC FUNCTIONS" "fn clampy(x: int, lo: int, hi: int) -> [] int" "Reply with the JSON object only"; do
    case "$P" in *"$want"*) ;; *) echo "FAIL: plan: the prompt lacks '$want'" >&2; fail=1 ;; esac
done
case "$P" in *REJECTED*) echo "FAIL: plan: the first prompt already talks of a rejection" >&2; fail=1 ;; esac
stop

# feedback: a rejected plan, then a good one
start; printf '%s' "$BAD" > "$d/response.1.txt"; printf 'Corrected:\n%s\n' "$GOOD" > "$d/response.2.txt"; rm -f "$d/out/plan.json" "$d/ulog"
plan $G --usage-log "$d/ulog" >/dev/null 2>"$d/e"; rc=$?
expect "feedback: exit code" "$rc" 0
expect "feedback: two requests" "$(count)" 2
same "$d/out/plan.json" "$d/want.json" || { echo "FAIL: feedback: the file is not the second, good plan" >&2; fail=1; }
P2=$(prompt_of 2)
for want in "REJECTED" "no-example" "$BAD" "Reply again with the corrected JSON object only"; do
    case "$P2" in *"$want"*) ;; *) echo "FAIL: feedback: the second prompt lacks '$want'" >&2; fail=1 ;; esac
done
expect "feedback: usage outcomes" "$(python3 -c "import json; print([json.loads(l)['outcome'] for l in open('$d/ulog')])")" "['rejected', 'written']"
stop

# brief names: the brief states the public function's name (`- name(...) : what it does`); round 1 renames it and the plan is otherwise valid, so only the
# brief-name check can refuse it. The refusal is fed back IN THE ROUND (src/plan.cho `brief_report`, the same check `build` keeps as a backstop), naming
# every missing name and the exact action; round 2 declares the name and is written; both rounds are in the journal
RENAMED='{"name": "clampy", "units": [{"id": "clamp", "signature": "fn clamp_value(x: int, lo: int, hi: int) -> [] int", "description": "x limited to [lo, hi].", "examples": ["clamp_value(5, 1, 3) == 3"], "deps": []}, {"id": "mid", "signature": "fn middle(a: int, b: int) -> [] int", "description": "the midpoint.", "examples": ["middle(2, 4) == 3"], "deps": []}]}'
GOOD2='{"name": "clampy", "units": [{"id": "clamp", "signature": "fn clampy(x: int, lo: int, hi: int) -> [] int", "description": "x limited to [lo, hi].", "examples": ["clampy(5, 1, 3) == 3"], "deps": []}, {"id": "mid", "signature": "fn middle(a: int, b: int) -> [] int", "description": "the midpoint.", "examples": ["middle(2, 4) == 3"], "deps": []}]}'
printf 'Write two functions:\n- clampy(x, lo, hi) : limit x to [lo, hi]\n- middle(a, b) -> int : the midpoint of a and b\n- middle(a, b) : again, a name the brief repeats\n' > "$d/brief-names.txt"
JB="$d/jb"; rm -rf "$JB"; mkdir -p "$JB/blobs"
start; printf '%s' "$RENAMED" > "$d/response.1.txt"; printf 'Fixed:\n%s\n' "$GOOD2" > "$d/response.2.txt"; rm -f "$d/out/plan.json" "$d/ulog"
plan --guide "$d/guide.md" --brief "$d/brief-names.txt" --usage-log "$d/ulog" --journal "$JB" >/dev/null 2>"$d/e"; rc=$?
expect "brief names: exit code ($(head -c 200 "$d/e"))" "$rc" 0
expect "brief names: two requests" "$(count)" 2
expect "brief names: usage outcomes" "$(python3 -c "import json; print([json.loads(l)['outcome'] for l in open('$d/ulog')])")" "['rejected', 'written']"
P2=$(prompt_of 2)
for want in "REJECTED" "brief-name" "declare \`fn clampy\` with exactly this name" "the brief states it" "$RENAMED"; do
    case "$P2" in *"$want"*) ;; *) echo "FAIL: brief names: the second prompt lacks '$want'" >&2; fail=1 ;; esac
done
case "$P2" in *"brief-name"*"middle"*) echo "FAIL: brief names: a name the plan declares was reported" >&2; fail=1 ;; esac
python3 -c "import json,sys; sys.exit(0 if 'fn clampy(' in json.load(open('$d/out/plan.json'))['units'][0]['signature'] else 1)" || { echo "FAIL: brief names: the written plan lacks fn clampy" >&2; fail=1; }
python3 -I - "$JB" <<'PY' || fail=1
import json, sys
ev = [json.loads(l) for l in open(sys.argv[1] + "/events.jsonl")]
got = [(e["kind"], e["round"], e["outcome"]) for e in ev]
bad = []
if got != [("plan_call", 1, "rejected"), ("plan_call", 2, "written")]: bad.append("events %r" % got)
elif not any("brief-name" in x and "clampy" in x for x in ev[0]["errors"]): bad.append("round 1 errors %r" % ev[0]["errors"])
if bad: print("FAIL: brief names: journal: " + "; ".join(bad), file=sys.stderr); sys.exit(1)
PY
stop
# every missing name is reported at once, not only the first
TWO='{"name": "clampy", "units": [{"id": "clamp", "signature": "fn clamp_value(x: int, lo: int, hi: int) -> [] int", "description": "x limited to [lo, hi].", "examples": ["clamp_value(5, 1, 3) == 3"], "deps": []}, {"id": "mid", "signature": "fn mid(a: int, b: int) -> [] int", "description": "the midpoint.", "examples": ["mid(2, 4) == 3"], "deps": []}]}'
start; printf '%s' "$TWO" > "$d/response.1.txt"; printf '%s' "$GOOD2" > "$d/response.2.txt"; rm -f "$d/out/plan.json"
plan --guide "$d/guide.md" --brief "$d/brief-names.txt" >/dev/null 2>"$d/e"; rc=$?
expect "brief names, both missing: exit code" "$rc" 0
P2=$(prompt_of 2)
for want in "declare \`fn clampy\` with exactly this name" "declare \`fn middle\` with exactly this name"; do
    case "$P2" in *"$want"*) ;; *) echo "FAIL: brief names, both missing: the second prompt lacks '$want'" >&2; fail=1 ;; esac
done
stop

# cases: the model writes DATA; the agent turns it into the unit's tests before the plan check, and writes the expanded plan
CASES_OK='{"name": "clampy", "units": [{"id": "clamp", "signature": "fn clampy(x: int, lo: int, hi: int) -> [] int", "description": "x limited to [lo, hi].", "examples": ["clampy(5, 1, 3) == 3"], "cases": [{"args": [5, 1, 3], "expect": 3}, {"args": [-5, 1, 3], "expect": 1}], "deps": []}]}'
CASES_BAD='{"name": "clampy", "units": [{"id": "clamp", "signature": "fn clampy(x: int, lo: int, hi: int) -> [] int", "description": "x limited to [lo, hi].", "examples": ["clampy(5, 1, 3) == 3"], "cases": [{"args": [5, 1], "expect": 3}], "deps": []}]}'
start; printf '%s' "$CASES_BAD" > "$d/response.1.txt"; printf '%s' "$CASES_OK" > "$d/response.2.txt"; rm -f "$d/out/plan.json" "$d/ulog"
plan $G --usage-log "$d/ulog" >/dev/null 2>"$d/e"; rc=$?
expect "cases: exit code ($(head -c 200 "$d/e"))" "$rc" 0
expect "cases: two requests" "$(count)" 2
case "$(prompt_of 2)" in *"[CASES_ERROR]"*"clamp"*) ;; *) echo "FAIL: cases: the second prompt does not carry the expander's report" >&2; fail=1 ;; esac
python3 - "$d/out/plan.json" <<'PY' || fail=1
import json, sys
p = json.load(open(sys.argv[1]))
u = p["units"][0]
bad = []
if "cases" in u: bad.append("the written plan still holds cases")
if not u.get("tests") or not all("pub fn test_" in t or t.lstrip().startswith("fn ") for t in u["tests"]): bad.append("no generated tests: %r" % u.get("tests"))
if u["examples"] != ["clampy(5, 1, 3) == 3"]: bad.append("examples changed")
if bad: print("FAIL: cases: " + "; ".join(bad), file=sys.stderr); sys.exit(1)
PY
"$d/plancheck" "$d/out/plan.json" >/dev/null 2>&1 || { echo "FAIL: cases: the expanded plan does not pass plancheck" >&2; fail=1; }
expect "cases: usage outcomes" "$(python3 -c "import json; print([json.loads(l)['outcome'] for l in open('$d/ulog')])")" "['rejected', 'written']"
stop

# fallback: a unit whose signature `cases` cannot express (an Option of a Box). The expander's report is the next round's teacher: it says to delete
# the unit's `cases` and write `tests`, that the unit still needs an example, and which types cases can express; a plan that does as told is accepted
KV_CASES='{"name": "kv", "units": [{"id": "find", "signature": "fn kv_find[&h, &t, &k](heap: &!h Heap, text: &t [byte], key: &k [byte]) -> [heap] option.Option[Box[[byte]]]", "description": "Some(value) of key=value, else None.", "examples": ["kv_find(heap, \"a=1\", \"a\") == option.Option::Some(\"1\")"], "cases": [{"args": ["a=1", "a"], "expect": "1"}], "deps": []}]}'
start; printf '%s' "$KV_CASES" > "$d/response.1.txt"; cp "$d/guide-kv.json" "$d/response.2.txt" 2>/dev/null; rm -f "$d/out/plan.json" "$d/ulog"
python3 - "$root/docs/plan-guide.md" "$d/guide-kv.json" <<'PY'
import re, sys
blocks = re.findall(r"```json\n(.*?)\n```", open(sys.argv[1], encoding="utf-8").read(), re.S)
open(sys.argv[2], "w", encoding="utf-8").write(blocks[1] + "\n")
PY
cp "$d/guide-kv.json" "$d/response.2.txt"
plan $G --usage-log "$d/ulog" >/dev/null 2>"$d/e"; rc=$?
expect "fallback: exit code ($(head -c 300 "$d/e"))" "$rc" 0
expect "fallback: two requests" "$(count)" 2
P2=$(prompt_of 2)
for want in "[CASES_ERROR]" "(option.Option[Box[[byte]]])" "delete the \`cases\` of this unit and write \`tests\`" "keep one \`examples\` entry" "buffer.Buffer (owned text)" "When cases cannot express a signature"; do
    case "$P2" in *"$want"*) ;; *) echo "FAIL: fallback: the second prompt lacks '$want'" >&2; fail=1 ;; esac
done
expect "fallback: usage outcomes" "$(python3 -c "import json; print([json.loads(l)['outcome'] for l in open('$d/ulog')])")" "['rejected', 'written']"
"$d/plancheck" "$d/out/plan.json" >/dev/null 2>&1 || { echo "FAIL: fallback: the written plan does not pass plancheck" >&2; fail=1; }
stop

# review: a second, BLIND pass. A reviewer re-derives each case's result from the description only; a case survives only if it agrees
printf '# Verifying the cases\nDerive each value.\n' > "$d/rguide.md"
RV="--review on --review-guide $d/rguide.md"
RC='{"name": "clampy", "units": [{"id": "clamp", "signature": "fn clampy(x: int, lo: int, hi: int) -> [] int", "description": "x limited to [lo, hi].", "examples": ["clampy(5, 1, 3) == 3"], "cases": [{"args": [5, 1, 3], "expect": 3}, {"args": [-5, 1, 3], "expect": 99}], "deps": []}]}'
start; printf '%s' "$RC" > "$d/response.1.txt"; printf '{"units": [{"id": "clamp", "answers": [{"expect": 3}, {"expect": 1}]}]}' > "$d/response.2.txt"; rm -f "$d/out/plan.json" "$d/ulog"
plan $G $RV --usage-log "$d/ulog" >/dev/null 2>"$d/e"; rc=$?
expect "review: exit code ($(head -c 200 "$d/e"))" "$rc" 0
expect "review: two requests (the plan, then the review)" "$(count)" 2
R2=$(prompt_of 2)
for want in "Verifying the cases" "clampy" "x limited to"; do
    case "$R2" in *"$want"*) ;; *) echo "FAIL: review: the review prompt lacks '$want'" >&2; fail=1 ;; esac
done
case "$R2" in *'"expect"'*|*99*) echo "FAIL: review: the reviewer was shown an expected value" >&2; fail=1 ;; esac
expect "review: only the agreed case survives as a test" "$(python3 -c "import json; p = json.load(open('$d/out/plan.json')); print(sum(t.count('pub fn test_') for t in p['units'][0]['tests']))")" 1
expect "review: usage outcomes" "$(python3 -c "import json; print([json.loads(l)['outcome'] for l in open('$d/ulog')])")" "['written', 'reviewed']"
case "$(cat "$d/e")" in *"REVIEW_DROPPED"*) ;; *) echo "FAIL: review: the dropped case is not reported on stderr" >&2; fail=1 ;; esac
stop
# the reviewer agrees with none: the plan is rejected and the planner is told
start; printf '%s' "$RC" > "$d/response.1.txt"; printf '{"units": [{"id": "clamp", "answers": [{"skip": true}, {"expect": 1}]}]}' > "$d/response.2.txt"
printf '%s' "$RC" | sed 's/"expect": 99/"expect": 1/' > "$d/response.3.txt"; printf '{"units": [{"id": "clamp", "answers": [{"expect": 3}, {"expect": 1}]}]}' > "$d/response.4.txt"; rm -f "$d/out/plan.json"
plan $G $RV >/dev/null 2>"$d/e"; rc=$?
expect "review none: exit code" "$rc" 0
expect "review none: four requests" "$(count)" 4
case "$(prompt_of 3)" in *"REVIEW"*"agreed with none"*|*"agreed with none"*) ;; *) echo "FAIL: review none: the planner was not told the reviewer agreed with none" >&2; fail=1 ;; esac
stop
# an unusable review is not a plan failure: the plan is written, unreviewed, and the log says so
start; printf '%s' "$RC" > "$d/response.1.txt"; printf 'I cannot verify this.\n' > "$d/response.2.txt"; cp "$d/response.2.txt" "$d/response.3.txt"; rm -f "$d/out/plan.json" "$d/ulog"
plan $G $RV --usage-log "$d/ulog" >/dev/null 2>"$d/e"; rc=$?
expect "review failed: exit code" "$rc" 0
case "$(cat "$d/e")" in *unreviewed*) ;; *) echo "FAIL: review failed: the plan is not marked unreviewed on stderr" >&2; fail=1 ;; esac
expect "review failed: usage outcomes" "$(python3 -c "import json; print([json.loads(l)['outcome'] for l in open('$d/ulog')])")" "['written', 'review_failed', 'review_failed']"
stop
# a review that miscounts (one answer fewer than cases) is the reviewer's slip, not the plan's: it is asked again, told what was wrong, and the plan
# is not rejected for it
start; printf '%s' "$RC" > "$d/response.1.txt"; printf '{"units": [{"id": "clamp", "answers": [{"expect": 3}]}]}' > "$d/response.2.txt"; printf '{"units": [{"id": "clamp", "answers": [{"expect": 3}, {"expect": 1}]}]}' > "$d/response.3.txt"; rm -f "$d/out/plan.json" "$d/ulog"
plan $G $RV --usage-log "$d/ulog" >/dev/null 2>"$d/e"; rc=$?
expect "review miscount: exit code ($(head -c 200 "$d/e"))" "$rc" 0
expect "review miscount: three requests (the plan, the review, the review again), no second plan round" "$(count)" 3
case "$(prompt_of 3)" in *"YOUR PREVIOUS ANSWER WAS UNUSABLE"*"1 answers for 2 cases"*) ;; *) echo "FAIL: review miscount: the second review prompt does not say what was wrong" >&2; fail=1 ;; esac
expect "review miscount: usage outcomes" "$(python3 -c "import json; print([json.loads(l)['outcome'] for l in open('$d/ulog')])")" "['written', 'review_failed', 'reviewed']"
expect "review miscount: the second try reviewed it: the agreed case survives, the other is dropped" "$(python3 -c "import json; p = json.load(open('$d/out/plan.json')); print(sum(t.count('pub fn test_') for t in p['units'][0]['tests']))")" 1
case "$(cat "$d/e")" in *"REVIEW_ERROR"*"1 answers for 2 cases"*) ;; *) echo "FAIL: review miscount: the first try's error is not on stderr" >&2; fail=1 ;; esac
case "$(cat "$d/e")" in *unreviewed*) echo "FAIL: review miscount: marked unreviewed although the second try worked" >&2; fail=1 ;; esac
stop
# the journal of a review that miscounts and is asked again: both review calls are events, the first review_failed with what was wrong
JM="$d/jmis"; rm -rf "$JM"; mkdir -p "$JM/blobs"
start; printf '%s' "$RC" > "$d/response.1.txt"; printf '{"units": [{"id": "clamp", "answers": [{"expect": 3}]}]}' > "$d/response.2.txt"; printf '{"units": [{"id": "clamp", "answers": [{"expect": 3}, {"expect": 1}]}]}' > "$d/response.3.txt"; rm -f "$d/out/plan.json" "$d/response.txt"
plan $G $RV --journal "$JM" >/dev/null 2>&1
python3 -I - "$JM" <<'PY' || fail=1
import json, sys
jd = sys.argv[1]
ev = [json.loads(l) for l in open(jd + "/events.jsonl")]
k = [e["kind"] + ":" + e.get("outcome", "") + ":" + str(e.get("sample", "")) for e in ev]
bad_ = []
if k != ["plan_call:written:1", "plan_call:review_failed:1", "plan_review::", "plan_call:reviewed:2", "plan_review::"]: bad_.append("events %r" % k)
else:
    f = ev[1]
    if not any("1 answers for 2 cases" in x for x in f["errors"]): bad_.append("errors of the failed review %r" % f["errors"])
    if f["prompt"] == ev[3]["prompt"] or "UNUSABLE" not in open(jd + "/blobs/" + ev[3]["prompt"]).read(): bad_.append("the second review's prompt does not carry the slip")
    if ev[4]["kept"] != 1 or ev[4]["of"] != 2: bad_.append("second review %r" % ev[4])
if bad_: print("FAIL: journal miscount: " + "; ".join(bad_), file=sys.stderr); sys.exit(1)
PY
stop
# miscounts twice: the plan is KEPT, unreviewed (both its cases), and the log says so, with the errors: never silent, never a rejected plan
start; printf '%s' "$RC" > "$d/response.1.txt"; printf '{"units": [{"id": "clamp", "answers": [{"expect": 3}]}]}' > "$d/response.2.txt"; cp "$d/response.2.txt" "$d/response.3.txt"; rm -f "$d/out/plan.json" "$d/ulog"
plan $G $RV --usage-log "$d/ulog" >/dev/null 2>"$d/e"; rc=$?
expect "review miscount twice: exit code" "$rc" 0
expect "review miscount twice: three requests" "$(count)" 3
expect "review miscount twice: the plan is written with both cases (unreviewed)" "$(python3 -c "import json; p = json.load(open('$d/out/plan.json')); print(sum(t.count('pub fn test_') for t in p['units'][0]['tests']))")" 2
case "$(cat "$d/e")" in *"the plan stands unreviewed"*) ;; *) echo "FAIL: review miscount twice: stderr does not say the plan stands unreviewed" >&2; fail=1 ;; esac
expect "review miscount twice: the error is on stderr both times" "$(grep -c 'REVIEW_ERROR.*1 answers for 2 cases' "$d/e")" 2
expect "review miscount twice: usage outcomes" "$(python3 -c "import json; print([json.loads(l)['outcome'] for l in open('$d/ulog')])")" "['written', 'review_failed', 'review_failed']"
stop
# --review on needs its guide
start; plan $G --review on >/dev/null 2>"$d/e"; rc=$?
expect "review: no --review-guide is exit 2" "$rc" 2
stop

# journal: every call of the plan stage is recorded
printf 'PRIMER-ONCE-XYZ\n' > "$d/primer.md"
JD="$d/jr"; rm -rf "$JD"; mkdir -p "$JD/blobs"
start; printf '%s' "$BAD" > "$d/response.1.txt"; printf 'Corrected:\n%s\n' "$GOOD" > "$d/response.2.txt"; rm -f "$d/out/plan.json"
plan $G --primer "$d/primer.md" --journal "$JD" >/dev/null 2>"$d/e"; rc=$?
expect "journal: exit code" "$rc" 0
python3 -I - "$JD" "$d" "$BAD" <<'PY' || fail=1
import json, sys
jd, d, bad = sys.argv[1:4]
ev = [json.loads(l) for l in open(jd + "/events.jsonl")]
blob = lambda n: open(jd + "/blobs/" + n, encoding="utf-8").read()
req = lambda n: json.load(open("%s/request.%d.json" % (d, n)))["prompt"]
primer = open(d + "/primer.md").read()
bad_ = []
if [e["kind"] for e in ev] != ["plan_call", "plan_call"]: bad_.append("kinds %r" % [e["kind"] for e in ev])
else:
    a, b = ev
    if (a["round"], a["sample"], a["outcome"], b["round"], b["outcome"]) != (1, 1, "rejected", 2, "written"): bad_.append("rounds/outcomes %r" % [(e["round"], e["sample"], e["outcome"]) for e in ev])
    if a["tokens"] != {"in": 9, "out": 7, "thinking": 0, "cache_write": 0, "cache_read": 0}: bad_.append("tokens %r" % a["tokens"])
    if a.get("stop") != "stop" or not isinstance(a.get("ms"), int): bad_.append("stop/ms %r %r" % (a.get("stop"), a.get("ms")))
    if not any("no-example" in x for x in a["errors"]): bad_.append("errors of round 1: %r" % a["errors"])
    if b["errors"] != []: bad_.append("errors of round 2: %r" % b["errors"])
    for n, e in ((1, a), (2, b)):
        if primer + blob(e["prompt"]) != req(n): bad_.append("round %d: primer + prompt blob is not the request's prompt" % n)
        if not e.get("primer"): bad_.append("round %d: no primer flag" % n)
    if blob(a["reply"]) != bad: bad_.append("reply 1 is not the model's reply: %r" % blob(a["reply"]))
    if "Corrected:" not in blob(b["reply"]): bad_.append("reply 2 is not the model's reply")
    if blob("primer.txt") != primer: bad_.append("blobs/primer.txt is not the primer")
    import os
    holders = [f for f in os.listdir(jd + "/blobs") if "PRIMER-ONCE-XYZ" in blob(f)]
    if holders != ["primer.txt"]: bad_.append("the primer is in %r" % holders)
    if "REJECTED" not in blob(b["prompt"]) or "no-example" not in blob(b["prompt"]): bad_.append("round 2's prompt blob does not carry the refusal")
if bad_: print("FAIL: journal: " + "; ".join(bad_), file=sys.stderr); sys.exit(1)
PY
stop
# without --journal nothing is written
JN="$d/jn"; rm -rf "$JN"; mkdir -p "$JN"
start; printf '%s' "$GOOD" > "$d/response.txt"; rm -f "$d/response.1.txt" "$d/response.2.txt"
plan $G >/dev/null 2>&1; expect "journal: off without --journal" "$(ls "$JN" | wc -l | tr -d ' ')" 0
stop
# the review: its call, and the cases it dropped with the reason
JR="$d/jrev"; rm -rf "$JR"; mkdir -p "$JR/blobs"
start; printf '%s' "$RC" > "$d/response.1.txt"; printf '{"units": [{"id": "clamp", "answers": [{"expect": 3}, {"expect": 1}]}]}' > "$d/response.2.txt"; rm -f "$d/response.txt" "$d/out/plan.json"
plan $G $RV --primer "$d/primer.md" --journal "$JR" >/dev/null 2>&1
python3 -I - "$JR" <<'PY' || fail=1
import json, sys
jd = sys.argv[1]
ev = [json.loads(l) for l in open(jd + "/events.jsonl")]
bad_ = []
if [e["kind"] for e in ev] != ["plan_call", "plan_call", "plan_review"]: bad_.append("kinds %r" % [e["kind"] for e in ev])
else:
    p, r, v = ev
    if (p["outcome"], r["outcome"], r["round"], r["sample"]) != ("written", "reviewed", 1, 1): bad_.append("outcomes %r" % [e["outcome"] for e in ev[:2]])
    if "Verifying the cases" not in open(jd + "/blobs/" + r["prompt"]).read(): bad_.append("the review's prompt is not in its blob")
    if p["prompt"] == r["prompt"] or p["reply"] == r["reply"] or "=== THE TASK ===" not in open(jd + "/blobs/" + p["prompt"]).read(): bad_.append("the review's blobs overwrote the plan's")
    if p.get("primer") is not True or r.get("primer"): bad_.append("primer flags: the plan call carries the primer, the review call does not: %r %r" % (p.get("primer"), r.get("primer")))
    if (v["kept"], v["of"]) != (1, 2): bad_.append("kept %r of %r" % (v["kept"], v["of"]))
    d = v["dropped"]
    if len(d) != 1 or d[0]["unit"] != "clamp" or d[0]["case"] != 2 or not d[0]["reason"].startswith("planner 99 reviewer 1"): bad_.append("dropped %r" % d)
    if "REVIEW_DROPPED" not in open(jd + "/blobs/" + v["blob"]).read(): bad_.append("the review's blob is not its report")
if bad_: print("FAIL: journal review: " + "; ".join(bad_), file=sys.stderr); sys.exit(1)
PY
stop
# a review that refuses the plan (it agrees with none of a unit's cases): the refusal is in the event
JX="$d/jrev2"; rm -rf "$JX"; mkdir -p "$JX/blobs"
start; printf '%s' "$RC" > "$d/response.1.txt"; printf '{"units": [{"id": "clamp", "answers": [{"skip": true}, {"expect": 1}]}]}' > "$d/response.2.txt"
printf '%s' "$RC" | sed 's/"expect": 99/"expect": 1/' > "$d/response.3.txt"; printf '{"units": [{"id": "clamp", "answers": [{"expect": 3}, {"expect": 1}]}]}' > "$d/response.4.txt"; rm -f "$d/out/plan.json"
plan $G $RV --journal "$JX" >/dev/null 2>&1
python3 -I - "$JX" <<'PY' || fail=1
import json, sys
ev = [json.loads(l) for l in open(sys.argv[1] + "/events.jsonl")]
bad_ = []
k = [e["kind"] + (":" + e["outcome"] if "outcome" in e else "") for e in ev]
if k != ["plan_call:written", "plan_call:review_rejected", "plan_review", "plan_call:written", "plan_call:reviewed", "plan_review"]: bad_.append("events %r" % k)
else:
    rej = ev[2]
    if "agreed with none" not in rej.get("error", "") and "agreed with none" not in "".join(ev[1]["errors"]): bad_.append("no refusal in the events: %r" % rej)
    if rej["dropped"] != [{"unit": "clamp", "case": 1, "reason": "planner 3 reviewer skip"}, {"unit": "clamp", "case": 2, "reason": "planner 99 reviewer 1"}]: bad_.append("dropped of the refused review %r" % rej["dropped"])
    if ev[1]["errors"] == []: bad_.append("the refusal fed back is not in plan_call errors")
if bad_: print("FAIL: journal review none: " + "; ".join(bad_), file=sys.stderr); sys.exit(1)
PY
stop

# ceiling: every round rejected; an existing file is untouched
start; printf '%s' "$BAD" > "$d/response.txt"; printf 'KEEP\n' > "$d/out/plan.json"
plan $G >"$d/o" 2>"$d/e"; rc=$?
expect "ceiling: exit code" "$rc" 1
expect "ceiling: three rounds" "$(count)" 3
expect "ceiling: the existing file is untouched" "$(cat "$d/out/plan.json")" "KEEP"
case "$(cat "$d/e")" in *no-example*) ;; *) echo "FAIL: ceiling: the last report is not on stderr ('$(head -c 200 "$d/e")')" >&2; fail=1 ;; esac
stop

# questions
for status in unclear too_big; do
    start; rm -f "$d/out/plan.json" "$d/out/plan.json.questions.json"
    if [ $status = unclear ]; then printf 'I need to know more.\n{"status": "unclear", "questions": ["Which currency?", "One ledger or many?"]}\n' > "$d/response.txt"
    else printf '{"status": "too_big", "modules": [{"name": "ledger", "summary": "accounts and entries"}, {"name": "api", "summary": "HTTP front"}]}' > "$d/response.txt"; fi
    plan $G >"$d/o" 2>"$d/e"; rc=$?
    expect "$status: exit code 3" "$rc" 3
    expect "$status: one request" "$(count)" 1
    [ ! -e "$d/out/plan.json" ] || { echo "FAIL: $status: a plan was written" >&2; fail=1; }
    expect "$status: the model's object is saved" "$(python3 -c "import json; print(json.load(open('$d/out/plan.json.questions.json'))['status'])" 2>&1)" "$status"
    stop
done

# no json: prose, then a cut-off, then a good plan
start; printf 'I would need to think about this.\n' > "$d/response.1.txt"; printf '{"name": "clampy", "units": [{"id": "clamp"' > "$d/response.2.txt"; printf 'length' > "$d/response.2.reason"; printf '%s' "$GOOD" > "$d/response.3.txt"; rm -f "$d/out/plan.json" "$d/ulog"
plan $G --usage-log "$d/ulog" >/dev/null 2>&1; rc=$?
expect "no json: exit code" "$rc" 0
expect "no json: three requests" "$(count)" 3
expect "no json: the outcomes" "$(python3 -c "import json; print([json.loads(l)['outcome'] for l in open('$d/ulog')])")" "['no_plan', 'cut_off', 'written']"
case "$(prompt_of 2)" in *"no JSON object"*) ;; *) echo "FAIL: no json: the next prompt does not say the reply had no JSON object" >&2; fail=1 ;; esac
stop

# cut off: a plan cut off by the bound is asked again with the bound doubled (at most 32000); a reply with nothing in it (the model's thinking used
# all of the bound) is told that, not told to write a shorter plan
npred() { python3 -c "import json; print(json.load(open('$d/request.$1.json'))['options']['num_predict'])"; }
start; printf '' > "$d/response.1.txt"; printf 'length' > "$d/response.1.reason"; printf '{"name": "clampy", "units": [{"id": "clamp"' > "$d/response.2.txt"; printf 'length' > "$d/response.2.reason"; printf '%s' "$GOOD" > "$d/response.3.txt"; rm -f "$d/out/plan.json" "$d/ulog"
plan $G --max-tokens 20000 --rounds 4 --usage-log "$d/ulog" >/dev/null 2>"$d/e"; rc=$?
expect "cut off: exit code" "$rc" 0
expect "cut off: three requests" "$(count)" 3
expect "cut off: the bound of the first round" "$(npred 1)" 20000
expect "cut off: the bound of the second round (doubled, at most 32000)" "$(npred 2)" 32000
expect "cut off: the bound of the third round (the cap)" "$(npred 3)" 32000
case "$(prompt_of 2)" in *"your thinking used all of it"*) ;; *) echo "FAIL: cut off: an empty cut-off reply is not told that thinking used the bound" >&2; fail=1 ;; esac
case "$(prompt_of 3)" in *"SHORTER plan"*) ;; *) echo "FAIL: cut off: a partial cut-off reply is not told to write a shorter plan" >&2; fail=1 ;; esac
stop
start; printf '{"name": "clampy", "units": [{"id": "clamp"' > "$d/response.1.txt"; printf 'length' > "$d/response.1.reason"; printf '%s' "$GOOD" > "$d/response.2.txt"; rm -f "$d/out/plan.json"
plan $G --max-tokens 1000 >/dev/null 2>"$d/e"; rc=$?
expect "cut off 1000: exit code" "$rc" 0
expect "cut off 1000: the second round has twice the bound" "$(npred 2)" 2000
case "$(cat "$d/e")" in *"the bound for the next round is 2000"*) ;; *) echo "FAIL: cut off 1000: the raised bound is not on stderr" >&2; fail=1 ;; esac
stop

# required
start
rm -f "$d/count"
env -i CANCHO_AGENT_BIN="$exe" /bin/sh "$root/scripts/cancho-agent.sh" --provider ollama --model m --port "$port" --mode plan --brief "$d/brief.txt" "$d/out/plan.json" >/dev/null 2>"$d/e"; rc=$?
expect "required: no --guide is exit 2" "$rc" 2
env -i CANCHO_AGENT_BIN="$exe" /bin/sh "$root/scripts/cancho-agent.sh" --provider ollama --model m --port "$port" --mode plan --guide "$d/guide.md" "$d/out/plan.json" >/dev/null 2>"$d/e"; rc=$?
expect "required: no --brief is exit 2" "$rc" 2
env -i CANCHO_AGENT_BIN="$exe" /bin/sh "$root/scripts/cancho-agent.sh" --provider ollama --model m --port "$port" --mode bogus --guide "$d/guide.md" --brief "$d/brief.txt" "$d/out/plan.json" >/dev/null 2>"$d/e"; rc=$?
expect "required: an unknown --mode is exit 2" "$rc" 2
expect "required: no request was made" "$(count)" 0
stop

# the guide's own worked example is a valid plan (a guide whose example the check rejects teaches the wrong thing)
python3 - "$root/docs/plan-guide.md" "$d/guide-example.json" <<'PY'
import re, sys
m = re.search(r"```json\n(.*?)\n```", open(sys.argv[1], encoding="utf-8").read(), re.S)
open(sys.argv[2], "w", encoding="utf-8").write(m.group(1) + "\n")
PY
"$d/plancheck" "$d/guide-example.json" >"$d/o" 2>&1 || { echo "FAIL: guide: its worked example is not a valid plan: $(cat "$d/o")" >&2; fail=1; }
for want in unclear too_big "REQUIRED PUBLIC FUNCTIONS" "ONE function"; do
    grep -q "$want" "$root/docs/plan-guide.md" || { echo "FAIL: guide: lacks '$want'" >&2; fail=1; }
done

# the guide's second worked example (the `tests` fallback for a signature cases cannot express) is a valid plan AND its tests compile and pass
# against a reference implementation (tests/fixtures/guide/kvfind.cho); one expected value flipped must fail it (the tests check something)
python3 - "$root/docs/plan-guide.md" "$d" "$CANCHO" "$root" <<'PY' || fail=1
import json, os, re, subprocess, sys
guide, d, cancho, root = sys.argv[1:5]
blocks = re.findall(r"```json\n(.*?)\n```", open(guide, encoding="utf-8").read(), re.S)
bad = []
if len(blocks) != 2: bad.append("the guide has %d json blocks, wanted 2 (a plan, and the tests fallback)" % len(blocks))
else:
    plan = json.loads(blocks[1])
    unit = plan["units"][0]
    if "cases" in unit: bad.append("the fallback example has cases")
    if not unit.get("tests") or not unit.get("examples"): bad.append("the fallback example lacks tests or examples")
    def run(tests):
        tf = os.path.join(d, "guide-tests.cho")
        open(tf, "w").write("edition 7;\nimport std.test;\n" + "\n".join(tests) + "\n")
        return subprocess.run([cancho, "test", "--std", "--backend", "cranelift", os.path.join(root, "tests", "fixtures", "guide", "kvfind.cho"), tf], capture_output=True, cwd=d)
    r = run(unit["tests"])
    if r.returncode != 0: bad.append("the guide's tests do not pass against the reference: " + (r.stdout + r.stderr).decode()[-300:])
    flipped = [t.replace('"a=1", "a", "1"', '"a=1", "a", "2"') for t in unit["tests"]]
    if flipped == unit["tests"]: bad.append("nothing to flip in the guide's tests")
    elif run(flipped).returncode == 0: bad.append("the guide's tests still pass with a wrong expected value: they check nothing")
if bad:
    print("FAIL: guide: " + "; ".join(bad), file=sys.stderr); sys.exit(1)
PY
for want in "Cover everything the task states" "When \`cases\` cannot express a signature" "EVERY kind of error" "worked examples are exact" "cannot contain a real line break" "cannot be discarded"; do
    grep -qF "$want" "$root/docs/plan-guide.md" || { echo "FAIL: guide: lacks '$want'" >&2; fail=1; }
done

rm -rf "$d"
[ "$fail" = 0 ] && echo "planner gate: ok" || { echo "planner gate: FAILED" >&2; exit 1; }
