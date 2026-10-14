#!/usr/bin/env python3
"""Independent audit of a built `08-ini` against the lex-code backlog oracle (49 cases) plus a few extra cases of our own,
parse and get graded separately.

    CANCHO=<compiler> python3 eval/audit_ini.py <project.cho>

The shapes are the ones the plan pins (cancho has no `Str` and no list of strings): a list of "name=value" settings is one
heap-owned buffer.Buffer holding the entries, each terminated by a line feed; Err carries the 1-based number of the first
malformed line (the brief says the message must name it):
    ini_parse[&h, &t](heap: &!h Heap, text: &t [byte]) -> [heap] result.Result[buffer.Buffer, int]
    ini_get[&h, &t, &s, &k](heap: &!h Heap, text: &t [byte], section: &s [byte], key: &k [byte])
        -> [heap] result.Result[option.Option[buffer.Buffer], int]
Groups: ini_parse (oracle parse cases), ini_get (oracle get cases), ini_errline (extra: the Err must carry the right line number,
hand-computed below, cross-checked against the oracle's reference parser), ini_extra (extra get cases, hand-computed).
A file that does not build in those shapes scores 0 for the group that needs them, with the compiler's first error.
Exit 0 only if every case holds. The oracle (eval/ini/oracle.py, vendored unchanged) was written before any run; ORACLE= overrides
it. The model under test never sees this file."""
import importlib.util, json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
C = os.environ.get("CANCHO", "cancho")
ORACLE = os.environ.get("ORACLE", os.path.join(HERE, "ini", "oracle.py"))
src = open(sys.argv[1], encoding="utf-8").read()
cases = [json.loads(l) for l in subprocess.run([sys.executable, ORACLE], capture_output=True, text=True, check=True).stdout.splitlines() if l.strip()]

# Extra cases, computed by hand from the brief. (text, line number of the first malformed line)
ERRLINE = [("=novalue", 1), ("a b=1", 1), ("[unclosed\na=1", 1), ("[]\na=1", 1), ("[a]b]\nk=1", 1), ("[a=b]\nk=1", 1),
           ("just text", 1), ("a=1\njust text", 2), ("[s] trailing\na=1", 1), ("\n\n=x", 3), ("a=1\r\n[bad\r\n", 2),
           ("a=1\n\n; c\nx y=2", 4), ("# only\n[s]\nk=1\n=2\nbad", 4), ("[s]\nキー=1", 2), ("a=1\n", None)]
# (text, section, key, expected value or None for absent)
EXTRA_GET = [("k=1\nk=2", "", "k", "2"), ("[日本]\nk=値", "日本", "k", "値"), ("a=", "", "a", ""), ("[s]\nk=\"  x  \"", "s", "k", "  x  "),
             ("[s]\nk=1\n[t]\nk=2\n[s]\nk=3", "s", "k", "3"), ("a=1\n[s]\nb=2", "s", "a", None), ("a=1\n[s]\nb=2", "", "b", None),
             ("[s]\nk=a=b", "s", "k", "a=b"), ("a=1\r\nb=2\r\n", "", "b", "2"), ("[s]\n[t]\nk=1", "s", "k", None), ("a=\"", "", "a", "\""), ("a=\"\"", "", "a", "")]

# Cross-check the hand-computed line numbers against the oracle's own reference parser (independent of the oracle's case list).
spec = importlib.util.spec_from_file_location("ini_oracle_ref", ORACLE)
sys.stdout = open(os.devnull, "w")           # importing the oracle runs its main(), which prints; discard that
ref = importlib.util.module_from_spec(spec); spec.loader.exec_module(ref)
sys.stdout = sys.__stdout__
for t, n in ERRLINE:
    assert (ref.parse(t) is None) == (n is not None), t
    if n is not None:
        lines = t.split("\n")
        assert ref.parse("\n".join(lines[:n - 1])) is not None and ref.parse("\n".join(lines[:n])) is None, (t, n)
for t, s, k, v in EXTRA_GET:
    r = ref.parse(t); d = dict(x.split("=", 1) for x in r)
    assert d.get((s + "." if s else "") + k) == v, (t, s, k)

body = re.sub(r"fn main\(world: World\).*?\n\}\n", "", src, flags=re.S)
body = re.sub(r"^edition \d+;\s*$", "", body, flags=re.M)
body = re.sub(r"^import std\.(option|result|buffer|bytes|test);\s*$", "", body, flags=re.M)   # the harness imports these itself
body = re.sub(r"^fn ", "pub fn ", body, flags=re.M)
body = re.sub(r"^(struct|enum) ", r"pub \1 ", body, flags=re.M)
head = "edition 7;\nimport std.option;\nimport std.result;\nimport std.buffer;\nimport std.bytes;\nimport std.test;\n"

