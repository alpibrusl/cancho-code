#!/bin/sh
# The Anthropic agent gate: scripts/agent-anthropic.sh against a stub of the Messages API (POST /v1/messages), so no key, no network and no
# spend are involved. The point of the file-based key (the driver's agent has NO environment, so ANTHROPIC_API_KEY cannot reach it, and a
# key written into the agent command would sit in the process list) is pinned here:
#
#   request   the key from the file is sent as x-api-key, with anthropic-version; the model, max_tokens and messages are right; the
#             primer (the language page) is a `system` block marked for caching, and absent when no primer is named
#   rewrite   the project file becomes the reply's program (a fence is cut)
#   key       the key is in no output of the agent (stdout, stderr, the saved raw replies); a key file that others can read is refused
#             BEFORE any request; a missing, empty or unnamed key file is an error that names ANTHROPIC_KEY_FILE
#   cut off   a reply that stopped at max_tokens is retried, never written
#   tls       the server is verified, and a CA bundle is found when the Python has none; a bundle without the CA still fails
#   error     an HTTP error is a non-zero exit with the API's own message, and the file is left as it was
#
# Needs python3 (the stub, and the script's own HTTP call; standard library only).
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
command -v python3 >/dev/null 2>&1 || { echo "no python3 on PATH" >&2; exit 2; }
fail=0
expect() { [ "$2" = "$3" ] || { echo "FAIL: $1: wanted '$3', got '$2'" >&2; fail=1; }; }

d=$(mktemp -d -t cc-anthropic-d-XXXXXX)
KEY="sk-ant-test-0123456789-not-a-real-key"
printf '%s\n' "$KEY" > "$d/key"; chmod 600 "$d/key"

cat > "$d/stub.py" <<'PY'
import http.server, json, os, sys
out, key = sys.argv[1], sys.argv[2]
n_requests = 0
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        global n_requests
        n_requests += 1
        body = self.rfile.read(int(self.headers["Content-Length"]))
        open(out + "/request.json", "wb").write(body)
        open(out + "/count", "w").write(str(n_requests))
        # what arrived, without writing the key itself anywhere
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
                               "content": [{"type": "text", "text": reply}], "stop_reason": stop, "usage": {"input_tokens": 1, "output_tokens": 1}}).encode()
            self.send_response(200)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(data)))
        self.end_headers(); self.wfile.write(data)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
if len(sys.argv) > 4:
    import ssl
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(sys.argv[3], sys.argv[4])
    s.socket = ctx.wrap_socket(s.socket, server_side=True)
