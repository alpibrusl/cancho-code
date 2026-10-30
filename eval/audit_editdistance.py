#!/usr/bin/env python3
"""Independent audit of a built `06-editdistance` against the lex-code backlog oracle (49 cases) plus the brief's properties (5), by group.

    CANCHO=<compiler> python3 eval/audit_editdistance.py <project.cho>

Groups: edit_distance, similarity_pct, closest (the oracle, eval/editdistance/oracle.py) and properties (the brief's "must hold" list,
checked here over a fixed pool of strings: symmetry, zero exactly when equal, triangle inequality, similarity in 0..100, and no panic
on malformed UTF-8). The shapes are the ones the plan pins (cancho has no `Str` and no list of strings; candidates are a std.vec):
    edit_distance[&r, &s](a: &r [byte], b: &s [byte]) -> [] int
    similarity_pct[&r, &s](a: &r [byte], b: &s [byte]) -> [] int
    closest[&q, &v, &s](query: &q [byte], candidates: &v vec.Vec[&s [byte]]) -> [] option.Option[&s [byte]]
Every group is its own file: a function of the wrong shape (or a crash) costs its own group only, with the compiler's first error.
Exit 0 only if every case holds. The oracle was written before any run; ORACLE= overrides it. The model under test never sees this file."""
import json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
C = os.environ.get("CANCHO", "cancho")
ORACLE = os.environ.get("ORACLE", os.path.join(HERE, "editdistance", "oracle.py"))
src = open(sys.argv[1], encoding="utf-8").read()
cases = [json.loads(l) for l in subprocess.run([sys.executable, ORACLE], capture_output=True, text=True, check=True).stdout.splitlines() if l.strip()]

body = re.sub(r"fn main\(world: World\).*?\n\}\n", "", src, flags=re.S)
body = re.sub(r"^edition \d+;\s*$", "", body, flags=re.M)
body = re.sub(r"^import std\.(option|vec|list|utf8|test);\s*$", "", body, flags=re.M)   # the harness imports these itself
body = re.sub(r"^fn ", "pub fn ", body, flags=re.M)
body = re.sub(r"^(struct|enum) ", r"pub \1 ", body, flags=re.M)
head = "edition 7;\nimport std.option;\nimport std.vec;\nimport std.list;\nimport std.utf8;\nimport std.test;\n"

HELPERS = '''
fn zz_same[&a, &b](x: &a [byte], y: &b [byte]) -> [] bool {
    if len(x) != len(y) { return false; }
    var i = 0;
    while i < len(x) { if int_of(x[i]) != int_of(y[i]) { return false; } i = i + 1; }
    return true;
}
fn zz_pool(i: int) -> [] &static [byte] {
    if i == 0 { return ""; }
    if i == 1 { return "a"; }
    if i == 2 { return "abc"; }
    if i == 3 { return "acb"; }
    if i == 4 { return "kitten"; }
    if i == 5 { return "sitting"; }
    if i == 6 { return "café"; }
    if i == 7 { return "cafe"; }
    if i == 8 { return "日本語"; }
    if i == 9 { return "日本"; }
    if i == 10 { return "é"; }
    if i == 11 { return "e"; }
    if i == 12 { return "xyzzy"; }
    return "ünïcödé";
}
fn zz_len(s: &static [byte]) -> [] int { return utf8.count(s); }
'''

# The brief says "a list of texts", which is a vec in the reference port and a list.List in a plan that reads it literally; both are fair.
# The audit builds the argument in whichever shape the built `closest` declares.
LIST_SHAPE = re.search(r"fn closest\b[^{]*list\.List", src) is not None
HELPERS += '''
fn zz_mk[&h, &r](heap: &!h Heap, s: &r [byte]) -> [heap] Box[[byte]] {
    let b = box_slice(heap, len(s), byte_of(0));
    borrow mut b as &!w in { let d = contents(w); var i = 0; while i < len(s) { d[i] = s[i]; i = i + 1; } }
    return b;
}
fn zz_ldrop[&h](heap: &!h Heap, l: list.List[Box[Box[[byte]]]]) -> [heap] int {
    match l {
        list.List::Empty => { return 0; }
        list.List::Cons(f, rest) => { unbox_slice(heap, unbox(heap, f)); let tail = unbox(heap, rest); return 1 + zz_ldrop(heap, tail); }
    }
}
'''

def lit(s):
    m = {"\n": "\\n", "\r": "\\r", "\t": "\\t", "\\": "\\\\", '"': '\\"', "\0": "\\0"}
    return '"' + "".join(m.get(c, c) for c in s) + '"'

def closest_list_test(i, c):
    q, cs = c["args"]
    none = c["expect"]["$variant"] == "None"
    want = "" if none else c["expect"]["args"][0]
    pushes = " ".join(f"l = list.push(heap, l, box(heap, zz_mk(heap, {lit(x)})));" for x in reversed(cs))
    nn = "true" if none else "false"
    return (f'pub fn test_c{i:02d}[&h](heap: &!h Heap) -> [heap] int {{ var l: list.List[Box[Box[[byte]]]] = list.List::Empty; {pushes} var code = 9; '
            f'borrow l as &lb in {{ match closest({lit(q)}, lb) {{ '
            f'option.Option::None => {{ if {nn} {{ code = 0; }} else {{ code = 1; }} }} '
            f'option.Option::Some(s) => {{ if {nn} {{ code = 2; }} else {{ if zz_same(s, {lit(want)}) {{ code = 0; }} else {{ code = 3; }} }} }} }} }} '
            f'zz_ldrop(heap, l); test.assert_eq(code, 0); return 0; }}')

