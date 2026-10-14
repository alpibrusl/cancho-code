#!/usr/bin/env python3
"""Independent audit of a built `expr` (integer expression evaluator) against eval/expr/oracle.py, graded by group.

    CANCHO=<compiler> python3 eval/audit_expr.py <project.cho>

The shape is the one the plan pins:
    expr_eval[&r](s: &r [byte]) -> [] result.Result[int, &static [byte]]
Groups: expr_value (inputs whose answer is a number), expr_error (inputs that must be Err), expr_long (inputs of 200+ bytes: deep
nesting, long chains, much whitespace; the answer may be either). A trap (overflow, division by zero, stack) in the solver fails
only its own case. A file that does not build scores 0 everywhere, with the compiler's first error.
Exit 0 only if every case holds. ORACLE= overrides the oracle. The model under test never sees this file."""
import json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
C = os.environ.get("CANCHO", "cancho")
ORACLE = os.environ.get("ORACLE", os.path.join(HERE, "expr", "oracle.py"))
src = open(sys.argv[1], encoding="utf-8").read()
cases = [json.loads(l) for l in subprocess.run([sys.executable, ORACLE], capture_output=True, text=True, check=True).stdout.splitlines() if l.strip()]

body = re.sub(r"fn main\(world: World\).*?\n\}\n", "", src, flags=re.S)
body = re.sub(r"^edition \d+;\s*$", "", body, flags=re.M)
body = re.sub(r"^module \w+;\s*$", "", body, flags=re.M)
body = re.sub(r"^import std\.(result|test);\s*$", "", body, flags=re.M)   # the harness imports these itself
body = re.sub(r"^fn ", "pub fn ", body, flags=re.M)
body = re.sub(r"^(struct|enum) ", r"pub \1 ", body, flags=re.M)
head = "edition 7;\nimport std.result;\nimport std.test;\n"

HELPERS = '''
fn value_is(s: &static [byte], want: int) -> [] int {
    match expr_eval(s) {
        result.Result::Ok(v) => { if v == want { return 0; } return 1; }
        result.Result::Err(_) => { return 2; }
    }
}
fn is_err(s: &static [byte]) -> [] int {
    match expr_eval(s) {
        result.Result::Ok(_) => { return 1; }
        result.Result::Err(_) => { return 0; }
    }
}
'''

def lit(s):
    m = {"\n": "\\n", "\r": "\\r", "\t": "\\t", "\\": "\\\\", '"': '\\"', "\0": "\\0"}
    return '"' + "".join(m.get(c, c) for c in s) + '"'

GROUPS = ("expr_value", "expr_error", "expr_long")
def group(c):
    if len(c["args"][0]) >= 200: return "expr_long"
    return "expr_error" if c.get("expect_err") else "expr_value"

tests, names = [], {g: [] for g in GROUPS}
for i, c in enumerate(cases):
    a = c["args"][0]
    g = group(c)
    name = f"test_{g}_{i:03d}"
    names[g].append(name)
    call = f"is_err({lit(a)})" if c.get("expect_err") else f"value_is({lit(a)}, {c['expect']['args'][0]})"
    tests.append(f"pub fn {name}() -> [] int {{ test.assert_eq({call}, 0); return 0; }}")

f = tempfile.NamedTemporaryFile("w", suffix=".cho", delete=False, encoding="utf-8")
f.write(head + body + "\n" + HELPERS + "\n".join(tests) + "\n"); f.close()
r = subprocess.run([C, "test", f.name, "--std"], capture_output=True, text=True)
os.unlink(f.name)
passed = set(re.findall(r"^test (\w+) \.\.\. ok$", r.stdout, flags=re.M))
why = ""
if not passed and not re.search(r"\d+ passed", r.stdout):
    err = [l for l in (r.stderr + r.stdout).splitlines() if "error" in l]
    why = "does not build: " + (re.sub(r"^.*?\.cho:", "line ", err[0])[:120] if err else "?")
total = 0
for g in GROUPS:
    p = sum(1 for n in names[g] if n in passed)
    total += p
    print(f"  {g}: {p}/{len(names[g])} {why}".rstrip())
print(f"  TOTAL {total}/{len(cases)}")
sys.exit(0 if total == len(cases) else 1)
