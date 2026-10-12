#!/bin/sh
# The Ollama agent gate (docs/parity.md P1): scripts/agent-ollama.sh against a stub server that speaks Ollama's /api/generate,
# so no model, no GPU and no network are involved. One case per promise:
#
#   request   the prompt holds the project file AND the checker's refusals (<project>.feedback); the model comes from OLLAMA_MODEL;
#             thinking is off and streaming is off (the answer is the file, not a trace)
#   rewrite   the project file becomes the model's answer, with a markdown fence stripped
#   env       it works with no environment at all (env -i): the driver gives its agent none, and ollama panics without a HOME
#   away      a server that is not there is a non-zero exit and the file is left as it was (the driver names it `agent_exit`)
#
# Needs python3 (the stub, and the script's own HTTP call; standard library only).
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
command -v python3 >/dev/null 2>&1 || { echo "no python3 on PATH" >&2; exit 2; }
fail=0
expect() { [ "$2" = "$3" ] || { echo "FAIL: $1: wanted '$3', got '$2'" >&2; fail=1; }; }

d=$(mktemp -d -t cc-ollama-d-XXXXXX)
cat > "$d/stub.py" <<'PY'
import http.server, json, sys
out = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        open(out + "/request.json", "wb").write(body)
        answer = {"response": "```cancho\nedition 7;\nfn fixed() -> [] int { return 1; }\n```\n", "eval_count": 7}
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

env -i OLLAMA_MODEL=stub-model:1b OLLAMA_URL="http://127.0.0.1:$port" /bin/sh "$root/scripts/agent-ollama.sh" "$d/project.cho" >/dev/null 2>"$d/err"
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

expect "rewrite: the file is the answer, fence stripped" "$(cat "$d/project.cho")" "edition 7;
fn fixed() -> [] int { return 1; }"

kill $stub 2>/dev/null; wait $stub 2>/dev/null
# away: nothing listens on that port any more
printf 'edition 7;\nfn keep() -> [] int { return 2; }\n' > "$d/keep.cho"; cp "$d/keep.cho" "$d/before.cho"
env -i OLLAMA_URL="http://127.0.0.1:$port" /bin/sh "$root/scripts/agent-ollama.sh" "$d/keep.cho" >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] || { echo "FAIL: away: exit code 0 with no server" >&2; fail=1; }
expect "away: the file is untouched" "$(cat "$d/keep.cho")" "$(cat "$d/before.cho")"

rm -rf "$d"
[ "$fail" = 0 ] && echo "ollama agent gate: ok" || { echo "ollama agent gate: FAILED" >&2; exit 1; }
