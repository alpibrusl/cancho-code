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
            "version": self.headers.get("anthropic-version"), "content_type": self.headers.get("content-type")}))
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
open(out + "/port", "w").write(str(s.server_address[1]))
s.serve_forever()
PY
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

rm -rf "$d"
[ "$fail" = 0 ] && echo "anthropic agent gate: ok" || { echo "anthropic agent gate: FAILED" >&2; exit 1; }
