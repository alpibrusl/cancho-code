#!/bin/sh
# The prompt gate: src/prompt.cho held to the Python it replaces. For each case the harness lays out a project file, its `.task` and its
# `.feedback` as the driver would, and `scripts/agent_lib.py`'s `build_prompt` and the cancho prompt must give the SAME bytes:
#
#   fix       no task: the instruction to fix; the checker's refusals with the source line and a caret under the column
#   task      a unit's task goes ahead of the file, trimmed; the refusals still follow
#   feedback  at most eight refusals; a column that points past the line; a line past the end; the checker's JSON with no `refused`; a
#             non-JSON feedback (its first 1,500 bytes); an empty one; a refusal missing a field (the whole feedback falls back to the text)
#   absent    neither .task nor .feedback
set -u

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "no python3 on PATH" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
d=$(mktemp -d -t cc-prompt-XXXXXX)
"$CANCHO" build "$root/tests/programs/prompt_gate.cho" "$root/src/prompt.cho" --std --backend cranelift -o "$d/gate" >/dev/null 2>"$d/build.err" \
    || { cat "$d/build.err" >&2; echo "gate did not build" >&2; exit 2; }

python3 - "$d" "$root" <<'PY'
import json, os, subprocess, sys
d, root = sys.argv[1:3]
sys.path.insert(0, os.path.join(root, "scripts"))
import agent_lib
fails = 0
SRC = "edition 7;\nfn broken() -> [] int { return true; }\nfn other() -> [] int {\n\treturn 1;\n}\n"

def ref(line, col, msg="expected `int`, found `bool`", rule="type-mismatch"):
    return {"rule": rule, "message": msg, "position": {"line": line, "column": col}}

def fb(*refs):
    return json.dumps({"refused": list(refs)})

cases = {
    "fix: one refusal": (SRC, None, fb(ref(2, 30))),
    "fix: caret at column 1": (SRC, None, fb(ref(2, 1))),
    "fix: a tab in the line": (SRC, None, fb(ref(4, 9))),
    "fix: two refusals": (SRC, None, fb(ref(2, 30), ref(3, 5, "unused", "dead-code"))),
    "fix: message with quotes and unicode": (SRC, None, fb(ref(2, 30, 'bad "thing" é 日本 \\ end', "r-1"))),
    "fix: nine refusals, eight shown": (SRC, None, fb(*[ref(2, k + 1, "m%d" % k) for k in range(9)])),
    "fix: line past the end": (SRC, None, fb(ref(99, 3))),
    "fix: line 0": (SRC, None, fb(ref(0, 3))),
    "fix: column past the line": (SRC, None, fb(ref(1, 60))),
    "fix: last line, no final newline": ("edition 7;\nfn a() {}", None, fb(ref(2, 4))),
    "feedback: refused is empty": (SRC, None, fb()),
    "feedback: JSON with no refused": (SRC, None, '{"other": 1}'),
    "feedback: not JSON": (SRC, None, "error: the compiler fell over\nat some place\n"),
    "feedback: empty file": (SRC, None, ""),
    "feedback: long text": (SRC, None, "x" * 4000),
    "feedback: a refusal missing a field": (SRC, None, '{"refused": [{"rule": "r", "message": "m"}]}'),
    "feedback: a refusal after a good one is missing a field": (SRC, None, '{"refused": [%s, {"rule": "r"}]}' % json.dumps(ref(2, 3))),
    "task: with feedback": (SRC, "UNIT: refill\nFUNCTION: bucket_refill\nEXAMPLES:\nbucket_refill(1) == 2\n", fb(ref(2, 30))),
    "task: surrounded by blank lines": (SRC, "\n\n  write it  \n\n", None),
    "task: whitespace only is no task": (SRC, " \n\t \n", fb(ref(2, 30))),
    "absent: neither": (SRC, None, None),
}
for name, (src, task, feedback) in cases.items():
    f = os.path.join(d, "project.cho")
    for ext in ("", ".task", ".feedback"):
        try: os.remove(f + ext)
        except OSError: pass
    open(f, "w", encoding="utf-8").write(src)
    if task is not None: open(f + ".task", "w", encoding="utf-8").write(task)
    if feedback is not None: open(f + ".feedback", "w", encoding="utf-8").write(feedback)
    _, want = agent_lib.build_prompt(f, "t", "NO_SUCH_PRIMER_VARIABLE")
    p = subprocess.run([os.path.join(d, "gate"), f, "x", "x", "x"], capture_output=True)
    if p.returncode != 0 or p.stdout != want.encode("utf-8"):
        fails += 1
        a, b = want.encode("utf-8"), p.stdout
        i = next((k for k in range(min(len(a), len(b))) if a[k] != b[k]), min(len(a), len(b)))
        print("FAIL: %s (exit %d): first difference at byte %d\n  python %r\n  cancho %r" % (name, p.returncode, i, a[max(0, i - 30):i + 60], b[max(0, i - 30):i + 60]), file=sys.stderr)
print("prompt: %d cases" % len(cases))
sys.exit(1 if fails else 0)
PY
rc=$?
rm -rf "$d"
[ "$rc" = 0 ] && echo "prompt gate: ok" || { echo "prompt gate: FAILED" >&2; exit 1; }
