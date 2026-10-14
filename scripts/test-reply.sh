#!/bin/sh
# The reply gate: src/reply.cho (a model's reply, and the program inside an answer) held to the Python it replaces.
#
#   program   `reply.program_span` and `tests/reference/agent_lib.py`'s `program()` give the SAME answer (byte for byte, or both none) on a corpus:
#             hand-made edge cases (fences, prose around them, `</think>` in its several places, no edition line, CRLF, ...) and the real
#             replies in tests/fixtures/replies.txt (qwen3.8 and Claude, from the runs reported on issue #9)
#   reply     the text blocks of a Messages reply are put together in order and `thinking` blocks are not text; escapes and non-ASCII text
#             survive; a reply bigger than a region (64 KiB) is read whole; `stop_reason` max_tokens is told from end_turn; the API's own
#             error message is returned, and `no message` when there is none or the body is not JSON; usage counts come out as numbers
set -u

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "no python3 on PATH" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
d=$(mktemp -d -t cc-reply-XXXXXX)
"$CANCHO" build "$root/tests/programs/reply_gate.cho" "$root/src/reply.cho" --std --backend cranelift -o "$d/gate" >/dev/null 2>"$d/build.err" \
    || { cat "$d/build.err" >&2; echo "gate did not build" >&2; exit 2; }

python3 - "$d/gate" "$root" <<'PY' || { echo "reply gate: FAILED" >&2; exit 1; }
import json, os, re, subprocess, sys, tempfile
gate, root = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(root, "tests", "reference"))
import agent_lib

fails = 0
tmp = tempfile.mkdtemp(prefix="cc-reply-cases-")

def run(mode, data):
    path = os.path.join(tmp, "case")
    open(path, "wb").write(data)
    p = subprocess.run([gate, mode, path, "x", "x", "x"], capture_output=True)
    return p.returncode, p.stdout

def fail(msg):
    global fails
    fails += 1
    print("FAIL: " + msg, file=sys.stderr)

PROG = "edition 7;\nfn fixed() -> [] int { return 1; }"
cases = {
    "bare program": PROG + "\n",
    "fenced": "```cancho\n" + PROG + "\n```\n",
    "fenced, prose around": "Here is the fix:\n\n```cancho\n" + PROG + "\n```\n\nThis works because...",
    "two blocks, the longest": "```\nedition 7;\nfn a() -> [] int { return 1; }\n```\ntext\n```cancho\n" + PROG + "\nfn b() -> [] int { return 2; }\n```\n",
    "two blocks, equal length": "```\nedition 7;\nfn a() -> [] int { return 1; }\n```\n```\nedition 7;\nfn b() -> [] int { return 2; }\n```\n",
    "unclosed fence": "```cancho\n" + PROG + "\n",
    "unopened fence": PROG + "\n```\n",
    "unopened fence, spaces before it": PROG + "\n   ```  \n",
    "fence with a tag and a space": "``` cancho\n" + PROG + "\n```",
    "fence tag with a space after": "```cancho  \n" + PROG + "\n```",
    "preamble then program": "Sure! I will fix it.\nedition 7;\nfn x() -> [] int { return 1; }\n",
    "no program": "I think the problem is that the function returns bool.\nLet me think about it more.",
    "reasoning with a fence, no edition": "```\nlet x = 1;\n```\n",
    "edition not at a line start": "the line edition 7; is not a program\n",
    "edition without digits": "edition x;\nfn a() {}\n",
    "edition without semicolon": "edition 7\nfn a() {}\n",
    "edition 12": "edition 12;\nfn a() -> [] int { return 1; }\n",
    "think, answer after": "reasoning...\n</think>\n" + PROG + "\n",
    "think, answer after, fenced": "reasoning with edition 9;\n</think>\n```cancho\n" + PROG + "\n```\n",
    "think, program before": "```cancho\n" + PROG + "\n```\n</think>",
    "think, program before, spaces after": "```cancho\n" + PROG + "\n```\n</think>\n  \n",
    "two thinks": "a\n</think>\nnot a program\n</think>\n" + PROG + "\n",
    "two thinks, program in the middle": "a\n</think>\n" + PROG + "\n</think>\nbye",
    "think, nothing anywhere": "a</think>b",
    "open think tag": "<think>\n" + PROG + "\n",
    "open think tag glued": "<think>" + PROG + "\n",
    "CRLF": "```cancho\r\n" + PROG.replace("\n", "\r\n") + "\r\n```\r\n",
    "trailing blank lines": PROG + "\n\n\n\n",
    "leading blank lines": "\n\n\n" + PROG + "\n",
    "empty": "",
    "only a fence": "```\n```\n",
    "backticks inside a string": "edition 7;\nfn f() -> [] int { return 1; } // ``` not a fence\n",
    "four backticks": "````cancho\n" + PROG + "\n````\n",
    "unicode": "edition 7;\n// héllo 日本 \U0001F600\nfn f() -> [] int { return 1; }\n",
}
for name, text in cases.items():
    want = agent_lib.program(text)
    code, out = run("span", text.encode("utf-8"))
    wantb = b"NONE" if want is None else want.encode("utf-8")
    if code != 0 or out != wantb:
        fail("program: %s:\n  python %r\n  cancho %r (exit %d)" % (name, wantb[:120], out[:120], code))