open(out + "/port", "w").write(str(s.server_address[1]))
s.serve_forever()
PY
startls() { rm -f "$d/port" "$d/count" "$d/request.json" "$d/headers.json" "$d/force-error"; python3 "$d/stub.py" "$d" "$KEY" "$d/srv.pem" "$d/srv.key" & stub=$!
          n=0; while [ ! -s "$d/port" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done; port=$(cat "$d/port"); }
start() { rm -f "$d/port" "$d/count" "$d/request.json" "$d/headers.json" "$d/force-error"; python3 "$d/stub.py" "$d" "$KEY" & stub=$!
          n=0; while [ ! -s "$d/port" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done; port=$(cat "$d/port"); }
stop() { kill $stub 2>/dev/null; wait $stub 2>/dev/null; }
agent() { env -i ANTHROPIC_URL="http://127.0.0.1:$port" ANTHROPIC_KEY_FILE="${KEYFILE:-$d/key}" ANTHROPIC_MODEL=stub-model "$@" /bin/sh "$root/scripts/agent-anthropic.sh" "$F"; }

printf 'edition 7;\nfn broken() -> [] int { return true; }\n' > "$d/project.cho"
printf '{"refused":[{"rule":"type-mismatch","message":"expected `int`, found `bool`","position":{"line":2,"column":30}}]}\n' > "$d/project.cho.feedback"
printf 'A PRIMER SENTENCE ABOUT CANCHO.\n' > "$d/primer.md"
F="$d/project.cho"

# request, rewrite, key
start
agent ANTHROPIC_PRIMER="$d/primer.md" ANTHROPIC_SAVE_RAW="$d/raw.txt" >"$d/out.txt" 2>"$d/err.txt"; rc=$?
expect "rewrite: exit code" "$rc" 0
expect "rewrite: the file is the program, fence cut" "$(cat "$d/project.cho")" "edition 7;
fn fixed() -> [] int { return 1; }"
h=$(cat "$d/headers.json" 2>/dev/null)
expect "request: path" "$(printf '%s' "$h" | python3 -c "import json,sys; print(json.load(sys.stdin)['path'])")" /v1/messages
expect "request: the key from the file is sent as x-api-key" "$(printf '%s' "$h" | python3 -c "import json,sys; print(json.load(sys.stdin)['key_matches'])")" True
expect "request: anthropic-version is sent" "$(printf '%s' "$h" | python3 -c "import json,sys; print(bool(json.load(sys.stdin)['version']))")" True
parsed=$(python3 -c "
import json
r = json.load(open('$d/request.json'))
print(r.get('model')); print(isinstance(r.get('max_tokens'), int) and r['max_tokens'] > 0)
m = r['messages']; print(len(m) == 1 and m[0]['role'] == 'user')
c = m[0]['content'] if isinstance(m[0]['content'], str) else ''.join(b.get('text', '') for b in m[0]['content'])
print('fn broken' in c and 'expected \`int\`, found \`bool\`' in c)
s = r.get('system')
print(isinstance(s, list) and s[0].get('cache_control', {}).get('type') == 'ephemeral' and 'A PRIMER SENTENCE' in s[0]['text'])
print('A PRIMER SENTENCE' in c)")
expect "request: model" "$(printf '%s\n' "$parsed" | sed -n 1p)" stub-model
expect "request: max_tokens" "$(printf '%s\n' "$parsed" | sed -n 2p)" True
expect "request: one user message" "$(printf '%s\n' "$parsed" | sed -n 3p)" True
expect "request: the prompt holds the file and the refusal" "$(printf '%s\n' "$parsed" | sed -n 4p)" True
expect "request: the primer is a cached system block" "$(printf '%s\n' "$parsed" | sed -n 5p)" True
expect "request: the primer is not repeated in the message" "$(printf '%s\n' "$parsed" | sed -n 6p)" False
for f in out.txt err.txt raw.txt; do
    if grep -q "$KEY" "$d/$f" 2>/dev/null; then echo "FAIL: key: the key is in the agent's $f" >&2; fail=1; fi
done
[ -s "$d/raw.txt" ] || { echo "FAIL: key: the raw reply was not saved (ANTHROPIC_SAVE_RAW)" >&2; fail=1; }
case "$(cat "$d/raw.txt")" in *"input_tokens"*"output_tokens"*) ;; *) echo "FAIL: usage: the saved reply does not record the token usage the API reported" >&2; fail=1 ;; esac

# a key that is not scoped to a workspace needs the workspace id as a header (the API says so, in a 400, for such a key): sent when named, absent otherwise
printf 'edition 7;\nfn broken() -> [] int { return true; }\n' > "$d/project.cho"
agent >/dev/null 2>&1
expect "workspace: no header unless named" "$(python3 -c "import json; print(json.load(open('$d/headers.json'))['workspace'])")" None
printf 'edition 7;\nfn broken() -> [] int { return true; }\n' > "$d/project.cho"
agent ANTHROPIC_WORKSPACE_ID=wrkspc_test_123 >/dev/null 2>&1
expect "workspace: the id is sent as anthropic-workspace-id" "$(python3 -c "import json; print(json.load(open('$d/headers.json'))['workspace'])")" wrkspc_test_123

# thinking: Claude thinks before it answers and the thinking counts against max_tokens. On the first long runs every reply spent its whole
# bound (8192 tokens) thinking and left no answer. ANTHROPIC_THINKING (disabled or adaptive) and ANTHROPIC_EFFORT (low medium high xhigh
# max, the API's own values) are sent when named, and not otherwise; a bad value is refused before any request.
req() { python3 -c "import json; r = json.load(open('$d/request.json')); print(json.dumps([r.get('thinking'), r.get('output_config')]))"; }
printf 'edition 7;\nfn broken() -> [] int { return true; }\n' > "$d/project.cho"; agent >/dev/null 2>&1
expect "thinking: by default neither is sent" "$(req)" "[null, null]"
printf 'edition 7;\nfn broken() -> [] int { return true; }\n' > "$d/project.cho"; agent ANTHROPIC_THINKING=disabled >/dev/null 2>&1
expect "thinking: disabled is sent" "$(req)" '[{"type": "disabled"}, null]'
printf 'edition 7;\nfn broken() -> [] int { return true; }\n' > "$d/project.cho"; agent ANTHROPIC_THINKING=adaptive ANTHROPIC_EFFORT=low >/dev/null 2>&1
expect "thinking: adaptive with an effort is sent" "$(req)" '[{"type": "adaptive"}, {"effort": "low"}]'
rm -f "$d/count"; agent ANTHROPIC_EFFORT=bogus >"$d/out.txt" 2>"$d/err.txt"; rc=$?
[ "$rc" != 0 ] || { echo "FAIL: thinking: a bad effort was accepted" >&2; fail=1; }
case "$(cat "$d/err.txt")" in *low*medium*high*) ;; *) echo "FAIL: thinking: a bad effort does not list the valid ones ('$(cat "$d/err.txt")')" >&2; fail=1 ;; esac
expect "thinking: a bad effort sends no request" "$(cat "$d/count" 2>/dev/null || echo 0)" 0
rm -f "$d/count"; agent ANTHROPIC_THINKING=sometimes >"$d/out.txt" 2>"$d/err.txt"; rc=$?
[ "$rc" != 0 ] || { echo "FAIL: thinking: a bad thinking mode was accepted" >&2; fail=1; }
# a reply cut off with NO visible text: the bound was spent thinking, and the message says what to do
rm -f "$d/response"*; : > "$d/response.1.txt"; printf 'max_tokens' > "$d/response.1.stop"; : > "$d/response.2.txt"; printf 'max_tokens' > "$d/response.2.stop"; : > "$d/response.3.txt"; printf 'max_tokens' > "$d/response.3.stop"
stop; start
printf 'edition 7;\nfn broken() -> [] int { return true; }\n' > "$d/project.cho"
agent >"$d/out.txt" 2>"$d/err.txt"; rc=$?
[ "$rc" != 0 ] || { echo "FAIL: thinking: exit 0 when every reply was cut off with no text" >&2; fail=1; }
case "$(cat "$d/err.txt")" in *thinking*ANTHROPIC_THINKING*|*ANTHROPIC_THINKING*thinking*) ;; *) echo "FAIL: thinking: an all-thinking reply does not say so ('$(cat "$d/err.txt")')" >&2; fail=1 ;; esac
rm -f "$d/response"*; stop; start

