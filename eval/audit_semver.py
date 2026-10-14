#!/usr/bin/env python3
"""Independent audit of a built `01-semver` against the lex-code backlog oracle, the three public functions graded separately.

    CANCHO=<compiler> python3 eval/audit_semver.py <project.cho>

The shapes are the ones the plan pins (cancho has no `Str`, so the brief's `Str` becomes bytes):
    semver_valid[&s](s: &s [byte]) -> [] bool
    semver_compare[&a, &b](a: &a [byte], b: &b [byte]) -> [] result.Result[int, &static [byte]]
    semver_satisfies[&v, &r](version: &v [byte], range: &r [byte]) -> [] result.Result[bool, &static [byte]]
A file that does not build in those shapes scores 0 for the group that needs them, with the compiler's first error.
Only these three are called (the plan's helper units are not graded here). Exit 0 only if every case holds.
The oracle (eval/semver/oracle.py, vendored unchanged) was written before any run; ORACLE= overrides it. The model under
test never sees this file."""
import json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
C = os.environ.get("CANCHO", "cancho")
ORACLE = os.environ.get("ORACLE", os.path.join(HERE, "semver", "oracle.py"))
src = open(sys.argv[1], encoding="utf-8").read()
cases = [json.loads(l) for l in subprocess.run([sys.executable, ORACLE], capture_output=True, text=True, check=True).stdout.splitlines() if l.strip()]

body = re.sub(r"fn main\(world: World\).*?\n\}\n", "", src, flags=re.S)
body = re.sub(r"^edition \d+;\s*$", "", body, flags=re.M)
body = re.sub(r"^import std\.(result|buffer|bytes|test);\s*$", "", body, flags=re.M)   # the harness imports these itself
body = re.sub(r"^fn ", "pub fn ", body, flags=re.M)
body = re.sub(r"^(struct|enum) ", r"pub \1 ", body, flags=re.M)
head = "edition 7;\nimport std.result;\nimport std.buffer;\nimport std.bytes;\nimport std.test;\n"

HELPERS = {
"semver_valid": '''
fn valid_is(s: &static [byte], want: bool) -> [] int {
    if semver_valid(s) == want { return 0; }
    return 1;
}
''',
"semver_compare": '''
fn cmp_is(a: &static [byte], b: &static [byte], want: int) -> [] int {
    match semver_compare(a, b) {
        result.Result::Ok(v) => { if v == want { return 0; } return 1; }
        result.Result::Err(_) => { return 2; }
    }
}
fn cmp_err(a: &static [byte], b: &static [byte]) -> [] int {
    match semver_compare(a, b) {
        result.Result::Ok(_) => { return 1; }
        result.Result::Err(_) => { return 0; }
    }
}
''',
"semver_satisfies": '''
fn sat_is(v: &static [byte], r: &static [byte], want: bool) -> [] int {
    match semver_satisfies(v, r) {
        result.Result::Ok(x) => { if x == want { return 0; } return 1; }
        result.Result::Err(_) => { return 2; }
    }
}
fn sat_err(v: &static [byte], r: &static [byte]) -> [] int {
    match semver_satisfies(v, r) {
        result.Result::Ok(_) => { return 1; }
        result.Result::Err(_) => { return 0; }
    }
}
''',
}
# Each group is its own file with its own helpers: a function of the wrong shape must cost its own group only.

def lit(s):
    m = {"\n": "\\n", "\r": "\\r", "\t": "\\t", "\\": "\\\\", '"': '\\"', "\0": "\\0"}
    return '"' + "".join(m.get(c, c) for c in s) + '"'

def tests_for(fn):
    out = []
    for i, c in enumerate([c for c in cases if c["fn"] == fn]):
        a = c["args"]
        err = c.get("expect_err")
        if fn == "semver_valid":
            call = f"valid_is({lit(a[0])}, {'true' if c['expect'] else 'false'})"
        elif fn == "semver_compare":
            call = f"cmp_err({lit(a[0])}, {lit(a[1])})" if err else f"cmp_is({lit(a[0])}, {lit(a[1])}, {c['expect']['args'][0]})"
        else:
            call = f"sat_err({lit(a[0])}, {lit(a[1])})" if err else f"sat_is({lit(a[0])}, {lit(a[1])}, {'true' if c['expect']['args'][0] else 'false'})"
        out.append(f"pub fn test_c{i:03d}() -> [] int {{ test.assert_eq({call}, 0); return 0; }}")
    return "\n".join(out) + "\n"

def run(fn):
    n = len([c for c in cases if c["fn"] == fn])
    f = tempfile.NamedTemporaryFile("w", suffix=".cho", delete=False, encoding="utf-8")
    f.write(head + body + "\n" + HELPERS[fn] + tests_for(fn)); f.close()
    r = subprocess.run([C, "test", f.name, "--std"], capture_output=True, text=True)
    os.unlink(f.name)
    m = re.search(r"(\d+) passed; (\d+) failed", r.stdout)
    if m:
        return int(m.group(1)), n, ""
    err = [l for l in (r.stderr + r.stdout).splitlines() if "error" in l]
    return 0, n, "does not build: " + (re.sub(r"^.*?\.cho:", "line ", err[0])[:120] if err else "?")

total = 0
for fn in ("semver_valid", "semver_compare", "semver_satisfies"):
    p, n, why = run(fn)
    total += p
    print(f"  {fn}: {p}/{n} {why}")
print(f"  TOTAL {total}/{len(cases)}")
sys.exit(0 if total == len(cases) else 1)