def closest_test(i, c):
    if LIST_SHAPE:
        return closest_list_test(i, c)
    q, cs = c["args"]
    none = c["expect"]["$variant"] == "None"
    want = "" if none else c["expect"]["args"][0]
    pushes = " ".join(f"l = vec.push(heap, l, {lit(x)});" for x in cs)
    nn = "true" if none else "false"
    return (f'pub fn test_c{i:02d}[&h](heap: &!h Heap) -> [heap] int {{ var l = vec.empty(heap, {len(cs) + 1}, ""); {pushes} var code = 9; '
            f'borrow l as &lb in {{ match closest({lit(q)}, lb) {{ '
            f'option.Option::None => {{ if {nn} {{ code = 0; }} else {{ code = 1; }} }} '
            f'option.Option::Some(s) => {{ if {nn} {{ code = 2; }} else {{ if zz_same(s, {lit(want)}) {{ code = 0; }} else {{ code = 3; }} }} }} }} }} '
            f'vec.drop(heap, l); test.assert_eq(code, 0); return 0; }}')

def tests_for(fn):
    out = []
    for i, c in enumerate([c for c in cases if c["fn"] == fn]):
        if fn == "closest":
            out.append(closest_test(i, c))
        else:
            a, b = c["args"]
            out.append(f"pub fn test_e{i:02d}() -> [] int {{ test.assert_eq({fn}({lit(a)}, {lit(b)}), {c['expect']}); return 0; }}")
    return "\n".join(out) + "\n"

PROPS = '''
pub fn test_prop_symmetric() -> [] int {
    var i = 0;
    while i < 14 { var j = 0; while j < 14 {
        test.assert_eq(edit_distance(zz_pool(i), zz_pool(j)), edit_distance(zz_pool(j), zz_pool(i)));
        j = j + 1; } i = i + 1; }
    return 0;
}
pub fn test_prop_zero_iff_equal() -> [] int {
    var i = 0;
    while i < 14 { var j = 0; while j < 14 {
        var z = 0;
        if edit_distance(zz_pool(i), zz_pool(j)) == 0 { z = 1; }
        var e = 0;
        if zz_same(zz_pool(i), zz_pool(j)) { e = 1; }
        test.assert_eq(z, e);
        j = j + 1; } i = i + 1; }
    return 0;
}
pub fn test_prop_triangle() -> [] int {
    var i = 0;
    while i < 14 { var j = 0; while j < 14 { var k = 0; while k < 14 {
        let direct = edit_distance(zz_pool(i), zz_pool(k));
        let via = edit_distance(zz_pool(i), zz_pool(j)) + edit_distance(zz_pool(j), zz_pool(k));
        var ok = 0;
        if direct <= via { ok = 1; }
        test.assert_eq(ok, 1);
        k = k + 1; } j = j + 1; } i = i + 1; }
    return 0;
}
pub fn test_prop_similarity_range() -> [] int {
    var i = 0;
    while i < 14 { var j = 0; while j < 14 {
        let s = similarity_pct(zz_pool(i), zz_pool(j));
        var ok = 0;
        if s >= 0 && s <= 100 { ok = 1; }
        test.assert_eq(ok, 1);
        let d = edit_distance(zz_pool(i), zz_pool(j));
        var ok2 = 0;
        var m = zz_len(zz_pool(i));
        if zz_len(zz_pool(j)) > m { m = zz_len(zz_pool(j)); }
        if d >= 0 && d <= m { ok2 = 1; }
        test.assert_eq(ok2, 1);
        j = j + 1; } i = i + 1; }
    return 0;
}
pub fn test_prop_malformed_no_panic() -> [] int {
    region r {
        let bad = alloc_slice[r](5, byte_of(97));
        bad[1] = byte_of(255);
        bad[2] = byte_of(195);
        bad[3] = byte_of(128);
        bad[4] = byte_of(194);
        var i = 0;
        while i < 14 {
            let d = edit_distance(bad, zz_pool(i));
            let e = edit_distance(zz_pool(i), bad);
            let s = similarity_pct(bad, zz_pool(i));
            var ok = 0;
            if d >= 0 && e >= 0 && s >= 0 && s <= 100 { ok = 1; }
            test.assert_eq(ok, 1);
            i = i + 1;
        }
    }
    return 0;
}
'''

def run(group):
    if group == "properties":
        n, text = 5, PROPS
    else:
        n, text = len([c for c in cases if c["fn"] == group]), tests_for(group)
    f = tempfile.NamedTemporaryFile("w", suffix=".cho", delete=False, encoding="utf-8")
    f.write(head + body + "\n" + HELPERS + text); f.close()
    r = subprocess.run([C, "test", f.name, "--std", "--backend", "cranelift"], capture_output=True, text=True)
    os.unlink(f.name)
    m = re.search(r"(\d+) passed; (\d+) failed", r.stdout)
    if m:
        return int(m.group(1)), n, ""
    err = [l for l in (r.stderr + r.stdout).splitlines() if "error" in l]
    return 0, n, "does not build or crashed: " + (re.sub(r"^.*?\.cho:", "line ", err[0])[:120] if err else "?")

total = want = 0
for g in ("edit_distance", "similarity_pct", "closest", "properties"):
    p, n, why = run(g)
    total += p; want += n
    print(f"  {g}: {p}/{n} {why}")
print(f"  TOTAL {total}/{want}")
sys.exit(0 if total == want else 1)