# no primer: no system block
printf 'edition 7;\nfn broken() -> [] int { return true; }\n' > "$d/project.cho"
agent >/dev/null 2>&1
expect "request: no primer, no system block" "$(python3 -c "import json; print('system' in json.load(open('$d/request.json')))")" False

# cut off: stop_reason max_tokens is retried (a fresh stub: it numbers its replies by request)
stop; start
rm -f "$d/response"*
printf 'edition 7;\nfn cut_off() -> [] int {\n' > "$d/response.1.txt"; printf 'max_tokens' > "$d/response.1.stop"
printf 'edition 7;\nfn whole() -> [] int { return 2; }\n' > "$d/response.2.txt"
printf 'edition 7;\nfn broken() -> [] int { return true; }\n' > "$d/project.cho"
agent >/dev/null 2>&1; rc=$?
expect "cut off: exit code" "$rc" 0
expect "cut off: the whole sample is the file" "$(cat "$d/project.cho")" "edition 7;
fn whole() -> [] int { return 2; }"
rm -f "$d/response"*
stop

# a key file others can read is refused before any request
start
chmod 644 "$d/key"
printf 'edition 7;\nfn keep() -> [] int { return 3; }\n' > "$d/project.cho"; cp "$d/project.cho" "$d/before.cho"
agent >"$d/out.txt" 2>"$d/err.txt"; rc=$?
[ "$rc" != 0 ] || { echo "FAIL: key: a group- and world-readable key file was accepted" >&2; fail=1; }
case "$(cat "$d/err.txt")" in *permission*) ;; *) echo "FAIL: key: no message about permissions ('$(cat "$d/err.txt")')" >&2; fail=1 ;; esac
expect "key: no request was made with a readable key file" "$(cat "$d/count" 2>/dev/null || echo 0)" 0
expect "key: the file is untouched" "$(cat "$d/project.cho")" "$(cat "$d/before.cho")"
grep -q "$KEY" "$d/out.txt" "$d/err.txt" 2>/dev/null && { echo "FAIL: key: the key is in the error output" >&2; fail=1; }
chmod 600 "$d/key"

# missing, empty, unnamed
(KEYFILE="$d/nope"; agent >"$d/out.txt" 2>"$d/err.txt"); rc=$?
[ "$rc" != 0 ] || { echo "FAIL: key: a missing key file was accepted" >&2; fail=1; }
: > "$d/empty.key"; chmod 600 "$d/empty.key"
(KEYFILE="$d/empty.key"; agent >"$d/out.txt" 2>"$d/err.txt"); rc=$?
[ "$rc" != 0 ] || { echo "FAIL: key: an empty key file was accepted" >&2; fail=1; }
env -i ANTHROPIC_URL="http://127.0.0.1:$port" /bin/sh "$root/scripts/agent-anthropic.sh" "$F" >"$d/out.txt" 2>"$d/err.txt"; rc=$?
[ "$rc" != 0 ] || { echo "FAIL: key: no key file named was accepted" >&2; fail=1; }
case "$(cat "$d/err.txt")" in *ANTHROPIC_KEY_FILE*) ;; *) echo "FAIL: key: the message does not name ANTHROPIC_KEY_FILE ('$(cat "$d/err.txt")')" >&2; fail=1 ;; esac
expect "key: still no request" "$(cat "$d/count" 2>/dev/null || echo 0)" 0

