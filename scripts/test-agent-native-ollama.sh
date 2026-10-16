#!/bin/sh
# The native Ollama agent gate (docs/parity.md P1): src/cancho_agent.cho (--provider ollama) through scripts/cancho-agent.sh against a stub server that speaks Ollama's /api/generate,
# so no model, no GPU and no network are involved. One case per promise:
#
#   request   the prompt holds the project file AND the checker's refusals (<project>.feedback); the model comes from --model;
#             thinking is off and streaming is off (the answer is the file, not a trace)
#   rewrite   the project file becomes the model's answer, with a markdown fence stripped
#   env       it works with no environment at all (env -i): the driver gives its agent none, and ollama panics without a HOME
#   task      <project>.task, when there is one, goes in the prompt ahead of the file (a project unit; docs/project.md)
#   truncated a reply cut off by the generation bound (done_reason "length") is not a sample: retried, never written
#   primer    --primer names a file that goes first in the prompt; an unreadable one is an error, not a silent skip
#   memory    --memory <dir> (docs/memory.md): the prompt gets a `Known pitfalls` block for the class of the refusal the unit just got and the person's facts;
#             without --memory, for a superseded lesson, for another class: nothing is added; what was added is in <project>.call/memory.json; the task file is untouched
#   away      a server that is not there is a non-zero exit and the file is left as it was (the driver names it `agent_exit`)
#
# Needs python3 (the stub, and the script's own HTTP call; standard library only).
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "no python3 on PATH" >&2; exit 2; }
C="${CANCHO_PACKAGES:-}"
[ -d "$C" ] || C="$(dirname "$(dirname "$(dirname "$(command -v "$CANCHO")")")")/packages"
[ -d "$C" ] || { echo "no cancho packages found; set CANCHO_PACKAGES" >&2; exit 2; }
fail=0
expect() { [ "$2" = "$3" ] || { echo "FAIL: $1: wanted '$3', got '$2'" >&2; fail=1; }; }

