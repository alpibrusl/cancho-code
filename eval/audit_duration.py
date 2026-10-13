#!/usr/bin/env python3
"""Independent audit of a built `05-duration` against the lex-code backlog oracle (64 cases), parse and format graded separately.

    CANCHO=<compiler> python3 eval/audit_duration.py <project.cho>

The shapes are the ones the plan pins (cancho has no `Str`, so the brief's `Str` becomes bytes and a heap-owned Buffer):
    duration_parse[&r](s: &r [byte]) -> [] result.Result[int, &static [byte]]
    duration_format[&h](heap: &!h Heap, seconds: int) -> [heap] result.Result[buffer.Buffer, &static [byte]]
A file that does not build in those shapes scores 0 for the group that needs them, with the compiler's first error.
Exit 0 only if every case holds. The oracle (eval/duration/oracle.py) was written before any run; ORACLE= overrides it. The model
under test never sees this file."""
import json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
C = os.environ.get("CANCHO", "cancho")
ORACLE = os.environ.get("ORACLE", os.path.join(HERE, "duration", "oracle.py"))
src = open(sys.argv[1], encoding="utf-8").read()
cases = [json.loads(l) for l in subprocess.run([sys.executable, ORACLE], capture_output=True, text=True, check=True).stdout.splitlines() if l.strip()]

body = re.sub(r"fn main\(world: World\).*?\n\}\n", "", src, flags=re.S)
body = re.sub(r"^edition \d+;\s*$", "", body, flags=re.M)
body = re.sub(r"^import std\.(result|buffer|bytes|test);\s*$", "", body, flags=re.M)   # the harness imports these itself
body = re.sub(r"^fn ", "pub fn ", body, flags=re.M)
body = re.sub(r"^(struct|enum) ", r"pub \1 ", body, flags=re.M)
head = "edition 7;\nimport std.result;\nimport std.buffer;\nimport std.bytes;\nimport std.test;\n"

FMT_HELPERS = '''
fn fmt_is[&h](heap: &!h Heap, n: int, want: &static [byte]) -> [heap] int {
    match duration_format(heap, n) {
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
fn fmt_err[&h](heap: &!h Heap, n: int) -> [heap] int {
    match duration_format(heap, n) {
        result.Result::Ok(b) => { buffer.drop(heap, b); return 1; }
        result.Result::Err(_) => { return 0; }
    }
}
'''
PARSE_HELPERS = '''
fn parse_is(s: &static [byte], want: int) -> [] int {
    match duration_parse(s) {
        result.Result::Ok(v) => { if v == want { return 0; } return 1; }
        result.Result::Err(_) => { return 2; }
    }
}
fn parse_err(s: &static [byte]) -> [] int {
    match duration_parse(s) {
        result.Result::Ok(_) => { return 1; }
        result.Result::Err(_) => { return 0; }
    }
}
'''
# Each group is its own file with its own helpers: a function of the wrong shape must cost its own group only.

def lit(s):
    m = {"\n": "\\n", "\r": "\\r", "\t": "\\t", "\\": "\\\\", '"': '\\"', "\0": "\\0"}
    return '"' + "".join(m.get(c, c) for c in s) + '"'

def tests_for(fn):
    out = []
    for i, c in enumerate([c for c in cases if c["fn"] == fn]):
        a = c["args"][0]
        err = c.get("expect_err") or (isinstance(c.get("expect"), dict) and c["expect"].get("$variant") == "Err")
        want = None if err else c["expect"]["args"][0]
        if fn == "duration_parse":
            call = f"parse_err({lit(a)})" if err else f"parse_is({lit(a)}, {want})"
            out.append(f"pub fn test_p{i:02d}() -> [] int {{ test.assert_eq({call}, 0); return 0; }}")
        else:
            call = f"fmt_err(heap, {a})" if err else f"fmt_is(heap, {a}, {lit(want)})"
            out.append(f"pub fn test_f{i:02d}[&h](heap: &!h Heap) -> [heap] int {{ test.assert_eq({call}, 0); return 0; }}")
    return "\n".join(out) + "\n"

def run(fn):
    n = len([c for c in cases if c["fn"] == fn])
    f = tempfile.NamedTemporaryFile("w", suffix=".cho", delete=False, encoding="utf-8")
    f.write(head + body + "\n" + (PARSE_HELPERS if fn == "duration_parse" else FMT_HELPERS) + tests_for(fn)); f.close()
    r = subprocess.run([C, "test", f.name, "--std"], capture_output=True, text=True)
    os.unlink(f.name)
    m = re.search(r"(\d+) passed; (\d+) failed", r.stdout)
    if m:
        return int(m.group(1)), n, ""
    err = [l for l in (r.stderr + r.stdout).splitlines() if "error" in l]
    return 0, n, "does not build: " + (re.sub(r"^.*?\.cho:", "line ", err[0])[:120] if err else "?")

total = 0
for fn in ("duration_parse", "duration_format"):
    p, n, why = run(fn)
    total += p
    print(f"  {fn}: {p}/{n} {why}")
print(f"  TOTAL {total}/{len(cases)}")
sys.exit(0 if total == len(cases) else 1)
