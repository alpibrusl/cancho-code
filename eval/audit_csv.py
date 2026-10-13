#!/usr/bin/env python3
"""Independent audit of a built `03-csv` against the lex-code backlog oracle (50 cases), parse and format graded separately.

    CANCHO=<compiler> python3 eval/audit_csv.py <project.cho>

The shapes are the ones the plan pins (cancho has no `Str` and no list of strings; the field list uses one more `Box` than it
looks like it needs, because the compiler cannot match a `Box[[byte]]` through a reference: alpibrusl/cancho#461):
    csv_parse_line[&h, &r](heap: &!h Heap, line: &r [byte]) -> [heap] result.Result[list.List[Box[Box[[byte]]]], int]
    csv_format_line[&h, &l](heap: &!h Heap, fields: &l list.List[Box[Box[[byte]]]]) -> [heap] Box[[byte]]
A file that does not build in those shapes scores 0 for the group that needs them, with the compiler's first error.
Exit 0 only if every case holds. The oracle (eval/csv/oracle.py) was written before any run; ORACLE= overrides it. The model under
test never sees this file."""
import json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
C = os.environ.get("CANCHO", "cancho")
ORACLE = os.environ.get("ORACLE", os.path.join(HERE, "csv", "oracle.py"))
src = open(sys.argv[1], encoding="utf-8").read()
cases = [json.loads(l) for l in subprocess.run([sys.executable, ORACLE], capture_output=True, text=True, check=True).stdout.splitlines() if l.strip()]

body = re.sub(r"fn main\(world: World\).*?\n\}\n", "", src, flags=re.S)
body = re.sub(r"^edition \d+;\s*$", "", body, flags=re.M)
body = re.sub(r"^import std\.(list|result|test);\s*$", "", body, flags=re.M)   # the harness imports these itself
body = re.sub(r"^fn ", "pub fn ", body, flags=re.M)
body = re.sub(r"^(struct|enum) ", r"pub \1 ", body, flags=re.M)
head = "edition 7;\nimport std.list;\nimport std.result;\nimport std.test;\n"

HELPERS = '''
fn zz_drop[&h](heap: &!h Heap, fields: list.List[Box[Box[[byte]]]]) -> [heap] int {
    match fields {
        list.List::Empty => { return 0; }
        list.List::Cons(f, rest) => {
            unbox_slice(heap, unbox(heap, f));
            let tail = unbox(heap, rest);
            return 1 + zz_drop(heap, tail);
        }
    }
}
fn zz_same[&a, &b](x: &a [byte], y: &b [byte]) -> [] bool {
    if len(x) != len(y) { return false; }
    var k = 0;
    while k < len(x) { if x[k] != y[k] { return false; } k = k + 1; }
    return true;
}
fn zz_nth_is[&l, &r](fields: &l list.List[Box[Box[[byte]]]], idx: int, want: &r [byte]) -> [] bool {
    match fields {
        list.List::Empty => { return false; }
        list.List::Cons(f, rest) => {
            if idx == 0 { return zz_same(contents(contents(f)), want); }
            return zz_nth_is(contents(rest), idx - 1, want);
        }
    }
}
fn zz_mk[&h, &r](heap: &!h Heap, s: &r [byte]) -> [heap] Box[[byte]] {
    let b = box_slice(heap, len(s), byte_of(0));
    borrow mut b as &!w in { copy_into(contents(w), s); }
    return b;
}
'''

def lit(s):
    m = {"\n": "\\n", "\r": "\\r", "\t": "\\t", "\\": "\\\\", '"': '\\"', "\0": "\\0"}
    return '"' + "".join(m.get(c, c) for c in s) + '"'

def parse_test(i, c):
    line = lit(c["args"][0])
    if c.get("expect_err"):
        return (f"pub fn test_p{i:02d}[&h](heap: &!h Heap) -> [heap] int {{\n"
                f"    match csv_parse_line(heap, {line}) {{\n"
                f"        result.Result::Ok(fs) => {{ zz_drop(heap, fs); return 1; }}\n"
                f"        result.Result::Err(_) => {{ return 0; }}\n    }}\n}}\n")
    want = c["expect"]["args"][0]
    checks = "".join(f"                if !zz_nth_is(r, {k}, {lit(f)}) {{ ok = false; }}\n" for k, f in enumerate(want))
    return (f"pub fn test_p{i:02d}[&h](heap: &!h Heap) -> [heap] int {{\n"
            f"    match csv_parse_line(heap, {line}) {{\n"
            f"        result.Result::Ok(fs) => {{\n            var ok = true;\n"
            f"            borrow fs as &r in {{\n                if list.length(r) != {len(want)} {{ ok = false; }}\n{checks}            }}\n"
            f"            zz_drop(heap, fs);\n            if ok {{ return 0; }}\n            return 1;\n        }}\n"
            f"        result.Result::Err(_) => {{ return 2; }}\n    }}\n}}\n")

def format_test(i, c):
    fields = c["args"][0]
    pushes = "".join(f"    l = list.push(heap, l, box(heap, zz_mk(heap, {lit(f)})));\n" for f in reversed(fields))
    return (f"pub fn test_f{i:02d}[&h](heap: &!h Heap) -> [heap] int {{\n"
            f"    var l: list.List[Box[Box[[byte]]]] = list.List::Empty;\n{pushes}"
            f"    var ok = false;\n    borrow l as &r in {{\n        let out = csv_format_line(heap, r);\n"
            f"        borrow out as &q in {{ ok = zz_same(contents(q), {lit(c['expect'])}); }}\n        unbox_slice(heap, out);\n    }}\n"
            f"    zz_drop(heap, l);\n    if ok {{ return 0; }}\n    return 1;\n}}\n")

def run(fn):
    mine = [c for c in cases if c["fn"] == fn]
    gen = parse_test if fn == "csv_parse_line" else format_test
    tests = "".join(gen(i, c) for i, c in enumerate(mine))
    f = tempfile.NamedTemporaryFile("w", suffix=".cho", delete=False, encoding="utf-8")
    f.write(head + body + "\n" + HELPERS + tests); f.close()
    r = subprocess.run([C, "test", f.name, "--std"], capture_output=True, text=True)
    os.unlink(f.name)
    m = re.search(r"(\d+) passed; (\d+) failed", r.stdout)
    if m:
        return int(m.group(1)), len(mine), ""
    err = [l for l in (r.stderr + r.stdout).splitlines() if "error" in l]
    return 0, len(mine), "does not build: " + (re.sub(r"^.*?\.cho:", "line ", err[0])[:130] if err else "?")

total = 0
for fn in ("csv_parse_line", "csv_format_line"):
    p, n, why = run(fn)
    total += p
    print(f"  {fn}: {p}/{n} {why}")
print(f"  TOTAL {total}/{len(cases)}")
sys.exit(0 if total == len(cases) else 1)
