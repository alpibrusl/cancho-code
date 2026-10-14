#!/bin/sh
# The prompt gate: src/prompt.cho held to the Python it replaces. For each case the harness lays out a project file, its `.task` and its
# `.feedback` as the driver would, and `tests/reference/agent_lib.py`'s `build_prompt` and the cancho prompt must give the SAME bytes:
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

"$CANCHO" build "$root/tests/programs/planprompt_gate.cho" "$root/src/planprompt.cho" --std --backend cranelift -o "$d/pgate" >/dev/null 2>"$d/build2.err" \
    || { cat "$d/build2.err" >&2; echo "planprompt gate did not build" >&2; exit 2; }

python3 - "$d" "$root" <<'PY'
import json, os, subprocess, sys
d, root = sys.argv[1:3]
sys.path.insert(0, os.path.join(root, "tests", "reference"))
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

# the planner's prompt: guide, THE TASK, REQUIRED PUBLIC FUNCTIONS only when given, the rejection only when there is one
def plan_case(name, guide, brief, contract, feedback):
    paths = []
    for k, v in (("guide", guide), ("brief", brief), ("contract", contract), ("feedback", feedback)):
        p = os.path.join(d, "pp." + k)
        if v is None:
            try: os.remove(p)
            except OSError: pass
        else:
            open(p, "w", encoding="utf-8").write(v)
        paths.append(p)
    want = guide.strip() + "\n\n=== THE TASK ===\n" + brief.strip() + "\n"
    if contract and contract.strip():
        want += "\n=== REQUIRED PUBLIC FUNCTIONS (use these signatures exactly) ===\n" + contract.strip() + "\n"
    if feedback and feedback.strip():
        want += "\n=== YOUR PREVIOUS REPLY WAS REJECTED ===\n" + feedback.strip() + "\n\nReply again with the corrected JSON object only.\n"
    else:
        want += "\nReply with the JSON object only.\n"
    p = subprocess.run([os.path.join(d, "pgate")] + paths + ["x"], capture_output=True)
    global fails
    if p.returncode != 0 or p.stdout != want.encode("utf-8"):
        fails += 1
        print("FAIL: planprompt: %s (exit %d)\n  wanted %r\n  got    %r" % (name, p.returncode, want.encode()[:300], p.stdout[:300]), file=sys.stderr)
G = "# Guide\nWrite a plan.\n\n"
plan_case("brief only", G, "Parse durations like 1h30m.\n", None, None)
plan_case("with a contract", G, "Parse durations.", "fn duration_parse[&r](s: &r [byte]) -> [] int\n", None)
plan_case("with a rejection", G, "Parse durations.", None, "[PLAN_ERROR]\tno-example\tparse\tunit has no example\n")
plan_case("everything", G, " Parse durations. ", "  fn a() -> [] int  ", "report\n")
plan_case("empty contract and feedback are absent", G, "T", "  \n", " \n")
plan_case("unicode and quotes in the brief", G, 'Parse "é" and 日本 \\ end', None, None)
print("planprompt: 6 cases")
sys.exit(1 if fails else 0)
PY
rc=$?
rm -rf "$d"
[ "$rc" = 0 ] && echo "prompt gate: ok" || { echo "prompt gate: FAILED" >&2; exit 1; }
