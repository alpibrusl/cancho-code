#!/bin/sh
# The native agent gate: src/cancho_agent.cho against a TLS stub of the Messages API. The cases are those of the Python agent this program
# replaced (scripts/agent-anthropic.sh, removed): what the agent promises did not change when the Python went.
#
#   request   key as x-api-key, anthropic-version, content-type; model, max_tokens, one user message holding the file and the checker's
#             refusal; the primer a cached `system` block and not repeated in the message; no primer, no system block
#   rewrite   the project file becomes the reply's program (fence cut)
#   key       the key is in no output (stdout, stderr, the saved raw replies); a missing, empty or unnamed key file is an error, no request
#   usage     the saved raw reply records the token usage the API reported; --usage-log writes one JSON line per API call (tokens in, out, thinking (inside out), cache write,
#             cache read, stop reason, outcome, sizes, milliseconds, the task's first line), for every outcome including an API error, never the key
#   workspace the id is sent as anthropic-workspace-id only when named
#   thinking  thinking and effort are sent only when named; a bad value is exit 2 and no request; an all-thinking reply says so
#   cut off   a reply that stopped at max_tokens is retried, never written
#   no program three replies with no program in them: exit 1, the file untouched
#   error     an HTTP error is exit 1 with the API's own message, one request, the file untouched
#   required  no --provider, no --model: exit 2 before any request (there is no default)
#   tls       the server is verified against --roots; a bundle without the CA, a certificate for another name, no server: refused, file untouched
#   env       it works with no environment at all (env -i)
#
# Not ported: the Python agent refuses a key file that group or others can read. cancho has no `stat`, so the mode cannot be read.
set -u

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "no python3 on PATH" >&2; exit 2; }
command -v openssl >/dev/null 2>&1 || { echo "no openssl on PATH" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
C="${CANCHO_PACKAGES:-}"
[ -d "$C" ] || C="$(dirname "$(dirname "$(dirname "$(command -v "$CANCHO")")")")/packages"
[ -d "$C" ] || { echo "no cancho packages found; set CANCHO_PACKAGES" >&2; exit 2; }
fail=0
expect() { [ "$2" = "$3" ] || { echo "FAIL: $1: wanted '$3', got '$2'" >&2; fail=1; }; }

d=$(mktemp -d -t cc-native-agent-XXXXXX)
exe="$d/agent"
"$CANCHO" build "$root/src/cancho_agent.cho" "$root/src/anthropic.cho" "$root/src/ollama.cho" "$root/src/prompt.cho" "$root/src/planprompt.cho" "$root/src/plan.cho" "$root/src/cases.cho" "$root/src/review.cho" "$root/src/provider.cho" "$root/src/reply.cho" \
    "$root/vendor/fetch_io.cho" "$C"/http-client/*.cho "$C"/tls/*.cho "$C"/x509/*.cho --std --backend cranelift -o "$exe" >/dev/null 2>"$d/build.err" \
    || { cat "$d/build.err" >&2; echo "gate did not build" >&2; exit 2; }

KEY="sk-ant-test-0123456789-not-a-real-key"
printf '%s\n' "$KEY" > "$d/key"
cat > "$d/stub.py" <<'PY'
import http.server, json, os, ssl, sys
out, key = sys.argv[1], sys.argv[2]
n_requests = 0
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        global n_requests
        n_requests += 1
        body = self.rfile.read(int(self.headers["Content-Length"]))
        open(out + "/request.json", "wb").write(body)
        open(out + "/count", "w").write(str(n_requests))
        open(out + "/headers.json", "w").write(json.dumps({
            "path": self.path, "key_matches": self.headers.get("x-api-key") == key,
            "version": self.headers.get("anthropic-version"), "content_type": self.headers.get("content-type"),
            "workspace": self.headers.get("anthropic-workspace-id")}))
        if self.headers.get("x-api-key") != key:
            data = json.dumps({"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}}).encode()
            self.send_response(401)
        elif os.path.exists(out + "/force-error"):
            data = json.dumps({"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}}).encode()
            self.send_response(529)
        else:
            try: reply = open(out + "/response.%d.txt" % n_requests).read()
            except OSError:
                try: reply = open(out + "/response.txt").read()
                except OSError: reply = "```cancho\nedition 7;\nfn fixed() -> [] int { return 1; }\n```\n"
            try: stop = open(out + "/response.%d.stop" % n_requests).read().strip()
            except OSError: stop = "end_turn"
            data = json.dumps({"id": "msg_x", "type": "message", "role": "assistant", "model": "stub",
                               "content": [{"type": "text", "text": reply}], "stop_reason": stop, "usage": {"input_tokens": 11, "output_tokens": 22, "cache_creation_input_tokens": 33, "cache_read_input_tokens": 44, "output_tokens_details": {"thinking_tokens": 7}}}).encode()
            self.send_response(200)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(data)))
        self.end_headers(); self.wfile.write(data)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(sys.argv[3], sys.argv[4])
s.socket = ctx.wrap_socket(s.socket, server_side=True)
open(out + "/port", "w").write(str(s.server_address[1]))
s.serve_forever()
PY
mkcert() { openssl req -newkey rsa:2048 -nodes -keyout "$d/$1.key" -out "$d/$1.csr" -subj "/CN=$2" >/dev/null 2>&1
           printf 'subjectAltName=DNS:%s\nauthorityKeyIdentifier=keyid,issuer\nsubjectKeyIdentifier=hash\nbasicConstraints=CA:FALSE\n' "$2" > "$d/$1.cnf"
           openssl x509 -req -in "$d/$1.csr" -CA "$d/ca.pem" -CAkey "$d/ca.key" -CAcreateserial -out "$d/$1.pem" -days 1 -extfile "$d/$1.cnf" >/dev/null 2>&1; }
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$d/ca.key" -out "$d/ca.pem" -subj "/CN=cc-test-ca" -days 1 -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$d/other.key" -out "$d/other.pem" -subj "/CN=some-other-ca" -days 1 -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
mkcert srv localhost
mkcert wrong elsewhere.example

start() { rm -f "$d/port" "$d/count" "$d/request.json" "$d/headers.json" "$d/force-error"; python3 "$d/stub.py" "$d" "$KEY" "${1:-$d/srv.pem}" "${2:-$d/srv.key}" & stub=$!
          n=0; while [ ! -s "$d/port" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done; port=$(cat "$d/port"); }
stop() { kill $stub 2>/dev/null; wait $stub 2>/dev/null; }
F="$d/project.cho"
broken() { printf 'edition 7;\nfn broken() -> [] int { return true; }\n' > "$F"; printf '{"refused":[{"rule":"type-mismatch","message":"expected `int`, found `bool`","position":{"line":2,"column":30}}]}\n' > "$F.feedback"; }
printf 'A PRIMER SENTENCE ABOUT CANCHO.\n' > "$d/primer.md"
# the agent, with no environment at all; the flags a caller must name come first, `$@` adds or overrides nothing (first value wins for a repeated flag)
agent() { env -i "$exe" --provider anthropic --model stub-model --key-file "${KEYFILE:-$d/key}" --host localhost --ip 127.0.0.1 --port "$port" --roots "${ROOTS:-$d/ca.pem}" "$@" "$F"; }
count() { cat "$d/count" 2>/dev/null || echo 0; }
req() { python3 -c "import json; r = json.load(open('$d/request.json')); print(json.dumps([r.get('thinking'), r.get('output_config')]))"; }

# request, rewrite, key, usage
start
broken
agent --primer "$d/primer.md" --save-raw "$d/raw.txt" >"$d/out.txt" 2>"$d/err.txt"; rc=$?
expect "rewrite: exit code (stderr: $(head -c 300 "$d/err.txt"))" "$rc" 0
expect "rewrite: the file is the program, fence cut" "$(cat "$F")" "edition 7;
fn fixed() -> [] int { return 1; }"
printf 'edition 7;\nfn fixed() -> [] int { return 1; }\n' > "$d/want.cho"
cmp -s "$F" "$d/want.cho" || { echo "FAIL: rewrite: the file is not exactly the program and one newline" >&2; fail=1; }
h=$(cat "$d/headers.json" 2>/dev/null)
expect "request: path" "$(printf '%s' "$h" | python3 -c "import json,sys; print(json.load(sys.stdin)['path'])")" /v1/messages
expect "request: the key from the file is sent as x-api-key" "$(printf '%s' "$h" | python3 -c "import json,sys; print(json.load(sys.stdin)['key_matches'])")" True
expect "request: anthropic-version is sent" "$(printf '%s' "$h" | python3 -c "import json,sys; print(json.load(sys.stdin)['version'])")" 2023-06-01
expect "request: content-type" "$(printf '%s' "$h" | python3 -c "import json,sys; print(json.load(sys.stdin)['content_type'])")" application/json
parsed=$(python3 -c "
import json
r = json.load(open('$d/request.json'))
print(r.get('model')); print(r.get('max_tokens'))
m = r['messages']; print(len(m) == 1 and m[0]['role'] == 'user')
c = m[0]['content']
print('fn broken' in c and 'expected \`int\`, found \`bool\`' in c)
s = r.get('system')
print(isinstance(s, list) and s[0].get('cache_control', {}).get('type') == 'ephemeral' and 'A PRIMER SENTENCE' in s[0]['text'])
print('A PRIMER SENTENCE' in c)")
expect "request: model" "$(printf '%s\n' "$parsed" | sed -n 1p)" stub-model
expect "request: max_tokens (8192 unless named)" "$(printf '%s\n' "$parsed" | sed -n 2p)" 8192
expect "request: one user message" "$(printf '%s\n' "$parsed" | sed -n 3p)" True
expect "request: the prompt holds the file and the refusal" "$(printf '%s\n' "$parsed" | sed -n 4p)" True
expect "request: the primer is a cached system block" "$(printf '%s\n' "$parsed" | sed -n 5p)" True
expect "request: the primer is not repeated in the message" "$(printf '%s\n' "$parsed" | sed -n 6p)" False
for f in out.txt err.txt raw.txt; do
    if grep -q "$KEY" "$d/$f" 2>/dev/null; then echo "FAIL: key: the key is in the agent's $f" >&2; fail=1; fi
done
[ -s "$d/raw.txt" ] || { echo "FAIL: key: the raw reply was not saved (--save-raw)" >&2; fail=1; }
case "$(cat "$d/raw.txt" 2>/dev/null)" in *"input_tokens=11 output_tokens=22 cache_creation_input_tokens=33 cache_read_input_tokens=44"*) ;; *) echo "FAIL: usage: the saved reply does not record the token usage ($(head -c 200 "$d/raw.txt"))" >&2; fail=1 ;; esac

# workspace
broken; agent >/dev/null 2>&1
expect "workspace: no header unless named" "$(python3 -c "import json; print(json.load(open('$d/headers.json'))['workspace'])")" None
broken; agent --workspace wrkspc_test_123 >/dev/null 2>&1
expect "workspace: the id is sent as anthropic-workspace-id" "$(python3 -c "import json; print(json.load(open('$d/headers.json'))['workspace'])")" wrkspc_test_123

# thinking and effort
broken; agent >/dev/null 2>&1
expect "thinking: by default neither is sent" "$(req)" "[null, null]"
broken; agent --thinking disabled >/dev/null 2>&1
expect "thinking: disabled is sent" "$(req)" '[{"type": "disabled"}, null]'
broken; agent --thinking adaptive --effort low >/dev/null 2>&1
expect "thinking: adaptive with an effort is sent" "$(req)" '[{"type": "adaptive"}, {"effort": "low"}]'
broken; agent --max-tokens 16000 >/dev/null 2>&1
expect "request: --max-tokens is sent" "$(python3 -c "import json; print(json.load(open('$d/request.json'))['max_tokens'])")" 16000
rm -f "$d/count"; broken; agent --effort bogus >"$d/out.txt" 2>"$d/err.txt"; rc=$?
expect "thinking: a bad effort is exit 2" "$rc" 2
case "$(cat "$d/err.txt")" in *low*medium*high*) ;; *) echo "FAIL: thinking: a bad effort does not list the valid ones ('$(cat "$d/err.txt")')" >&2; fail=1 ;; esac
expect "thinking: a bad effort sends no request" "$(count)" 0
rm -f "$d/count"; broken; agent --thinking sometimes >/dev/null 2>&1; rc=$?
expect "thinking: a bad thinking mode is exit 2" "$rc" 2
expect "thinking: ... and sends no request" "$(count)" 0

# no primer: no system block
broken; agent >/dev/null 2>&1
expect "request: no primer, no system block" "$(python3 -c "import json; print('system' in json.load(open('$d/request.json')))")" False

# cut off: stop_reason max_tokens is retried
stop; start
printf 'edition 7;\nfn cut_off() -> [] int {\n' > "$d/response.1.txt"; printf 'max_tokens' > "$d/response.1.stop"
printf 'edition 7;\nfn whole() -> [] int { return 2; }\n' > "$d/response.2.txt"
broken; agent >/dev/null 2>&1; rc=$?
expect "cut off: exit code" "$rc" 0
expect "cut off: the whole sample is the file" "$(cat "$F")" "edition 7;
fn whole() -> [] int { return 2; }"
expect "cut off: two requests" "$(count)" 2
rm -f "$d/response"*

# no program in any of three replies
stop; start
printf 'I think the problem is the return type; let me reason about it for a while.\n' > "$d/response.txt"
broken; cp "$F" "$d/before.cho"
agent >"$d/out.txt" 2>"$d/err.txt"; rc=$?
expect "no program: exit 1" "$rc" 1
expect "no program: three samples" "$(count)" 3
expect "no program: the file is untouched" "$(cat "$F")" "$(cat "$d/before.cho")"
# an all-thinking reply (cut off, no text) is retried and written never
stop; start
rm -f "$d/response"*; : > "$d/response.txt"; printf 'max_tokens' > "$d/response.1.stop"; printf 'max_tokens' > "$d/response.2.stop"; printf 'max_tokens' > "$d/response.3.stop"
broken; agent >"$d/out.txt" 2>"$d/err.txt"; rc=$?
expect "all thinking: exit 1" "$rc" 1
expect "all thinking: the file is untouched" "$(cat "$F")" "$(cat "$d/before.cho")"
rm -f "$d/response"*

# usage log: one JSON line per API call, whatever came of it
stop; start
printf 'edition 7;\nfn cut_off() -> [] int {\n' > "$d/response.1.txt"; printf 'max_tokens' > "$d/response.1.stop"
printf 'I think it is the return type.\n' > "$d/response.2.txt"
printf 'Fixed:\n```cancho\nedition 7;\nfn ok() -> [] int { return 1; }\n```\n' > "$d/response.3.txt"
broken; printf 'UNIT: refill\nFUNCTION: f\n' > "$F.task"; rm -f "$d/ulog.jsonl"
agent --usage-log "$d/ulog.jsonl" >/dev/null 2>&1; rc=$?
expect "usage log: exit code" "$rc" 0
python3 - "$d/ulog.jsonl" "$KEY" <<'PY' || fail=1
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
bad = []
if [r.get("outcome") for r in rows] != ["cut_off", "no_program", "written"]: bad.append("outcomes %r" % [r.get("outcome") for r in rows])
if [r.get("sample") for r in rows] != [1, 2, 3]: bad.append("samples")
for r in rows:
    for k, v in (("in", 11), ("out", 22), ("cache_write", 33), ("cache_read", 44)):
        if r.get(k) != v: bad.append("%s=%r" % (k, r.get(k)))
    if r.get("thinking") != 7: bad.append("thinking=%r (the API reported 7 thinking tokens)" % r.get("thinking"))
    if r.get("provider") != "anthropic" or r.get("model") != "stub-model": bad.append("provider/model")
    if r.get("task") != "UNIT: refill": bad.append("task %r" % r.get("task"))
    if not isinstance(r.get("ms"), int) or r["ms"] < 0: bad.append("ms")
    if not isinstance(r.get("reply_chars"), int): bad.append("reply_chars")
if [r.get("stop") for r in rows] != ["max_tokens", "end_turn", "end_turn"]: bad.append("stop %r" % [r.get("stop") for r in rows])
if rows[2].get("program_chars") != len("edition 7;\nfn ok() -> [] int { return 1; }"): bad.append("program_chars %r" % rows[2].get("program_chars"))
if rows[1].get("program_chars") != 0: bad.append("program_chars of a reply with no program")
if sys.argv[2] in open(sys.argv[1]).read(): bad.append("THE KEY IS IN THE LOG")
if bad:
    print("FAIL: usage log: " + "; ".join(bad), file=sys.stderr); sys.exit(1)
PY
rm -f "$F.task" "$d/response"*
touch "$d/force-error"; broken; rm -f "$d/ulog.jsonl"
agent --usage-log "$d/ulog.jsonl" >/dev/null 2>&1
rm -f "$d/force-error"
expect "usage log: an API error is one line with its outcome and status" "$(python3 -c "
import json; rows = [json.loads(l) for l in open('$d/ulog.jsonl')]
print(len(rows), rows[0].get('outcome'), rows[0].get('status'), rows[0].get('thinking'))" 2>&1)" "1 api_error 529 0"
broken; agent >/dev/null 2>&1
[ ! -e "$d/nolog.jsonl" ] || { echo "FAIL: usage log: a file nobody named exists" >&2; fail=1; }

# a key file: missing, empty, unnamed. No request.
stop; start
broken; cp "$F" "$d/before.cho"
(KEYFILE="$d/nope"; agent >"$d/out.txt" 2>"$d/err.txt"); rc=$?
[ "$rc" != 0 ] || { echo "FAIL: key: a missing key file was accepted" >&2; fail=1; }
: > "$d/empty.key"
(KEYFILE="$d/empty.key"; agent >"$d/out.txt" 2>"$d/err.txt"); rc=$?
[ "$rc" != 0 ] || { echo "FAIL: key: an empty key file was accepted" >&2; fail=1; }
env -i "$exe" --provider anthropic --model m --host localhost --ip 127.0.0.1 --port "$port" --roots "$d/ca.pem" "$F" >"$d/out.txt" 2>"$d/err.txt"; rc=$?
expect "key: no key file named is exit 2" "$rc" 2
case "$(cat "$d/err.txt")" in *key-file*) ;; *) echo "FAIL: key: the message does not name --key-file ('$(cat "$d/err.txt")')" >&2; fail=1 ;; esac
expect "key: no request was made" "$(count)" 0
expect "key: the file is untouched" "$(cat "$F")" "$(cat "$d/before.cho")"

# provider and model are required
rm -f "$d/count"
env -i "$exe" --model m --key-file "$d/key" --host localhost --ip 127.0.0.1 --port "$port" --roots "$d/ca.pem" "$F" >"$d/out.txt" 2>"$d/err.txt"; rc=$?
expect "required: no --provider is exit 2" "$rc" 2
case "$(cat "$d/err.txt")" in *provider*) ;; *) echo "FAIL: required: the message does not name --provider ('$(cat "$d/err.txt")')" >&2; fail=1 ;; esac
env -i "$exe" --provider anthropic --key-file "$d/key" --host localhost --ip 127.0.0.1 --port "$port" --roots "$d/ca.pem" "$F" >"$d/out.txt" 2>"$d/err.txt"; rc=$?
expect "required: no --model is exit 2" "$rc" 2
case "$(cat "$d/err.txt")" in *model*) ;; *) echo "FAIL: required: the message does not name --model ('$(cat "$d/err.txt")')" >&2; fail=1 ;; esac
env -i "$exe" --provider anthropic --model "" --key-file "$d/key" --host localhost --ip 127.0.0.1 --port "$port" --roots "$d/ca.pem" "$F" >"$d/out.txt" 2>"$d/err.txt"; rc=$?
expect "required: an empty --model is exit 2" "$rc" 2
expect "required: no request was made" "$(count)" 0

# an HTTP error, and a wrong key
touch "$d/force-error"
broken; cp "$F" "$d/before.cho"
agent >"$d/out.txt" 2>"$d/err.txt"; rc=$?
expect "error: exit 1 on an HTTP error" "$rc" 1
case "$(cat "$d/err.txt")" in *Overloaded*) ;; *) echo "FAIL: error: the API's message is not shown ('$(cat "$d/err.txt")')" >&2; fail=1 ;; esac
expect "error: one request (an API error is not retried)" "$(count)" 1
expect "error: the file is untouched" "$(cat "$F")" "$(cat "$d/before.cho")"
rm -f "$d/force-error"
printf 'sk-ant-WRONG-key\n' > "$d/wrongapi.key"
(KEYFILE="$d/wrongapi.key"; agent >"$d/out.txt" 2>"$d/err.txt"); rc=$?
expect "error: a rejected key is exit 1" "$rc" 1
case "$(cat "$d/err.txt")" in *authentication*) ;; *) echo "FAIL: error: a rejected key is not reported as such ('$(cat "$d/err.txt")')" >&2; fail=1 ;; esac
grep -q "sk-ant-WRONG-key" "$d/out.txt" "$d/err.txt" 2>/dev/null && { echo "FAIL: error: the key is in the error output" >&2; fail=1; }

# tls: the server is verified against --roots
(ROOTS="$d/other.pem"; broken; agent >"$d/out.txt" 2>"$d/err.txt"); rc=$?
[ "$rc" != 0 ] || { echo "FAIL: tls: a server whose CA is not in --roots was accepted" >&2; fail=1; }
stop; start "$d/wrong.pem" "$d/wrong.key"
broken; cp "$F" "$d/before.cho"
agent >"$d/out.txt" 2>"$d/err.txt"; rc=$?
[ "$rc" != 0 ] || { echo "FAIL: tls: a certificate for another name was accepted" >&2; fail=1; }
expect "tls: nothing reached a server with the wrong name" "$(count)" 0
expect "tls: the file is untouched" "$(cat "$F")" "$(cat "$d/before.cho")"
stop
agent >"$d/out.txt" 2>"$d/err.txt"; rc=$?
[ "$rc" != 0 ] || { echo "FAIL: away: exit 0 with no server" >&2; fail=1; }
expect "away: the file is untouched" "$(cat "$F")" "$(cat "$d/before.cho")"

# the wrapper: it resolves the host and finds the roots, with no environment but PATH; a flag after its own wins
stop; start
broken
env -i PATH=/usr/bin:/bin CANCHO_AGENT_BIN="$exe" CANCHO_AGENT_HOST=localhost CANCHO_AGENT_ROOTS="$d/ca.pem" /bin/sh "$root/scripts/cancho-agent.sh" \
    --provider anthropic --model stub-model --key-file "$d/key" --port "$port" "$F" >"$d/out.txt" 2>"$d/err.txt"; rc=$?
expect "wrapper: resolves the host and the agent writes the program (stderr: $(head -c 200 "$d/err.txt"))" "$rc" 0
cmp -s "$F" "$d/want.cho" || { echo "FAIL: wrapper: the file is not the program" >&2; fail=1; }
broken
env -i PATH=/usr/bin:/bin CANCHO_AGENT_BIN="$exe" CANCHO_AGENT_HOST=localhost CANCHO_AGENT_ROOTS="$d/other.pem" /bin/sh "$root/scripts/cancho-agent.sh" \
    --provider anthropic --model stub-model --key-file "$d/key" --port "$port" --roots "$d/ca.pem" "$F" >/dev/null 2>&1; rc=$?
expect "wrapper: a --roots after the wrapper's own wins" "$rc" 0
env -i PATH=/usr/bin:/bin CANCHO_AGENT_BIN="$exe" CANCHO_AGENT_HOST=no-such-host.invalid CANCHO_AGENT_ROOTS="$d/ca.pem" /bin/sh "$root/scripts/cancho-agent.sh" \
    --provider anthropic --model stub-model --key-file "$d/key" "$F" >"$d/out.txt" 2>"$d/err.txt"; rc=$?
[ "$rc" != 0 ] || { echo "FAIL: wrapper: an unresolvable host exited 0" >&2; fail=1; }
env -i PATH=/usr/bin:/bin CANCHO_AGENT_BIN="$exe" /bin/sh "$root/scripts/cancho-agent.sh" --model m "$F" >/dev/null 2>"$d/err.txt"; rc=$?
expect "wrapper: no provider is the agent's exit 2" "$rc" 2
stop

rm -rf "$d"
[ "$fail" = 0 ] && echo "native agent gate: ok" || { echo "native agent gate: FAILED" >&2; exit 1; }
