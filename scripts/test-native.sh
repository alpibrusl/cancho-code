#!/bin/sh
# The native transport gate: `provider.exchange` (src/provider.cho) through tests/programs/post_gate.cho, against a local stub that speaks
# HTTP and HTTPS, so no key, no network and no spend are involved. The point of a native agent is that nothing outside cancho carries the key
# or checks the certificate; this pins both:
#
#   tls      a POST over TLS to a server whose CA is in the roots: the status and the body come back whole, and the server received exactly
#            the header lines and the body the caller wrote (the key under `x-api-key`, and nowhere else)
#   plain    the same over plain TCP (`secure` 0), for a local server
#   big      a request body far bigger than the client's buffer (200 KB; the language page alone is 29 KB) arrives whole
#   trust    roots that do not hold the server's CA: refused, and the request never reached the server
#   name     a certificate for another name than the host asked for: refused, nothing reached the server
#   away     nothing listening: a named refusal, not a hang
#
# Needs CANCHO (and the compiler's packages/, found next to it or in CANCHO_PACKAGES), python3 for the stub, openssl for the certificates.
set -u

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "no python3 on PATH" >&2; exit 2; }
command -v openssl >/dev/null 2>&1 || { echo "no openssl on PATH" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
C="${CANCHO_PACKAGES:-}"
[ -d "$C" ] || C="$(dirname "$(dirname "$(command -v "$CANCHO")")")/packages"
[ -d "$C" ] || C="$(dirname "$(dirname "$(dirname "$(command -v "$CANCHO")")")")/packages"
[ -d "$C" ] || { echo "no cancho packages found; set CANCHO_PACKAGES" >&2; exit 2; }

fail=0
expect() { [ "$2" = "$3" ] || { echo "FAIL: $1: wanted '$3', got '$2'" >&2; fail=1; }; }

d=$(mktemp -d -t cc-native-XXXXXX)
exe="$d/post_gate"
"$CANCHO" build "$root/tests/programs/post_gate.cho" "$root/src/provider.cho" "$root/vendor/fetch_io.cho" \
    "$C"/http-client/*.cho "$C"/tls/*.cho "$C"/x509/*.cho --std -o "$exe" >/dev/null 2>"$d/build.err" \
    || { cat "$d/build.err" >&2; echo "gate did not build" >&2; exit 2; }

cat > "$d/stub.py" <<'PY'
import http.server, json, ssl, sys
out = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        open(out + "/got.body", "wb").write(body)
        open(out + "/got.headers", "w").write(json.dumps({"path": self.path, "x-api-key": self.headers.get("x-api-key"),
            "anthropic-version": self.headers.get("anthropic-version"), "content-type": self.headers.get("content-type"),
            "authorization": self.headers.get("authorization"), "host": self.headers.get("host")}))
        data = json.dumps({"echo": len(body), "ok": True}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(data)))
        self.end_headers(); self.wfile.write(data)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
if len(sys.argv) > 3:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(sys.argv[2], sys.argv[3])
    s.socket = ctx.wrap_socket(s.socket, server_side=True)
open(out + "/port", "w").write(str(s.server_address[1]))
s.serve_forever()
PY

# A CA, a server certificate for `localhost`, a certificate for another name, and an unrelated CA.
mk() { openssl req -newkey rsa:2048 -nodes -keyout "$d/$1.key" -out "$d/$1.csr" -subj "/CN=$2" >/dev/null 2>&1
       printf 'subjectAltName=DNS:%s\nauthorityKeyIdentifier=keyid,issuer\nsubjectKeyIdentifier=hash\nbasicConstraints=CA:FALSE\n' "$2" > "$d/$1.cnf"
       openssl x509 -req -in "$d/$1.csr" -CA "$d/ca.pem" -CAkey "$d/ca.key" -CAcreateserial -out "$d/$1.pem" -days 1 -extfile "$d/$1.cnf" >/dev/null 2>&1; }
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$d/ca.key" -out "$d/ca.pem" -subj "/CN=cc-test-ca" -days 1 -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$d/other.key" -out "$d/other.pem" -subj "/CN=some-other-ca" -days 1 -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
mk srv localhost
mk wrong elsewhere.example

KEY="sk-ant-test-0123456789-not-a-real-key"
printf 'x-api-key: %s\r\nanthropic-version: 2023-06-01\r\ncontent-type: application/json\r\n' "$KEY" > "$d/headers"
printf '{"model":"stub","messages":[{"role":"user","content":"hello \\"world\\""}]}' > "$d/body"
BODYLEN=$(wc -c < "$d/body" | tr -d ' ')

start() { rm -f "$d/port" "$d/got.body" "$d/got.headers"; python3 "$d/stub.py" "$d" "$@" & stub=$!
          n=0; while [ ! -s "$d/port" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done; port=$(cat "$d/port"); }
stop() { kill $stub 2>/dev/null; wait $stub 2>/dev/null; }
run() { "$exe" "$1" 127.0.0.1 "$port" "$2" /v1/messages "$3" "$d/headers" "$d/body"; }

# tls
start "$d/srv.pem" "$d/srv.key"
out=$(run localhost 1 "$d/ca.pem")
expect "tls: status and body" "$out" "status 200
{\"echo\": $BODYLEN, \"ok\": true}"
expect "tls: the body arrived whole" "$(cat "$d/got.body" 2>/dev/null)" "$(cat "$d/body")"
got=$(python3 -c "import json; h = json.load(open('$d/got.headers')); print(h['path'], h['x-api-key'] == '$KEY', h['anthropic-version'], h['content-type'], h['authorization'], h['host'])" 2>&1)
expect "tls: the headers arrived as written" "$got" "/v1/messages True 2023-06-01 application/json None localhost"

# big: the client's output buffer is 16 KiB, so a body is fed over many turns of the pump
python3 -c "import json; print(json.dumps({'model': 'stub', 'messages': [{'role': 'user', 'content': ('abc \\\\ \"q\" ' * 20000)}]}), end='')" > "$d/body.big"
cp "$d/body" "$d/body.small"; cp "$d/body.big" "$d/body"
BIGLEN=$(wc -c < "$d/body" | tr -d ' ')
out=$(run localhost 1 "$d/ca.pem")
expect "big: status and echoed length (tls)" "$out" "status 200
{\"echo\": $BIGLEN, \"ok\": true}"
cmp -s "$d/got.body" "$d/body" || { echo "FAIL: big: the body did not arrive whole (tls)" >&2; fail=1; }
cp "$d/body.small" "$d/body"

# trust: a bundle without the server's CA
rm -f "$d/got.body" "$d/got.headers"
out=$(run localhost 1 "$d/other.pem")
case "$out" in failed*) ;; *) echo "FAIL: trust: an untrusted server was accepted ('$out')" >&2; fail=1 ;; esac
[ ! -e "$d/got.body" ] || { echo "FAIL: trust: the request reached an untrusted server" >&2; fail=1; }

# name: the certificate is for another name than the one asked for
stop; start "$d/wrong.pem" "$d/wrong.key"
out=$(run localhost 1 "$d/ca.pem")
case "$out" in failed*) ;; *) echo "FAIL: name: a certificate for another name was accepted ('$out')" >&2; fail=1 ;; esac
[ ! -e "$d/got.body" ] || { echo "FAIL: name: the request reached a server with the wrong name" >&2; fail=1; }
stop

# plain
start
out=$(run localhost 0 /dev/null)
expect "plain: status and body" "$out" "status 200
{\"echo\": $BODYLEN, \"ok\": true}"
expect "plain: the body arrived whole" "$(cat "$d/got.body" 2>/dev/null)" "$(cat "$d/body")"
cp "$d/body.big" "$d/body"
out=$(run localhost 0 /dev/null)
expect "big: status and echoed length (plain)" "$out" "status 200
{\"echo\": $BIGLEN, \"ok\": true}"
cmp -s "$d/got.body" "$d/body" || { echo "FAIL: big: the body did not arrive whole (plain)" >&2; fail=1; }
cp "$d/body.small" "$d/body"
stop

# away
out=$(run localhost 0 /dev/null)
case "$out" in failed*) ;; *) echo "FAIL: away: no refusal with no server ('$out')" >&2; fail=1 ;; esac

rm -rf "$d"
[ "$fail" = 0 ] && echo "native transport gate: ok" || { echo "native transport gate: FAILED" >&2; exit 1; }
