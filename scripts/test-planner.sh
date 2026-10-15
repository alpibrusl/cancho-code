#!/bin/sh
# The planner gate: `cancho-agent --mode plan` (src/cancho_agent.cho) asks a model for a PLAN (docs/plan.md) instead of a program, and the plan
# check (src/plan.cho, in process, no model) decides. Against a plain-HTTP stub that speaks Ollama's /api/generate, so no key, no GPU, no spend:
#
#   plan      a valid plan inside prose and a fence is written (the same plan as JSON, one newline after, units without `cases` untouched); one request; the prompt
#             holds the guide, the task and the required signatures
#   feedback  a rejected plan is not written; the NEXT request carries the plan check's own report and the rejected plan; a good second plan is written
#   cases     a unit's `cases` (data) are expanded into its `tests` by src/cases.cho before the plan check; an expansion error is fed back like a plan-check error; the plan written has tests and no cases
#   ceiling   every round rejected: exit 1, nothing written, the file that was there is untouched, the last report is on stderr
#   questions {"status":"unclear"} / {"status":"too_big"}: exit 3, the model's object is saved beside the output, no plan is written, one request
#   no json   prose without an object, and a reply cut off by the bound, are rounds that fail and are retried; neither is ever written
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
"$CANCHO" build "$root/src/cancho_agent.cho" "$root/src/anthropic.cho" "$root/src/ollama.cho" "$root/src/prompt.cho" "$root/src/planprompt.cho" "$root/src/plan.cho" "$root/src/cases.cho" "$root/src/review.cho" "$root/src/splice.cho" "$root/src/provider.cho" "$root/src/reply.cho" "$root/src/calls.cho" \
    "$root/vendor/fetch_io.cho" "$C"/http-client/*.cho "$C"/tls/*.cho "$C"/x509/*.cho --std --backend cranelift -o "$exe" >/dev/null 2>"$d/build.err" \
    || { cat "$d/build.err" >&2; echo "gate did not build" >&2; exit 2; }
"$CANCHO" build "$root/tests/programs/plancheck.cho" "$root/src/plan.cho" --std --backend cranelift -o "$d/plancheck" >/dev/null 2>&1 || { echo "plancheck did not build" >&2; exit 2; }

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
plan $G $RV --journal "$JR" >/dev/null 2>&1
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

rm -rf "$d"
[ "$fail" = 0 ] && echo "planner gate: ok" || { echo "planner gate: FAILED" >&2; exit 1; }
