#!/usr/bin/env python3
"""Independent audit of a built `04-jsonptr` against the lex-code backlog oracle, one group per function, plus a round-trip group.

    CANCHO=<compiler> python3 eval/audit_jsonptr.py <project.cho>

The shapes are the ones the plan pins (cancho has no `Str` and no list of strings; the token list uses one more `Box` than it
looks like it needs, because the compiler cannot match a `Box[[byte]]` through a reference: alpibrusl/cancho#461):
    ptr_parse[&h, &r](heap: &!h Heap, p: &r [byte]) -> [heap] result.Result[list.List[Box[Box[[byte]]]], &static [byte]]
    ptr_format[&h, &l](heap: &!h Heap, tokens: &l list.List[Box[Box[[byte]]]]) -> [heap] buffer.Buffer
    ptr_append[&h, &r, &t](heap: &!h Heap, p: &r [byte], token: &t [byte]) -> [heap] result.Result[buffer.Buffer, &static [byte]]
    ptr_parent[&r](p: &r [byte]) -> [] result.Result[&r [byte], &static [byte]]
Groups: the four functions (oracle.py, vendored unchanged, 134 cases) and `roundtrip`, the brief's two properties checked on
the oracle's own inputs: parse(format(tokens)) == tokens, and format(parse(p)) == p for every valid p. A file that does not build
in those shapes scores 0 for the group that needs them, with the compiler's first error. Exit 0 only if every case holds.
ORACLE= overrides the oracle. The model under test never sees this file."""
import json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
C = os.environ.get("CANCHO", "cancho")
ORACLE = os.environ.get("ORACLE", os.path.join(HERE, "jsonptr", "oracle.py"))
src = open(sys.argv[1], encoding="utf-8").read()
cases = [json.loads(l) for l in subprocess.run([sys.executable, ORACLE], capture_output=True, text=True, check=True).stdout.splitlines() if l.strip()]

body = re.sub(r"fn main\(world: World\).*?\n\}\n", "", src, flags=re.S)
body = re.sub(r"^edition \d+;\s*$", "", body, flags=re.M)
body = re.sub(r"^import std\.(list|result|buffer|test);\s*$", "", body, flags=re.M)   # the harness imports these itself
body = re.sub(r"^fn ", "pub fn ", body, flags=re.M)
body = re.sub(r"^(struct|enum) ", r"pub \1 ", body, flags=re.M)
head = "edition 7;\nimport std.list;\nimport std.result;\nimport std.buffer;\nimport std.test;\n"

HELPERS = '''
@@SAME
fn zz_same[&a, &b](x: &a [byte], y: &b [byte]) -> [] bool {
    if len(x) != len(y) { return false; }
    var k = 0;
    while k < len(x) { if x[k] != y[k] { return false; } k = k + 1; }
    return true;
}
@@LIST
fn zz_drop[&h](heap: &!h Heap, l: list.List[Box[Box[[byte]]]]) -> [heap] int {
    match l {
        list.List::Empty => { return 0; }
        list.List::Cons(f, rest) => {
            unbox_slice(heap, unbox(heap, f));
            let tail = unbox(heap, rest);
            return 1 + zz_drop(heap, tail);
        }
    }
}
fn zz_nth_is[&l, &r](l: &l list.List[Box[Box[[byte]]]], idx: int, want: &r [byte]) -> [] bool {
    match l {
        list.List::Empty => { return false; }
        list.List::Cons(f, rest) => {
            if idx == 0 { return zz_same(contents(contents(f)), want); }
            return zz_nth_is(contents(rest), idx - 1, want);
        }
    }
}
fn zz_eq[&a, &b](x: &a list.List[Box[Box[[byte]]]], y: &b list.List[Box[Box[[byte]]]]) -> [] bool {
    match x {
        list.List::Empty => {
            match y {
                list.List::Empty => { return true; }
                list.List::Cons(_, _) => { return false; }
            }
        }
        list.List::Cons(f, rest) => {
            match y {
                list.List::Empty => { return false; }
                list.List::Cons(g, rest2) => {
                    if zz_same(contents(contents(f)), contents(contents(g))) == false { return false; }
                    return zz_eq(contents(rest), contents(rest2));
                }
            }
        }
    }
}
fn zz_mk[&h, &r](heap: &!h Heap, s: &r [byte]) -> [heap] Box[[byte]] {
    let b = box_slice(heap, len(s), byte_of(0));
    borrow mut b as &!w in { copy_into(contents(w), s); }
    return b;
}
@@FMT
fn zz_fmt_is[&h, &l](heap: &!h Heap, l: &l list.List[Box[Box[[byte]]]], want: &static [byte]) -> [heap] int {
    let out = ptr_format(heap, l);
    var same = false;
    borrow out as &x in { same = zz_same(buffer.bytes(x), want); }
    buffer.drop(heap, out);
    if same { return 0; }
    return 1;
}
@@APP
fn zz_append_is[&h](heap: &!h Heap, p: &static [byte], t: &static [byte], want: &static [byte]) -> [heap] int {
    match ptr_append(heap, p, t) {
        result.Result::Ok(b) => {
            var same = false;
            borrow b as &x in { same = zz_same(buffer.bytes(x), want); }
            buffer.drop(heap, b);
            if same { return 0; }
            return 1;
        }
        result.Result::Err(_) => { return 2; }
    }
}
fn zz_append_err[&h](heap: &!h Heap, p: &static [byte], t: &static [byte]) -> [heap] int {
    match ptr_append(heap, p, t) {
        result.Result::Ok(b) => { buffer.drop(heap, b); return 1; }
        result.Result::Err(_) => { return 0; }
    }
}
@@PAR
fn zz_parent_is(p: &static [byte], want: &static [byte]) -> [] int {
    match ptr_parent(p) {
        result.Result::Ok(q) => { if zz_same(q, want) { return 0; } return 1; }
        result.Result::Err(_) => { return 2; }
    }
}
fn zz_parent_err(p: &static [byte]) -> [] int {
    match ptr_parent(p) {
        result.Result::Ok(_) => { return 1; }
        result.Result::Err(_) => { return 0; }
    }
}
'''

