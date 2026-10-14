#!/usr/bin/env python3
"""Independent audit of a built `roman` against eval/roman/oracle.py, by function group.

    CANCHO=<compiler> python3 eval/audit_roman.py <project.cho>

Shapes (the plan pins them; cancho has no string type):
    to_roman[&h](heap: &!h Heap, n: int) -> [heap] result.Result[buffer.Buffer, &static [byte]]
    from_roman[&r](text: &r [byte]) -> [] result.Result[int, &static [byte]]
Groups: to_roman, from_roman, roundtrip (one case: from_roman(to_roman(n)) == n for every n in 1..3999).
A file that does not build scores 0 for the group that needs it, with the compiler's first error.
Exit 0 only if every case holds. ORACLE= overrides the oracle. The model under test never sees this file."""
import json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
C = os.environ.get("CANCHO", "cancho")
ORACLE = os.environ.get("ORACLE", os.path.join(HERE, "roman", "oracle.py"))
src = open(sys.argv[1], encoding="utf-8").read()
cases = [json.loads(l) for l in subprocess.run([sys.executable, ORACLE], capture_output=True, text=True, check=True).stdout.splitlines() if l.strip()]

body = re.sub(r"fn main\(world: World\).*?\n\}\n", "", src, flags=re.S)
body = re.sub(r"^edition \d+;\s*$", "", body, flags=re.M)
body = re.sub(r"^import std\.(result|buffer|bytes|test);\s*$", "", body, flags=re.M)
body = re.sub(r"^fn ", "pub fn ", body, flags=re.M)
body = re.sub(r"^(struct|enum) ", r"pub \1 ", body, flags=re.M)
head = "edition 7;\nimport std.result;\nimport std.buffer;\nimport std.bytes;\nimport std.test;\n"

TO_HELPERS = '''
fn t_is[&h](heap: &!h Heap, n: int, want: &static [byte]) -> [heap] int {
    match to_roman(heap, n) {
        result.Result::Ok(b) => {
            var same = false;
            borrow b as &x in { same = bytes.equal(buffer.bytes(x), want); }
            buffer.drop(heap, b);
            if same { return 0; }
            return 1;
        }
        result.Result::Err(_) => { return 2; }
    }
}
fn t_err[&h](heap: &!h Heap, n: int) -> [heap] int {
    match to_roman(heap, n) {
        result.Result::Ok(b) => { buffer.drop(heap, b); return 1; }
        result.Result::Err(_) => { return 0; }
    }
}
'''
FROM_HELPERS = '''
fn f_is(s: &static [byte], want: int) -> [] int {
    match from_roman(s) {
        result.Result::Ok(v) => { if v == want { return 0; } return 1; }
        result.Result::Err(_) => { return 2; }
    }
}
fn f_err(s: &static [byte]) -> [] int {
    match from_roman(s) {
        result.Result::Ok(_) => { return 1; }
        result.Result::Err(_) => { return 0; }
    }
}
'''
RT_HELPERS = '''
fn rt_one[&h](heap: &!h Heap, n: int) -> [heap] int {
    match to_roman(heap, n) {
        result.Result::Ok(b) => {
            var r = 1;
            borrow b as &x in {
                match from_roman(buffer.bytes(x)) {
                    result.Result::Ok(v) => { if v == n { r = 0; } }
                    result.Result::Err(_) => { r = 3; }
                }
            }
            buffer.drop(heap, b);
            return r;
        }
        result.Result::Err(_) => { return 2; }
    }
}
pub fn test_roundtrip_all[&h](heap: &!h Heap) -> [heap] int {
    var bad = 0;
    var n = 1;
    while n <= 3999 { bad = bad + rt_one(heap, n); n = n + 1; }
    test.assert_eq(bad, 0);
    return 0;
}
'''

def lit(s):
    m = {"\n": "\\n", "\r": "\\r", "\t": "\\t", "\\": "\\\\", '"': '\\"', "\0": "\\0"}
    return '"' + "".join(m.get(c, c) for c in s) + '"'

def is_err(c): return c.get("expect_err") or (isinstance(c.get("expect"), dict) and c["expect"].get("$variant") == "Err")

def tests_for(fn):
    out = []
    for i, c in enumerate([c for c in cases if c["fn"] == fn]):
        a = c["args"][0]; err = is_err(c)
        if fn == "to_roman":
            call = f"t_err(heap, {a})" if err else f"t_is(heap, {a}, {lit(c['expect']['args'][0])})"
            out.append(f"pub fn test_t{i:03d}[&h](heap: &!h Heap) -> [heap] int {{ test.assert_eq({call}, 0); return 0; }}")
        else:
            call = f"f_err({lit(a)})" if err else f"f_is({lit(a)}, {c['expect']['args'][0]})"
            out.append(f"pub fn test_f{i:03d}() -> [] int {{ test.assert_eq({call}, 0); return 0; }}")
    return "\n".join(out) + "\n"

GROUPS = {"to_roman": (TO_HELPERS, lambda: tests_for("to_roman")),
          "from_roman": (FROM_HELPERS, lambda: tests_for("from_roman")),
          "roundtrip": (RT_HELPERS, lambda: "")}

def run(g):
    n = len([c for c in cases if c["fn"] == g])
    helpers, mk = GROUPS[g]
    f = tempfile.NamedTemporaryFile("w", suffix=".cho", delete=False, encoding="utf-8")
    f.write(head + body + "\n" + helpers + mk()); f.close()
    r = subprocess.run([C, "test", f.name, "--std", "--backend", "cranelift"], capture_output=True, text=True)
    os.unlink(f.name)
    m = re.search(r"(\d+) passed; (\d+) failed", r.stdout)
    if m:
        return int(m.group(1)), n, ""
    err = [l for l in (r.stderr + r.stdout).splitlines() if "error" in l]
    return 0, n, "does not build: " + (re.sub(r"^.*?\.cho:", "line ", err[0])[:120] if err else "?")

total = 0
for g in GROUPS:
    p, n, why = run(g)
    total += p
    print(f"  {g}: {p}/{n} {why}")
print(f"  TOTAL {total}/{len(cases)}")
sys.exit(0 if total == len(cases) else 1)