HELPERS = '''
fn zz_parse_is[&h](heap: &!h Heap, text: &static [byte], want: &static [byte]) -> [heap] int {
    match ini_parse(heap, text) {
        result.Result::Err(_) => { return 2; }
        result.Result::Ok(b) => {
            var st = 1;
            borrow b as &r in { if bytes.equal(buffer.bytes(r), want) { st = 0; } }
            buffer.drop(heap, b);
            return st;
        }
    }
}
fn zz_parse_err[&h](heap: &!h Heap, text: &static [byte]) -> [heap] int {
    match ini_parse(heap, text) {
        result.Result::Err(_) => { return 0; }
        result.Result::Ok(b) => { buffer.drop(heap, b); return 3; }
    }
}
fn zz_parse_errline[&h](heap: &!h Heap, text: &static [byte], line: int) -> [heap] int {
    match ini_parse(heap, text) {
        result.Result::Err(n) => { if n == line { return 0; } return 4; }
        result.Result::Ok(b) => { buffer.drop(heap, b); return 3; }
    }
}
fn zz_parse_ok_only[&h](heap: &!h Heap, text: &static [byte]) -> [heap] int {
    match ini_parse(heap, text) {
        result.Result::Err(_) => { return 2; }
        result.Result::Ok(b) => { buffer.drop(heap, b); return 0; }
    }
}
fn zz_get_some[&h](heap: &!h Heap, text: &static [byte], s: &static [byte], k: &static [byte], want: &static [byte]) -> [heap] int {
    match ini_get(heap, text, s, k) {
        result.Result::Err(_) => { return 2; }
        result.Result::Ok(o) => {
            match o {
                option.Option::None => { return 1; }
                option.Option::Some(b) => {
                    var st = 1;
                    borrow b as &r in { if bytes.equal(buffer.bytes(r), want) { st = 0; } }
                    buffer.drop(heap, b);
                    return st;
                }
            }
        }
    }
}
fn zz_get_none[&h](heap: &!h Heap, text: &static [byte], s: &static [byte], k: &static [byte]) -> [heap] int {
    match ini_get(heap, text, s, k) {
        result.Result::Err(_) => { return 2; }
        result.Result::Ok(o) => {
            match o {
                option.Option::None => { return 0; }
                option.Option::Some(b) => { buffer.drop(heap, b); return 1; }
            }
        }
    }
}
fn zz_get_err[&h](heap: &!h Heap, text: &static [byte], s: &static [byte], k: &static [byte]) -> [heap] int {
    match ini_get(heap, text, s, k) {
        result.Result::Err(_) => { return 0; }
        result.Result::Ok(o) => {
            match o {
                option.Option::None => { return 1; }
                option.Option::Some(b) => { buffer.drop(heap, b); return 1; }
            }
        }
    }
}
'''

def lit(s):
    m = {"\n": "\\n", "\r": "\\r", "\t": "\\t", "\\": "\\\\", '"': '\\"', "\0": "\\0"}
    return '"' + "".join(m.get(c, c) for c in s) + '"'

def test(name, call):
    return f"pub fn test_{name}[&h](heap: &!h Heap) -> [heap] int {{ test.assert_eq({call}, 0); return 0; }}\n"

def g_parse():
    out = []
    for i, c in enumerate(x for x in cases if x["fn"] == "ini_parse"):
        t = lit(c["args"][0])
        if c.get("expect_err"):
            out.append(test(f"p{i:02d}", f"zz_parse_err(heap, {t})"))
        else:
            want = "".join(e + "\n" for e in c["expect"]["args"][0])
            out.append(test(f"p{i:02d}", f"zz_parse_is(heap, {t}, {lit(want)})"))
    return out

def g_get():
    out = []
    for i, c in enumerate(x for x in cases if x["fn"] == "ini_get"):
        t, s, k = (lit(a) for a in c["args"])
        if c.get("expect_err"):
            out.append(test(f"g{i:02d}", f"zz_get_err(heap, {t}, {s}, {k})"))
        else:
            o = c["expect"]["args"][0]
            if o["$variant"] == "None":
                out.append(test(f"g{i:02d}", f"zz_get_none(heap, {t}, {s}, {k})"))
            else:
                out.append(test(f"g{i:02d}", f"zz_get_some(heap, {t}, {s}, {k}, {lit(o['args'][0])})"))
    return out

def g_errline():
    out = []
    for i, (t, n) in enumerate(ERRLINE):
        call = f"zz_parse_ok_only(heap, {lit(t)})" if n is None else f"zz_parse_errline(heap, {lit(t)}, {n})"
        out.append(test(f"l{i:02d}", call))
    return out

def g_extra():
    out = []
    for i, (t, s, k, v) in enumerate(EXTRA_GET):
        call = (f"zz_get_none(heap, {lit(t)}, {lit(s)}, {lit(k)})" if v is None
                else f"zz_get_some(heap, {lit(t)}, {lit(s)}, {lit(k)}, {lit(v)})")
        out.append(test(f"x{i:02d}", call))
    return out

def run(tests):
    f = tempfile.NamedTemporaryFile("w", suffix=".cho", delete=False, encoding="utf-8")
    f.write(head + body + "\n" + HELPERS + "".join(tests)); f.close()
    r = subprocess.run([C, "test", f.name, "--std"], capture_output=True, text=True)
    os.unlink(f.name)
    m = re.search(r"(\d+) passed; (\d+) failed", r.stdout)
    if m:
        return int(m.group(1)), len(tests), ""
    err = [l for l in (r.stderr + r.stdout).splitlines() if "error" in l]
    return 0, len(tests), "does not build: " + (re.sub(r"^.*?\.cho:", "line ", err[0])[:130] if err else "?")

total = n_all = 0
for name, gen in (("ini_parse", g_parse), ("ini_get", g_get), ("ini_errline", g_errline), ("ini_extra", g_extra)):
    t = gen()
    p, n, why = run(t)
    total += p; n_all += n
    print(f"  {name}: {p}/{n} {why}")
print(f"  TOTAL {total}/{n_all}")
sys.exit(0 if total == n_all else 1)