def lit(s):
    m = {"\n": "\\n", "\r": "\\r", "\t": "\\t", "\\": "\\\\", '"': '\\"', "\0": "\\0"}
    return '"' + "".join(m.get(c, c) for c in s) + '"'

def build_list(heap, var, toks):
    return f"    var {var}: list.List[Box[Box[[byte]]]] = list.List::Empty;\n" + "".join(
        f"    {var} = list.push({heap}, {var}, box({heap}, zz_mk({heap}, {lit(t)})));\n" for t in reversed(toks))

def parse_test(i, c):
    p = lit(c["args"][0])
    if c.get("expect_err"):
        return (f"pub fn test_p{i:03d}[&h](heap: &!h Heap) -> [heap] int {{\n    match ptr_parse(heap, {p}) {{\n"
                f"        result.Result::Ok(l) => {{ zz_drop(heap, l); return 1; }}\n        result.Result::Err(_) => {{ return 0; }}\n    }}\n}}\n")
    want = c["expect"]["args"][0]
    checks = "".join(f"                if !zz_nth_is(r, {k}, {lit(t)}) {{ ok = false; }}\n" for k, t in enumerate(want))
    return (f"pub fn test_p{i:03d}[&h](heap: &!h Heap) -> [heap] int {{\n    match ptr_parse(heap, {p}) {{\n"
            f"        result.Result::Ok(l) => {{\n            var ok = true;\n            borrow l as &r in {{\n"
            f"                if list.length(r) != {len(want)} {{ ok = false; }}\n{checks}            }}\n"
            f"            zz_drop(heap, l);\n            if ok {{ return 0; }}\n            return 1;\n        }}\n"
            f"        result.Result::Err(_) => {{ return 2; }}\n    }}\n}}\n")

def format_test(i, c):
    return (f"pub fn test_f{i:03d}[&h](heap: &!h Heap) -> [heap] int {{\n{build_list('heap', 'l', c['args'][0])}"
            f"    var st = 1;\n    borrow l as &r in {{ st = zz_fmt_is(heap, r, {lit(c['expect'])}); }}\n"
            f"    zz_drop(heap, l);\n    test.assert_eq(st, 0);\n    return 0;\n}}\n")

def append_test(i, c):
    p, t = c["args"]
    call = (f"zz_append_err(heap, {lit(p)}, {lit(t)})" if c.get("expect_err")
            else f"zz_append_is(heap, {lit(p)}, {lit(t)}, {lit(c['expect']['args'][0])})")
    return f"pub fn test_a{i:03d}[&h](heap: &!h Heap) -> [heap] int {{ test.assert_eq({call}, 0); return 0; }}\n"