# an HTTP error, and a wrong key
touch "$d/force-error"
agent >"$d/out.txt" 2>"$d/err.txt"; rc=$?
[ "$rc" != 0 ] || { echo "FAIL: error: exit code 0 on an HTTP error" >&2; fail=1; }
case "$(cat "$d/err.txt")" in *Overloaded*|*529*) ;; *) echo "FAIL: error: the API's message is not shown ('$(cat "$d/err.txt")')" >&2; fail=1 ;; esac
expect "error: the file is untouched" "$(cat "$d/project.cho")" "$(cat "$d/before.cho")"
rm -f "$d/force-error"
printf 'sk-ant-WRONG-key\n' > "$d/wrong.key"; chmod 600 "$d/wrong.key"
(KEYFILE="$d/wrong.key"; agent >"$d/out.txt" 2>"$d/err.txt"); rc=$?
[ "$rc" != 0 ] || { echo "FAIL: error: a rejected key exited 0" >&2; fail=1; }
case "$(cat "$d/err.txt")" in *401*|*authentication*) ;; *) echo "FAIL: error: a rejected key is not reported as such ('$(cat "$d/err.txt")')" >&2; fail=1 ;; esac
grep -q "sk-ant-WRONG-key" "$d/out.txt" "$d/err.txt" 2>/dev/null && { echo "FAIL: error: the key is in the error output" >&2; fail=1; }
stop

# tls: the agent must verify the server, and must find a CA bundle itself when its Python has none (the python.org macOS build ships none: the
# first live call failed CERTIFICATE_VERIFY_FAILED). A local CA signs the stub's certificate; SSL_CERT_FILE and SSL_CERT_DIR point nowhere, which
# is "this Python trusts nothing". Verification stays ON: a bundle that does not hold the CA must still fail.
if command -v openssl >/dev/null 2>&1; then
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$d/ca.key" -out "$d/ca.pem" -subj "/CN=cc-test-ca" -days 1 -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$d/other.key" -out "$d/other.pem" -subj "/CN=some-other-ca" -days 1 >/dev/null 2>&1
    openssl req -newkey rsa:2048 -nodes -keyout "$d/srv.key" -out "$d/srv.csr" -subj "/CN=localhost" >/dev/null 2>&1
    printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nauthorityKeyIdentifier=keyid,issuer\nsubjectKeyIdentifier=hash\nbasicConstraints=CA:FALSE\n' > "$d/ext.cnf"
    openssl x509 -req -in "$d/srv.csr" -CA "$d/ca.pem" -CAkey "$d/ca.key" -CAcreateserial -out "$d/srv.pem" -days 1 -extfile "$d/ext.cnf" >/dev/null 2>&1
    startls
    tlsagent() { env -i SSL_CERT_FILE=/nonexistent SSL_CERT_DIR=/nonexistent ANTHROPIC_URL="https://localhost:$port" ANTHROPIC_KEY_FILE="$d/key" ANTHROPIC_MODEL=stub-model "$@" /bin/sh "$root/scripts/agent-anthropic.sh" "$F"; }
    printf 'edition 7;\nfn broken() -> [] int { return true; }\n' > "$d/project.cho"; cp "$d/project.cho" "$d/before.cho"
    tlsagent >"$d/out.txt" 2>"$d/err.txt"; rc=$?
    [ "$rc" != 0 ] || { echo "FAIL: tls: a server whose CA nothing trusts was accepted" >&2; fail=1; }
    case "$(cat "$d/err.txt")" in *ertificate*) ;; *) echo "FAIL: tls: no certificate message ('$(cat "$d/err.txt")')" >&2; fail=1 ;; esac
    expect "tls: nothing was written when the server was not trusted" "$(cat "$d/project.cho")" "$(cat "$d/before.cho")"
    tlsagent AGENT_CA_BUNDLES="$d/other.pem" >"$d/out.txt" 2>"$d/err.txt"; rc=$?
    [ "$rc" != 0 ] || { echo "FAIL: tls: a bundle that does not hold the server's CA was accepted (verification is off?)" >&2; fail=1; }
    tlsagent AGENT_CA_BUNDLES="$d/other.pem:$d/ca.pem" >"$d/out.txt" 2>"$d/err.txt"; rc=$?
    expect "tls: a fallback bundle that holds the CA works (exit)" "$rc" 0
    expect "tls: ... and the file is the reply's program" "$(cat "$d/project.cho")" "edition 7;
fn fixed() -> [] int { return 1; }"
    stop
else
    echo "note: no openssl on PATH; the tls case was skipped" >&2
fi

rm -rf "$d"
[ "$fail" = 0 ] && echo "anthropic agent gate: ok" || { echo "anthropic agent gate: FAILED" >&2; exit 1; }
