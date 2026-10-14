#!/usr/bin/env python3
"""Independent audit of a built `base64` (RFC 4648 standard alphabet, padded, strict decode), by function group.

    CANCHO=<compiler> python3 eval/audit_base64.py <project.cho>

The shapes are the ones the plan pins:
    base64_encode[&h, &r](heap: &!h Heap, data: &r [byte]) -> [heap] buffer.Buffer
    base64_decode[&h, &r](heap: &!h Heap, text: &r [byte]) -> [heap] result.Result[buffer.Buffer, &static [byte]]
Groups: base64_encode (bytes in, expected text), base64_decode (Ok(bytes) for canonical text, Err for everything else: length, characters,
padding, non-zero trailing bits), roundtrip (decode(encode(x)) is Ok(x), which needs both functions to build). A file that does not build in
those shapes scores 0 for the groups that need them, with the compiler's first error. Exit 0 only if every case holds.
The oracle (eval/base64/oracle.py) was written before any run; ORACLE= overrides it. The model under test never sees this file."""
import json, os, re, subprocess, sys, tempfile, collections

HERE = os.path.dirname(os.path.abspath(__file__))
C = os.environ.get("CANCHO", "cancho")
ORACLE = os.environ.get("ORACLE", os.path.join(HERE, "base64", "oracle.py"))
src = open(sys.argv[1], encoding="utf-8").read()
cases = [json.loads(l) for l in subprocess.run([sys.executable, ORACLE], capture_output=True, text=True, check=True).stdout.splitlines() if l.strip()]

body = re.sub(r"fn main\(world: World\).*?\n\}\n", "", src, flags=re.S)
body = re.sub(r"^edition \d+;\s*$", "", body, flags=re.M)
body = re.sub(r"^import std\.(result|buffer|bytes|test);\s*$", "", body, flags=re.M)   # the harness imports these itself
body = re.sub(r"^fn ", "pub fn ", body, flags=re.M)
body = re.sub(r"^(struct|enum) ", r"pub \1 ", body, flags=re.M)
head = "edition 7;\nimport std.result;\nimport std.buffer;\nimport std.bytes;\nimport std.test;\n"

# A group is its own file with its own helpers: a function of the wrong shape costs its own group only.
ENC_HELPERS = '''
fn enc_is[&h, &r, &w](heap: &!h Heap, data: &r [byte], want: &w [byte]) -> [heap] int {
    let b = base64_encode(heap, data);
    var same = false;
    borrow b as &x in { same = bytes.equal(buffer.bytes(x), want); }
    buffer.drop(heap, b);
    if same { return 0; }
    return 1;
}
'''
DEC_HELPERS = '''
fn dec_is[&h, &r, &w](heap: &!h Heap, text: &r [byte], want: &w [byte]) -> [heap] int {
    match base64_decode(heap, text) {
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
fn dec_err[&h, &r](heap: &!h Heap, text: &r [byte]) -> [heap] int {
    match base64_decode(heap, text) {
        result.Result::Ok(b) => { buffer.drop(heap, b); return 1; }
        result.Result::Err(_) => { return 0; }
    }
}
'''
RT_HELPERS = '''
fn rt_is[&h, &r](heap: &!h Heap, data: &r [byte]) -> [heap] int {
    let e = base64_encode(heap, data);
    var status = 3;
    borrow e as &x in {
        match base64_decode(heap, buffer.bytes(x)) {
            result.Result::Ok(b) => {
                var same = false;
                borrow b as &y in { same = bytes.equal(buffer.bytes(y), data); }
                buffer.drop(heap, b);
                status = 1;
                if same { status = 0; }
            }
            result.Result::Err(_) => { status = 2; }
        }
    }
    buffer.drop(heap, e);
    return status;
}
'''

def fill(var, hexstr):
    bs = bytes.fromhex(hexstr)
    lines = [f"let {var} = alloc_slice[r]({len(bs)}, byte_of(0));"]
    for k in range(0, len(bs), 16):
        lines.append(" ".join(f"{var}[{k + j}] = byte_of({b});" for j, b in enumerate(bs[k:k + 16])))
    return "\n        ".join(lines)

def test_fn(name, call_lines, post):
    return f"pub fn {name}[&h](heap: &!h Heap) -> [heap] int {{\n    region r {{\n        {call_lines}\n        test.assert_eq({post}, 0);\n    }}\n    return 0;\n}}\n"

def tests_for(group):
    out = []
    for i, c in enumerate([c for c in cases if c["fn"] == group]):
        if group == "base64_encode":
            want = c["expect_text"].encode().hex()
            out.append(test_fn(f"test_e{i:03d}", fill("d", c["data"]) + "\n        " + fill("w", want), "enc_is(heap, d, w)"))
        elif group == "base64_decode":
            if c.get("expect_err"):
                out.append(test_fn(f"test_d{i:03d}", fill("t", c["text"]), "dec_err(heap, t)"))
            else:
                out.append(test_fn(f"test_d{i:03d}", fill("t", c["text"]) + "\n        " + fill("w", c["expect"]), "dec_is(heap, t, w)"))
        else:
            out.append(test_fn(f"test_r{i:03d}", fill("d", c["data"]), "rt_is(heap, d)"))
    return "\n".join(out)

HELPERS = {"base64_encode": ENC_HELPERS, "base64_decode": DEC_HELPERS, "roundtrip": RT_HELPERS}

def run(group):
    n = len([c for c in cases if c["fn"] == group])
    f = tempfile.NamedTemporaryFile("w", suffix=".cho", delete=False, encoding="utf-8")
    f.write(head + body + "\n" + HELPERS[group] + tests_for(group)); f.close()
    r = subprocess.run([C, "test", f.name, "--std"], capture_output=True, text=True)
    os.unlink(f.name)
    m = re.search(r"(\d+) passed; (\d+) failed", r.stdout)
    if m:
        return int(m.group(1)), n, ""
    err = [l for l in (r.stderr + r.stdout).splitlines() if "error" in l]
    return 0, n, "does not build: " + (re.sub(r"^.*?\.cho:", "line ", err[0])[:120] if err else "?")

total = 0
for g in ("base64_encode", "base64_decode", "roundtrip"):
    p, n, why = run(g)
    total += p
    print(f"  {g}: {p}/{n} {why}")
dec = collections.Counter(c["why"] for c in cases if c.get("expect_err"))
print("  (decode Err cases by first rule broken: " + ", ".join(f"{k} {v}" for k, v in sorted(dec.items())) + ")")
print(f"  TOTAL {total}/{len(cases)}")
sys.exit(0 if total == len(cases) else 1)