def parent_test(i, c):
    p = c["args"][0]
    call = f"zz_parent_err({lit(p)})" if c.get("expect_err") else f"zz_parent_is({lit(p)}, {lit(c['expect']['args'][0])})"
    return f"pub fn test_q{i:03d}() -> [] int {{ test.assert_eq({call}, 0); return 0; }}\n"

def roundtrip_tests():
    out, k = [], 0
    toks, ptrs = set(), []
    for c in cases:
        if c["fn"] == "ptr_format": toks.add(json.dumps(c["args"][0]))
        if c["fn"] == "ptr_parse" and not c.get("expect_err"): ptrs.append(c["args"][0])
    for t in sorted(toks):   # parse(format(tokens)) == tokens
        t = json.loads(t)
        out.append(f"pub fn test_r{k:03d}[&h](heap: &!h Heap) -> [heap] int {{\n{build_list('heap', 'l', t)}"
                   f"    var st = 1;\n    borrow l as &r in {{\n        let b = ptr_format(heap, r);\n        borrow b as &x in {{\n"
                   f"            match ptr_parse(heap, buffer.bytes(x)) {{\n"
                   f"                result.Result::Ok(m) => {{ borrow m as &y in {{ if zz_eq(r, y) {{ st = 0; }} }} zz_drop(heap, m); }}\n"
                   f"                result.Result::Err(_) => {{ st = 2; }}\n            }}\n        }}\n        buffer.drop(heap, b);\n    }}\n"
                   f"    zz_drop(heap, l);\n    test.assert_eq(st, 0);\n    return 0;\n}}\n")
        k += 1
    for p in ptrs:   # format(parse(p)) == p
        out.append(f"pub fn test_r{k:03d}[&h](heap: &!h Heap) -> [heap] int {{\n    match ptr_parse(heap, {lit(p)}) {{\n"
                   f"        result.Result::Ok(l) => {{\n            var st = 1;\n            borrow l as &r in {{ st = zz_fmt_is(heap, r, {lit(p)}); }}\n"
                   f"            zz_drop(heap, l);\n            test.assert_eq(st, 0);\n            return 0;\n        }}\n"
                   f"        result.Result::Err(_) => {{ return 1; }}\n    }}\n}}\n")
        k += 1
    return out

_parts = re.split(r"@@(SAME|LIST|FMT|APP|PAR)\n", HELPERS)
H = {"COMMON": "", **{_parts[i]: _parts[i + 1] for i in range(1, len(_parts), 2)}}
# each group gets only the helpers that call its own function: a missing or mis-shaped function costs its own group only
NEEDS = {"ptr_parse": ["SAME", "LIST"], "ptr_format": ["SAME", "LIST", "FMT"], "ptr_append": ["SAME", "APP"], "ptr_parent": ["SAME", "PAR"], "roundtrip": ["SAME", "LIST", "FMT"]}

GROUPS = [("ptr_parse", parse_test), ("ptr_format", format_test), ("ptr_append", append_test), ("ptr_parent", parent_test)]

def run(tests, n, group):
    f = tempfile.NamedTemporaryFile("w", suffix=".cho", delete=False, encoding="utf-8")
    f.write(head + body + "\n" + "".join(H[k] for k in NEEDS[group]) + "".join(tests)); f.close()
    r = subprocess.run([C, "test", f.name, "--std"], capture_output=True, text=True)
    os.unlink(f.name)
    m = re.search(r"(\d+) passed; (\d+) failed", r.stdout)
    if m:
        return int(m.group(1)), n, ""
    err = [l for l in (r.stderr + r.stdout).splitlines() if "error" in l]
    return 0, n, "does not build: " + (re.sub(r"^.*?\.cho:", "line ", err[0])[:130] if err else "?")

total = grand = 0
for fn, gen in GROUPS:
    mine = [c for c in cases if c["fn"] == fn]
    p, n, why = run([gen(i, c) for i, c in enumerate(mine)], len(mine), fn)
    total += p; grand += n
    print(f"  {fn}: {p}/{n} {why}")
rt = roundtrip_tests()
p, n, why = run(rt, len(rt), "roundtrip")
total += p; grand += n
print(f"  roundtrip: {p}/{n} {why}")
print(f"  TOTAL {total}/{grand}")
sys.exit(0 if total == grand else 1)
