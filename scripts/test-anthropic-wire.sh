#!/bin/sh
# The request a native Anthropic agent sends (src/anthropic.cho), built by tests/programs/anthropic_gate.cho and compared, as parsed JSON,
# with what the Messages API takes and what the Python agent it replaced sent. Pure: no network, no key.
#
#   full      model, max_tokens, one user message, thinking, output_config.effort, and the primer as a cached `system` block
#   bare      no primer, no thinking, no effort: those three keys are ABSENT, not empty (an empty value is a value the API may refuse)
#   escapes   a prompt with quotes, backslashes, newlines, tabs, control bytes and non-ASCII text arrives byte for byte once parsed
#   ollama    /api/generate: model, the primer then the prompt as one `prompt`, stream and think off, options (num_ctx, temperature 0.2, num_predict)
#   headers   x-api-key, anthropic-version, content-type; anthropic-workspace-id only when named; every line ends CRLF; the key appears once
set -u

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "no python3 on PATH" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
fail=0
d=$(mktemp -d -t cc-wire-XXXXXX)
"$CANCHO" build "$root/tests/programs/anthropic_gate.cho" "$root/src/anthropic.cho" "$root/src/ollama.cho" --std -o "$d/gate" >/dev/null 2>"$d/build.err" \
    || { cat "$d/build.err" >&2; echo "gate did not build" >&2; exit 2; }

python3 - "$d" <<'PY'
import sys
d = sys.argv[1]
open(d + "/primer.md", "w", encoding="utf-8").write("A PRIMER about cancho.\nSecond line, with \"quotes\".\n")
open(d + "/plain.txt", "w", encoding="utf-8").write("fix the program\n")
open(d + "/hard.txt", "wb").write("quote \" backslash \\ newline \n tab \t ctl \x01\x1f unicode é 日本 \U0001F600 end".encode("utf-8"))
open(d + "/key", "w").write("sk-ant-test-0123456789-not-a-real-key\n")
PY

check() {   # name, expected-python-expression, command...
    name=$1; want=$2; shift 2
    "$@" > "$d/out" 2>"$d/err"; rc=$?
    [ "$rc" = 0 ] || { echo "FAIL: $name: exit $rc ($(cat "$d/err"))" >&2; fail=1; return; }
    python3 - "$d" "$name" "$want" <<'PY' || fail=1
import json, sys
d, name, want = sys.argv[1:4]
raw = open(d + "/out", "rb").read()
try:
    got = json.loads(raw.decode("utf-8"))
except Exception as e:
    print("FAIL: %s: not JSON (%s): %r" % (name, e, raw[:200]), file=sys.stderr); sys.exit(1)
primer = open(d + "/primer.md", encoding="utf-8").read()
hard = open(d + "/hard.txt", encoding="utf-8").read()
plain = open(d + "/plain.txt", encoding="utf-8").read()
exp = eval(want)
if got != exp:
    print("FAIL: %s:\n  wanted %r\n  got    %r" % (name, exp, got), file=sys.stderr); sys.exit(1)
PY
}

check full "{'model': 'm-1', 'max_tokens': 16000, 'messages': [{'role': 'user', 'content': plain}], 'thinking': {'type': 'adaptive'}, 'output_config': {'effort': 'high'}, 'system': [{'type': 'text', 'text': primer, 'cache_control': {'type': 'ephemeral'}}]}" \
    "$d/gate" body m-1 16000 "$d/primer.md" "$d/plain.txt" adaptive high
check bare "{'model': 'm-1', 'max_tokens': 8192, 'messages': [{'role': 'user', 'content': plain}]}" \
    "$d/gate" body m-1 8192 /dev/null "$d/plain.txt" - -
check escapes "{'model': 'm-1', 'max_tokens': 1, 'messages': [{'role': 'user', 'content': hard}]}" \
    "$d/gate" body m-1 1 /dev/null "$d/hard.txt" - -

check ollama "{'model': 'q:1', 'prompt': primer + hard, 'stream': False, 'think': False, 'options': {'num_ctx': 16384, 'temperature': 0.2, 'num_predict': 4096}}" \
    "$d/gate" ollama q:1 16384 "$d/primer.md" "$d/hard.txt" 4096 x
check ollama-bare "{'model': 'q:1', 'prompt': plain, 'stream': False, 'think': False, 'options': {'num_ctx': 8192, 'temperature': 0.2, 'num_predict': 8192}}" \
    "$d/gate" ollama q:1 8192 /dev/null "$d/plain.txt" 8192 x
"$d/gate" ollama-headers x x x x x x > "$d/oh"
printf 'content-type: application/json\r\n' > "$d/oh.want"
cmp -s "$d/oh" "$d/oh.want" || { echo "FAIL: ollama headers: wanted only a content type" >&2; fail=1; }

KEY=$(tr -d '\n' < "$d/key")
"$d/gate" headers "$d/key" - x x x x > "$d/h1"
printf 'x-api-key: %s\r\nanthropic-version: 2023-06-01\r\ncontent-type: application/json\r\n' "$KEY" > "$d/h1.want"
cmp -s "$d/h1" "$d/h1.want" || { echo "FAIL: headers: wanted $(od -c "$d/h1.want" | head -3), got $(od -c "$d/h1" | head -3)" >&2; fail=1; }
"$d/gate" headers "$d/key" wrkspc_123 x x x x > "$d/h2"
printf 'anthropic-workspace-id: wrkspc_123\r\n' >> "$d/h1.want"
cmp -s "$d/h2" "$d/h1.want" || { echo "FAIL: headers with a workspace differ" >&2; fail=1; }
[ "$(grep -c "$KEY" "$d/h2")" = 1 ] || { echo "FAIL: headers: the key is not on exactly one line" >&2; fail=1; }

rm -rf "$d"
[ "$fail" = 0 ] && echo "anthropic wire gate: ok" || { echo "anthropic wire gate: FAILED" >&2; exit 1; }