d=$(mktemp -d -t cc-ollama-d-XXXXXX)
exe="$d/agent"
"$CANCHO" build "$root/src/cancho_agent.cho" "$root/src/anthropic.cho" "$root/src/ollama.cho" "$root/src/prompt.cho" "$root/src/planprompt.cho" "$root/src/plan.cho" "$root/src/cases.cho" "$root/src/review.cho" "$root/src/splice.cho" "$root/src/provider.cho" "$root/src/reply.cho" "$root/src/calls.cho" "$root/src/memory.cho" "$root/src/signature.cho" \
    "$root/vendor/fetch_io.cho" "$C"/http-client/*.cho "$C"/tls/*.cho "$C"/x509/*.cho --std --backend cranelift -o "$exe" >/dev/null 2>"$d/build.err" \
    || { cat "$d/build.err" >&2; echo "gate did not build" >&2; exit 2; }
# the agent, with no environment at all; $port is read when it runs
ag() { env -i CANCHO_AGENT_BIN="$exe" /bin/sh "$root/scripts/cancho-agent.sh" --provider ollama --model stub-model:1b --port "$port" "$@"; }
cat > "$d/stub.py" <<'PY'
import http.server, json, sys
out = sys.argv[1]
n_requests = 0
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        open(out + "/request.json", "wb").write(body)
        global n_requests
        n_requests += 1
        try:
            reply = open(out + "/response.%d.txt" % n_requests).read()   # a case may script the answers in order
        except OSError:
            reply = None
        try:
            if reply is None: reply = open(out + "/response.txt").read()      # or set one answer
        except OSError:
            reply = "```cancho\nedition 7;\nfn fixed() -> [] int { return 1; }\n```\n"
        try:
            reason = open(out + "/response.%d.reason" % n_requests).read().strip()   # a case may say why the model stopped
        except OSError:
            reason = "stop"
        answer = {"response": reply, "eval_count": 7, "done_reason": reason}
        data = json.dumps(answer).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(out + "/port", "w").write(str(s.server_address[1]))
s.serve_forever()
PY
python3 "$d/stub.py" "$d" & stub=$!
n=0; while [ ! -s "$d/port" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
port=$(cat "$d/port")

printf 'edition 7;\nfn broken() -> [] int { return true; }\n' > "$d/project.cho"
printf '{"refused":[{"rule":"type-mismatch","message":"expected `int`, found `bool`","position":{"line":2,"column":30}}]}\n' > "$d/project.cho.feedback"

ag "$d/project.cho" >/dev/null 2>"$d/err"
rc=$?
expect "env: exit code with no environment" "$rc" 0

req=$(cat "$d/request.json" 2>/dev/null)
parsed=$(printf '%s' "$req" | python3 -c "
import json, sys
r = json.load(sys.stdin)
print(r.get('model')); print(r.get('think')); print(r.get('stream'))
p = r.get('prompt', '')
print('fn broken' in p); print('type-mismatch' in p and 'expected \`int\`, found \`bool\`' in p)" 2>&1)
expect "request: model" "$(printf '%s\n' "$parsed" | sed -n 1p)" stub-model:1b
expect "request: thinking off" "$(printf '%s\n' "$parsed" | sed -n 2p)" False
expect "request: streaming off" "$(printf '%s\n' "$parsed" | sed -n 3p)" False
expect "request: the prompt holds the project file" "$(printf '%s\n' "$parsed" | sed -n 4p)" True
expect "request: the prompt holds the refusal" "$(printf '%s\n' "$parsed" | sed -n 5p)" True
# the refusal's own source line, with a caret under the column: a model that is told "line 2, column 30" rarely finds it by counting
excerpt=$(printf '%s' "$req" | python3 -c "
import json, sys
p = json.load(sys.stdin).get('prompt', '')
i = p.find('line 2, column 30')
print(p[i:i + 400] if i >= 0 else 'MISSING')" 2>&1)
case "$excerpt" in *'fn broken() -> [] int { return true; }'*) ;; *) echo "FAIL: request: the refusal does not show its source line" >&2; fail=1 ;; esac
col=$(printf '%s\n' "$excerpt" | grep -n '^ *\^ *$' | head -1 | cut -d: -f2)
want=$(printf '%*s^' 33 '')    # 4 spaces of indent + 29 columns before column 30 = 33
[ "$col" = "$want" ] || { echo "FAIL: request: the caret is not under column 30 (got '$col')" >&2; fail=1; }

expect "rewrite: the file is the answer, fence stripped" "$(cat "$d/project.cho")" "edition 7;
fn fixed() -> [] int { return 1; }"

kill $stub 2>/dev/null; wait $stub 2>/dev/null
# away: nothing listens on that port any more
printf 'edition 7;\nfn keep() -> [] int { return 2; }\n' > "$d/keep.cho"; cp "$d/keep.cho" "$d/before.cho"
ag "$d/keep.cho" >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] || { echo "FAIL: away: exit code 0 with no server" >&2; fail=1; }
expect "away: no server is exit 1, not a gave-up code" "$rc" 1
expect "away: the file is untouched" "$(cat "$d/keep.cho")" "$(cat "$d/before.cho")"

# model: there is no default model, and no default provider. Missing or empty is exit 2, the flag named, the file untouched, no request made
python3 "$d/stub.py" "$d" & stub=$!
rm -f "$d/port" "$d/request.json"; n=0; while [ ! -s "$d/port" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done; port=$(cat "$d/port")
printf 'edition 7;\nfn keep() -> [] int { return 2; }\n' > "$d/nm.cho"; cp "$d/nm.cho" "$d/nm.before"
bare() { env -i CANCHO_AGENT_BIN="$exe" /bin/sh "$root/scripts/cancho-agent.sh" "$@" "$d/nm.cho" >/dev/null 2>"$d/nm.err"; }
bare --provider ollama --port "$port"; expect "model: no --model is exit 2" "$?" 2
grep -q -- --model "$d/nm.err" || { echo "FAIL: model: the refusal does not name --model" >&2; fail=1; }
bare --provider ollama --model "" --port "$port"; expect "model: an empty --model is exit 2" "$?" 2
bare --model m --port "$port"; expect "provider: no --provider is exit 2" "$?" 2
grep -q -- --provider "$d/nm.err" || { echo "FAIL: provider: the refusal does not name --provider" >&2; fail=1; }
[ ! -e "$d/request.json" ] || { echo "FAIL: model/provider: a request was made" >&2; fail=1; }
expect "model: the file is untouched" "$(cat "$d/nm.cho")" "$(cat "$d/nm.before")"
kill $stub 2>/dev/null; wait $stub 2>/dev/null

# task: a project unit leaves <project>.task beside the file (docs/project.md): what to write, with the signature and the examples. It goes in
# the prompt, ahead of the file; without one the prompt has no task
python3 "$d/stub.py" "$d" & stub=$!
rm -f "$d/port" "$d/request.json"; n=0; while [ ! -s "$d/port" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done; port=$(cat "$d/port")
printf 'UNIT: refill\nFUNCTION: bucket_refill\nSIGNATURE: fn bucket_refill(a: int) -> [] int\nEXAMPLES:\nbucket_refill(1) == 2\n' > "$d/unit.cho.task"
printf 'edition 7;\nfn broken() -> [] int { return true; }\n' > "$d/unit.cho"
ag "$d/unit.cho" >/dev/null 2>&1
treq=$(python3 -c "
import json; p = json.load(open('$d/request.json'))['prompt']
i = p.find('UNIT: refill'); j = p.find('fn broken')
print(i >= 0, j >= 0, 0 <= i < j, 'bucket_refill(1) == 2' in p)")
expect "task: the task is in the prompt, ahead of the file" "$treq" "True True True True"
rm -f "$d/unit.cho.task"
printf 'edition 7;\nfn broken() -> [] int { return true; }\n' > "$d/unit.cho"
ag "$d/unit.cho" >/dev/null 2>&1
expect "task: absent when there is none" "$(grep -c 'UNIT: refill' "$d/request.json")" 0
kill $stub 2>/dev/null; wait $stub 2>/dev/null

# bound: generation is capped (num_predict), because an unbounded generation held the first real acceptance run for 900 s on one turn
expect "request: generation is bounded" "$(printf '%s' "$req" | python3 -c "import json,sys; print(json.load(sys.stdin)['options'].get('num_predict'))")" 8192

# fences: a model often explains first; the file is the fenced block, not the prose around it
python3 "$d/stub.py" "$d" & stub=$!
rm -f "$d/port"; n=0; while [ ! -s "$d/port" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done; port=$(cat "$d/port")
printf 'Here is the corrected program:\n\n```cancho\nedition 7;\nfn good() -> [] int { return 3; }\n```\n\nIt returns three.\n' > "$d/response.txt"
printf 'edition 7;\nfn a() -> [] int { return true; }\n' > "$d/prose.cho"
ag "$d/prose.cho" >/dev/null 2>&1
expect "fences: prose around a fenced block" "$(cat "$d/prose.cho")" "edition 7;
fn good() -> [] int { return 3; }"
printf 'edition 7;\nfn plain() -> [] int { return 4; }\n' > "$d/response.txt"
printf 'edition 7;\nfn a() -> [] int { return true; }\n' > "$d/plain.cho"
ag "$d/plain.cho" >/dev/null 2>&1
expect "fences: an answer with no fence is the file" "$(cat "$d/plain.cho")" "edition 7;
fn plain() -> [] int { return 4; }"
# an unopened fence (code, then a closing fence) and an unclosed one (a fence, then code): the stray fence must not stay in the file
printf 'edition 7;\nfn unopened() -> [] int { return 5; }\n```\n' > "$d/response.txt"
printf 'edition 7;\nfn a() -> [] int { return true; }\n' > "$d/unopened.cho"
ag "$d/unopened.cho" >/dev/null 2>&1
expect "fences: a closing fence with no opening one is dropped" "$(cat "$d/unopened.cho")" "edition 7;
fn unopened() -> [] int { return 5; }"
printf '```cancho\nedition 7;\nfn unclosed() -> [] int { return 6; }\n' > "$d/response.txt"
printf 'edition 7;\nfn a() -> [] int { return true; }\n' > "$d/unclosed.cho"
ag "$d/unclosed.cho" >/dev/null 2>&1
expect "fences: an opening fence with no closing one is dropped" "$(cat "$d/unclosed.cho")" "edition 7;
fn unclosed() -> [] int { return 6; }"
printf '```cancho\nedition 7;\nfn small() -> [] int { return 1; }\n```\nand also\n```\nedition 7;\nfn big() -> [] int { return 2; }\nfn main2() -> [] int { return 0; }\n```\n' > "$d/response.txt"
printf 'edition 7;\nfn a() -> [] int { return true; }\n' > "$d/two.cho"
ag "$d/two.cho" >/dev/null 2>&1
expect "fences: with several blocks the longest is the file" "$(sed -n 2p "$d/two.cho")" "fn big() -> [] int { return 2; }"
kill $stub 2>/dev/null; wait $stub 2>/dev/null
rm -f "$d/response.txt"

# reasoning: a reply with no code in it (the model's own reasoning, cut off) is not a file. It is retried as a fresh sample; the project is
# never overwritten with prose; and if every sample is prose the agent fails (the driver names that `agent_exit`)
python3 "$d/stub.py" "$d" & stub=$!
rm -f "$d/port" "$d"/response*.txt; n=0; while [ ! -s "$d/port" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done; port=$(cat "$d/port")
printf 'Wait, `option.None` and `option.Some` syntax.\nLet me think about the struct.\n' > "$d/response.1.txt"
printf 'Hmm, one more detail about main.\n' > "$d/response.2.txt"
printf 'edition 7;\nfn third() -> [] int { return 7; }\n' > "$d/response.3.txt"
printf 'edition 7;\nfn a() -> [] int { return true; }\n' > "$d/retry.cho"
ag "$d/retry.cho" >/dev/null 2>&1; rc=$?
expect "reasoning: exit code after two prose samples and one file" "$rc" 0
expect "reasoning: the third sample is the file" "$(cat "$d/retry.cho")" "edition 7;
fn third() -> [] int { return 7; }"
kill $stub 2>/dev/null; wait $stub 2>/dev/null
python3 "$d/stub.py" "$d" & stub=$!
rm -f "$d/port" "$d"/response*.txt; n=0; while [ ! -s "$d/port" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done; port=$(cat "$d/port")
printf 'Wait, I think the answer is long.\n' > "$d/response.txt"
printf 'edition 7;\nfn keep() -> [] int { return 8; }\n' > "$d/prose.cho"; cp "$d/prose.cho" "$d/prose.before"
ag "$d/prose.cho" >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] || { echo "FAIL: reasoning: exit code 0 when every sample was prose" >&2; fail=1; }
expect "reasoning: the file is untouched" "$(cat "$d/prose.cho")" "$(cat "$d/prose.before")"
# a leaked reasoning marker: the program, then a closing fence and `</think>` (seen on the first real acceptance runs: it left a stray
# backtick at the end of the file), or reasoning, `</think>`, then the program
printf 'edition 7;\nfn before() -> [] int { return 10; }\n```\n</think>\n' > "$d/response.txt"
printf 'edition 7;\nfn a() -> [] int { return true; }\n' > "$d/think1.cho"
ag "$d/think1.cho" >/dev/null 2>&1
expect "think: a closing fence and </think> after the program are dropped" "$(cat "$d/think1.cho")" "edition 7;
fn before() -> [] int { return 10; }"
printf 'Let me think: edition 7; is the header.\n</think>\n\nedition 7;\nfn after_tag() -> [] int { return 11; }\n' > "$d/response.txt"
printf 'edition 7;\nfn a() -> [] int { return true; }\n' > "$d/think2.cho"
ag "$d/think2.cho" >/dev/null 2>&1
expect "think: the program after </think> is the file, not a mention in the reasoning" "$(cat "$d/think2.cho")" "edition 7;
fn after_tag() -> [] int { return 11; }"
# a preamble before the code, with no fence: the file starts at the edition line
printf 'Here you go.\n\nedition 7;\nfn after() -> [] int { return 9; }\n' > "$d/response.txt"
printf 'edition 7;\nfn a() -> [] int { return true; }\n' > "$d/pre.cho"
ag "$d/pre.cho" >/dev/null 2>&1
expect "reasoning: a preamble before the code is cut" "$(cat "$d/pre.cho")" "edition 7;
fn after() -> [] int { return 9; }"
kill $stub 2>/dev/null; wait $stub 2>/dev/null
rm -f "$d"/response*.txt

# raw: --save-raw <file> appends every raw reply (before anything is cut out of it) to that file, so what a model actually wrote can be
# read afterwards; the trail records only what the checker said about the result
python3 "$d/stub.py" "$d" & stub=$!
rm -f "$d/port" "$d"/response*.txt "$d"/response*.reason; n=0; while [ ! -s "$d/port" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done; port=$(cat "$d/port")
printf 'Some prose first.\n\nedition 7;\nfn raw_one() -> [] int { return 14; }\n\n- a trailing note\n' > "$d/response.txt"
printf 'edition 7;\nfn a() -> [] int { return true; }\n' > "$d/raw.cho"; rm -f "$d/raw.out"
ag --save-raw "$d/raw.out" "$d/raw.cho" >/dev/null 2>&1
case "$(cat "$d/raw.out" 2>/dev/null)" in *"Some prose first."*"- a trailing note"*) ;; *) echo "FAIL: raw: the raw reply was not saved whole ('$(cat "$d/raw.out" 2>/dev/null | head -c 80)')" >&2; fail=1 ;; esac
ag "$d/raw.cho" >/dev/null 2>&1
expect "raw: nothing is saved unless asked" "$(grep -c 'Some prose first' "$d/raw.out")" 1
kill $stub 2>/dev/null; wait $stub 2>/dev/null
rm -f "$d"/response*.txt "$d"/response*.reason

# patch output (--output patch): the model returns only the code to add or change; a program splices it into the file
mkpatch() { printf 'edition 7;\nimport std.result;\n\nfn keep() -> [] int { return 1; }\n\nfn change() -> [] int { return 2; }\n' > "$d/pt.cho"; printf 'UNIT: add\nFUNCTION: added\n' > "$d/pt.cho.task"; rm -f "$d/ulog.pt"; }
python3 "$d/stub.py" "$d" & stub=$!
rm -f "$d/port" "$d"/response*.txt "$d"/request.json; n=0; while [ ! -s "$d/port" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done; port=$(cat "$d/port")
mkpatch; printf 'Here you go:\n```cancho\nfn added() -> [] int { return 3; }\n```\nDone.\n' > "$d/response.txt"
ag --output patch --usage-log "$d/ulog.pt" "$d/pt.cho" >/dev/null 2>&1; rc=$?
expect "patch: exit code" "$rc" 0
printf 'edition 7;\nimport std.result;\n\nfn keep() -> [] int { return 1; }\n\nfn change() -> [] int { return 2; }\n\nfn added() -> [] int { return 3; }\n' > "$d/pt.want"
cmp -s "$d/pt.cho" "$d/pt.want" || { echo "FAIL: patch: the new function is not appended and the rest kept byte for byte" >&2; fail=1; }
case "$(python3 -c "import json; print(json.load(open('$d/request.json'))['prompt'])")" in *"ADD or CHANGE"*"fn keep()"*) ;; *) echo "FAIL: patch: the prompt does not ask for only the code to add or change (and show the file)" >&2; fail=1 ;; esac
expect "patch: usage outcome" "$(python3 -c "import json; print([json.loads(l)['outcome'] for l in open('$d/ulog.pt')])")" "['written']"
mkpatch; printf 'fn change() -> [] int { return 20; }\n' > "$d/response.txt"
ag --output patch "$d/pt.cho" >/dev/null 2>&1
printf 'edition 7;\nimport std.result;\n\nfn keep() -> [] int { return 1; }\n\nfn change() -> [] int { return 20; }\n' > "$d/pt.want"
cmp -s "$d/pt.cho" "$d/pt.want" || { echo "FAIL: patch: a function with the same name is not replaced in place" >&2; fail=1; }
mkpatch; printf 'edition 7;\nimport std.result;\n\nfn keep() -> [] int { return 1; }\n\nfn change() -> [] int { return 2; }\n' > "$d/response.txt"
cp "$d/pt.cho" "$d/pt.before"
ag --output patch "$d/pt.cho" >/dev/null 2>&1; rc=$?
expect "patch: a whole-file reply is accepted as a patch (exit)" "$rc" 0
cmp -s "$d/pt.cho" "$d/pt.before" || { echo "FAIL: patch: re-sending the whole file changed it" >&2; fail=1; }
mkpatch; printf 'I am not sure what to write here.\n' > "$d/response.txt"; cp "$d/pt.cho" "$d/pt.before"; rm -f "$d/ulog.pt"
ag --output patch --usage-log "$d/ulog.pt" "$d/pt.cho" >/dev/null 2>&1; rc=$?
expect "patch: prose only is exit 11 (gave up, no program)" "$rc" 11
cmp -s "$d/pt.cho" "$d/pt.before" || { echo "FAIL: patch: the file changed though nothing usable came back" >&2; fail=1; }
expect "patch: three samples, all no_program" "$(python3 -c "import json; print([json.loads(l)['outcome'] for l in open('$d/ulog.pt')])")" "['no_program', 'no_program', 'no_program']"
kill $stub 2>/dev/null; wait $stub 2>/dev/null
python3 "$d/stub.py" "$d" & stub=$!
rm -f "$d/port" "$d"/response*.txt; n=0; while [ ! -s "$d/port" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done; port=$(cat "$d/port")
mkpatch; printf 'fn broken() -> [] int { return 1;\n' > "$d/response.1.txt"; printf 'fn added() -> [] int { return 3; }\n' > "$d/response.2.txt"; rm -f "$d/response.txt" "$d/ulog.pt"
ag --output patch --usage-log "$d/ulog.pt" "$d/pt.cho" >/dev/null 2>&1; rc=$?
expect "patch: an item that never closes is retried (exit)" "$rc" 0
expect "patch: ... and logged" "$(python3 -c "import json; print([json.loads(l)['outcome'] for l in open('$d/ulog.pt')])")" "['splice_error', 'written']"
kill $stub 2>/dev/null; wait $stub 2>/dev/null
rm -f "$d"/response*.txt
ag --output bogus "$d/pt.cho" >/dev/null 2>&1; expect "patch: an unknown --output is exit 2" "$?" 2

# truncated: a reply that stopped because it hit the generation bound (done_reason "length") is cut off mid-program, not an answer. Written
# to the project it left `expected ..., found end of file` as the refusal, which a model cannot act on (the first CSV runs: 7 of 12 units).
python3 "$d/stub.py" "$d" & stub=$!
rm -f "$d/port" "$d"/response*.txt "$d"/response*.reason; n=0; while [ ! -s "$d/port" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done; port=$(cat "$d/port")
printf 'edition 7;\nfn cut_off() -> [] int {\n    var i = 0;\n    while i < 3 {\n' > "$d/response.1.txt"; printf 'length' > "$d/response.1.reason"
printf 'edition 7;\nfn also_cut() -> [] int {\n' > "$d/response.2.txt"; printf 'length' > "$d/response.2.reason"
printf 'edition 7;\nfn whole() -> [] int { return 12; }\n' > "$d/response.3.txt"
printf 'edition 7;\nfn a() -> [] int { return true; }\n' > "$d/trunc.cho"
ag "$d/trunc.cho" >/dev/null 2>&1; rc=$?
expect "truncated: exit code after two cut-off samples and one whole one" "$rc" 0
expect "truncated: the whole sample is the file" "$(cat "$d/trunc.cho")" "edition 7;
fn whole() -> [] int { return 12; }"
kill $stub 2>/dev/null; wait $stub 2>/dev/null
python3 "$d/stub.py" "$d" & stub=$!
rm -f "$d/port" "$d"/response*.txt "$d"/response*.reason; n=0; while [ ! -s "$d/port" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done; port=$(cat "$d/port")
printf 'edition 7;\nfn cut_off() -> [] int {\n' > "$d/response.txt"; printf 'length' > "$d/response.1.reason"; cp "$d/response.1.reason" "$d/response.2.reason"; cp "$d/response.1.reason" "$d/response.3.reason"
printf 'edition 7;\nfn keep() -> [] int { return 13; }\n' > "$d/alltrunc.cho"; cp "$d/alltrunc.cho" "$d/alltrunc.before"
ag "$d/alltrunc.cho" >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] || { echo "FAIL: truncated: exit code 0 when every sample was cut off" >&2; fail=1; }
expect "truncated: the file is untouched when every sample was cut off" "$(cat "$d/alltrunc.cho")" "$(cat "$d/alltrunc.before")"
kill $stub 2>/dev/null; wait $stub 2>/dev/null
rm -f "$d"/response*.txt "$d"/response*.reason

# primer: --primer names a file whose text goes first in the prompt (the intended one is `cancho agent-guidelines > file`: the
# language's own page for an agent, generated from the binary); without it the prompt has no primer
python3 "$d/stub.py" "$d" & stub=$!
rm -f "$d/port"; n=0; while [ ! -s "$d/port" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done; port=$(cat "$d/port")
printf 'PRIMER-SENTINEL: a function is written fn name() -> [] int\n' > "$d/primer.md"
printf 'edition 7;\nfn a() -> [] int { return true; }\n' > "$d/with.cho"; cp "$d/with.cho" "$d/without.cho"
ag --primer "$d/primer.md" "$d/with.cho" >/dev/null 2>&1
expect "primer: in the prompt when named" "$(grep -c PRIMER-SENTINEL "$d/request.json")" 1
ag "$d/without.cho" >/dev/null 2>&1
expect "primer: absent when not named" "$(grep -c PRIMER-SENTINEL "$d/request.json")" 0
ag --primer "$d/nope.md" "$d/without.cho" >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] || { echo "FAIL: primer: a primer file that cannot be read must not be silently skipped" >&2; fail=1; }
kill $stub 2>/dev/null; wait $stub 2>/dev/null

# memory: the unit agent run with --memory <dir>; the lessons come from tests/lessons/memory/good (the gate of the memory is scripts/test-lessons.sh)
python3 "$d/stub.py" "$d" & stub=$!
rm -f "$d/port" "$d/request.json"; n=0; while [ ! -s "$d/port" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done; port=$(cat "$d/port")
good="$root/tests/lessons/memory/good"
mfeed() { printf '{\n  "refused": [\n    {\n      "rule": "%s",\n      "message": "%s",\n      "position": { "line": 2, "column": 30 }\n    }\n  ]\n}\n' "$1" "$2" > "$d/mem.cho.feedback"; }
mkmem() { printf 'edition 7;\nfn broken() -> [] int { return true; }\n' > "$d/mem.cho"; printf 'UNIT: refill\nFUNCTION: bucket_refill\n' > "$d/mem.cho.task"; rm -rf "$d/mem.cho.call"; mkdir "$d/mem.cho.call"; rm -f "$d/request.json"; }
mkmem; mfeed type-mismatch 'expected `&[byte]`, found `Buffer`'
ag --memory "$good" "$d/mem.cho" >/dev/null 2>&1; expect "memory: exit code" "$?" 0
mreq=$(python3 -c "
import json; p = json.load(open('$d/request.json'))['prompt']
print('Known pitfalls' in p, '+    let n = len(buffer.bytes(b));' in p, 'no network' in p, 0 <= p.find('Known pitfalls') < p.find('\\n---\\n'), 'UNIT: refill' in p)")
expect "memory: the pitfalls block with its fix, the facts, ahead of the file" "$mreq" "True True True True True"
expect "memory: the sidecar names the lesson and the facts" "$(python3 -c "import json; print([m['id'] for m in json.load(open('$d/mem.cho.call/memory.json'))])")" "['L864bef6c', 'F1', 'F2']"
expect "memory: the task file is as it was" "$(cat "$d/mem.cho.task")" "UNIT: refill
FUNCTION: bucket_refill"
mkmem; mfeed type-mismatch 'expected `&[byte]`, found `Buffer`'
ag "$d/mem.cho" >/dev/null 2>&1
expect "memory: nothing without --memory" "$(grep -c 'Known pitfalls\|no network' "$d/request.json")" 0
[ ! -e "$d/mem.cho.call/memory.json" ] || { echo "FAIL: memory: a sidecar without --memory" >&2; fail=1; }
mkmem; mfeed not-a-function '`empty` is not a function in this program'
ag --memory "$good" "$d/mem.cho" >/dev/null 2>&1
expect "memory: a superseded lesson is not recalled (the facts still are)" "$(python3 -c "
import json; p = json.load(open('$d/request.json'))['prompt']
print('Known pitfalls' in p, 'no network' in p)")" "False True"
mkmem; mfeed type-mismatch 'expected `int`, found `float`'
ag --memory "$good" "$d/mem.cho" >/dev/null 2>&1
expect "memory: another class is not recalled" "$(grep -c 'Known pitfalls' "$d/request.json")" 0
rm -rf "$d/mem.cho.call"; mkmem; rm -rf "$d/mem.cho.call"; mfeed type-mismatch 'expected `&[byte]`, found `Buffer`'
ag --memory "$good" "$d/mem.cho" >/dev/null 2>&1; expect "memory: no .call directory is no error" "$?" 0
[ ! -e "$d/mem.cho.call" ] || { echo "FAIL: memory: the agent made the .call directory" >&2; fail=1; }
ag --memory "$d/no-such-memory" "$d/mem.cho" >/dev/null 2>&1; expect "memory: a memory directory that is not there is no error" "$?" 0
kill $stub 2>/dev/null; wait $stub 2>/dev/null

rm -rf "$d"
[ "$fail" = 0 ] && echo "native ollama agent gate: ok" || { echo "native ollama agent gate: FAILED" >&2; exit 1; }