print("program: %d edge cases" % len(cases))

blocks = re.split(r"^=== reply[^\n]*\n", open(os.path.join(root, "tests/fixtures/replies.txt"), encoding="utf-8").read(), flags=re.M)[1:]
n = 0
for k, b in enumerate(blocks):
    text = b[:-1] if b.endswith("\n") else b
    want = agent_lib.program(text)
    code, out = run("span", text.encode("utf-8"))
    wantb = b"NONE" if want is None else want.encode("utf-8")
    n += 1
    if code != 0 or out != wantb:
        fail("program: real reply %d (%d bytes): python %d bytes, cancho %d bytes (exit %d)" % (k, len(text), len(wantb), len(out), code))
print("program: %d real replies" % n)

def msg(content, stop="end_turn", usage=None):
    return {"id": "msg_x", "type": "message", "role": "assistant", "model": "m", "content": content, "stop_reason": stop,
            "usage": usage if usage is not None else {"input_tokens": 1, "output_tokens": 1}}

def expect(name, mode, body, want):
    code, out = run(mode, body if isinstance(body, bytes) else json.dumps(body).encode("utf-8"))
    if code != 0 or out != want.encode("utf-8"):
        fail("reply: %s: wanted %r, got %r (exit %d)" % (name, want[:100], out[:100].decode("utf-8", "replace"), code))

hard = "quote \" backslash \\ newline \n tab \t ctl \x01 unicode é 日本 \U0001F600 slash / end"
expect("one text block", "text", msg([{"type": "text", "text": "hello"}]), "hello")
expect("blocks in order, thinking skipped", "text",
       msg([{"type": "thinking", "thinking": "SECRET", "signature": "s"}, {"type": "text", "text": "a"}, {"type": "text", "text": "b"}]), "ab")
expect("a block of another type is not text, whatever fields it has", "text",
       msg([{"type": "text", "text": "a"}, {"type": "other", "text": "NOT"}, {"type": "text", "text": "b"}]), "ab")
expect("escapes survive", "text", msg([{"type": "text", "text": hard}]), hard)
expect("no content", "text", {"type": "message"}, "")
expect("not JSON", "text", b"<html>bad gateway</html>", "")
big = ("x" * 99 + "\n") * 1500
expect("a reply bigger than a region", "text", msg([{"type": "text", "text": big}]), big)
expect("stop max_tokens", "max", msg([], "max_tokens"), "yes")
expect("stop end_turn", "max", msg([], "end_turn"), "no")
expect("stop absent", "max", {"content": []}, "no")
expect("error body", "error", {"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}}, "overloaded_error: Overloaded")
expect("error without a message", "error", {"error": {"type": "x"}}, "no message")
expect("error from a non-JSON body", "error", b"oops", "no message")
expect("usage", "usage", msg([], usage={"input_tokens": 12, "output_tokens": 345, "cache_creation_input_tokens": 11408, "cache_read_input_tokens": 0}),
       "input_tokens=12 output_tokens=345 cache_creation_input_tokens=11408 cache_read_input_tokens=0")
expect("usage, absent counts are 0", "usage", msg([], usage={"input_tokens": 5}),
       "input_tokens=5 output_tokens=0 cache_creation_input_tokens=0 cache_read_input_tokens=0")
expect("usage, absent", "usage", {"content": []}, "input_tokens=0 output_tokens=0 cache_creation_input_tokens=0 cache_read_input_tokens=0")
expect("ollama: response", "generated", {"model": "q", "response": hard, "done": True, "done_reason": "stop", "eval_count": 7}, hard)
expect("ollama: a response bigger than a region", "generated", {"response": big, "done_reason": "stop"}, big)
expect("ollama: no response field", "generated", {"done": True}, "")
expect("ollama: not JSON", "generated", b"nope", "")
expect("ollama: done_reason length", "length", {"response": "x", "done_reason": "length"}, "yes")
expect("ollama: done_reason stop", "length", {"response": "x", "done_reason": "stop"}, "no")
expect("ollama: no done_reason", "length", {"response": "x"}, "no")
expect("ollama: error body", "generate-error", {"error": "model 'x' not found"}, "model 'x' not found")
expect("ollama: no error field", "generate-error", {"response": "x"}, "no message")
expect("ollama: error from a non-JSON body", "generate-error", b"oops", "no message")
print("reply: 26 cases")
sys.exit(1 if fails else 0)
PY
rc=$?
rm -rf "$d"
[ "$rc" = 0 ] && echo "reply gate: ok" || { echo "reply gate: FAILED" >&2; exit 1; }
