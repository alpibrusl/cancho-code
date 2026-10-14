#!/usr/bin/env python3
"""Independent audit of a built `basics` (six pure integer functions) against the hidden oracle, by function.

    CANCHO=<compiler> python3 eval/audit_basics.py <project.cho>

Shapes (all `int`/`bool`, effect row `[]`): clamp(x, lo, hi), gcd(a, b), lcm(a, b), is_leap_year(y) -> bool, isqrt(n), pow_mod(base, exp, modulus).
Each function is its own test file: a function that is missing or of the wrong shape costs its own group (the compiler's first error is printed);
a build that fails in a shared part costs every group. If a group's run dies (an overflow trap or a panic kills the test binary
before it can summarise), the cases are re-run one by one, so a trap costs only the cases that trap.
Exit 0 only if every case holds. The oracle (eval/basics/oracle.py) was written before any run; ORACLE= overrides it.
The model under test never sees this file."""
import json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
C = os.environ.get("CANCHO", "cancho")
ORACLE = os.environ.get("ORACLE", os.path.join(HERE, "basics", "oracle.py"))
src = open(sys.argv[1], encoding="utf-8").read()
cases = [json.loads(l) for l in subprocess.run([sys.executable, ORACLE], capture_output=True, text=True, check=True).stdout.splitlines() if l.strip()]

body = re.sub(r"fn main\(world: World\).*?\n\}\n", "", src, flags=re.S)
body = re.sub(r"^edition \d+;\s*$", "", body, flags=re.M)
body = re.sub(r"^module [\w.]+;\s*$", "", body, flags=re.M)
body = re.sub(r"^import std\.test;\s*$", "", body, flags=re.M)   # the harness imports it itself
body = re.sub(r"^fn ", "pub fn ", body, flags=re.M)
body = re.sub(r"^(struct|enum) ", r"pub \1 ", body, flags=re.M)
head = "edition 7;\nmodule audit;\nimport std.test;\n"
FUNCS = ("clamp", "gcd", "lcm", "is_leap_year", "isqrt", "pow_mod")

def lit(v):
    if isinstance(v, bool): return "true" if v else "false"
    if v == -(1 << 63): return "(-9223372036854775807 - 1)"   # the minimum has no positive counterpart
    return f"({v})" if v < 0 else str(v)

def test_fn(i, c):
    call = f"{c['fn']}({', '.join(lit(a) for a in c['args'])})"
    if isinstance(c["expect"], bool):
        chk = f"test.assert({call} == {lit(c['expect'])});"
    else:
        chk = f"test.assert_eq({call}, {lit(c['expect'])});"
    return f"pub fn test_c{i:03d}() -> [] int {{ {chk} return 0; }}\n"

def build_and_test(tests):
    f = tempfile.NamedTemporaryFile("w", suffix=".cho", delete=False, encoding="utf-8")
    f.write(head + body + "\n" + tests); f.close()
    try:
        r = subprocess.run([C, "test", f.name, "--std", "--backend", "cranelift"], capture_output=True, text=True, timeout=300)
    except subprocess.TimeoutExpired:
        return None, "timed out"
    finally:
        os.unlink(f.name)
    m = re.search(r"(\d+) passed; (\d+) failed", r.stdout)
    if m: return int(m.group(1)), ""
    err = [l for l in (r.stderr + r.stdout).splitlines() if "error" in l]
    return None, (re.sub(r"^.*?\.cho:", "line ", err[0])[:120] if err else "no test summary (trap or crash)")

def run(fn):
    cs = [c for c in cases if c["fn"] == fn]
    p, why = build_and_test("".join(test_fn(i, c) for i, c in enumerate(cs)))
    if p is not None: return p, len(cs), ""
    if not why.startswith("no test summary"): return 0, len(cs), "does not build: " + why
    # the binary died: grade the cases one at a time
    ok = 0
    for i, c in enumerate(cs):
        q, _ = build_and_test(test_fn(i, c))
        ok += 1 if q == 1 else 0
    return ok, len(cs), "(a case trapped or crashed; graded one by one)"

total = 0
for fn in FUNCS:
    p, n, why = run(fn)
    total += p
    print(f"  {fn}: {p}/{n} {why}".rstrip())
print(f"  TOTAL {total}/{len(cases)}")
sys.exit(0 if total == len(cases) else 1)
