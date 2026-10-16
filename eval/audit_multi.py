#!/usr/bin/env python3
"""Independent audit of a built `multi` item (a small calculator in three modules, eval/multi/brief.txt) against eval/multi/oracle.py.

    CANCHO=<compiler> python3 eval/audit_multi.py <dir>/project.cho

The built project is the directory next to the given project.cho: the three module files tokens.cho, parser.cho and calc.cho (project.cho itself is not part
of the audit: nothing in the item asks for code in it). Every case calls ONLY the public functions of the modules, from a test file of its own that imports
them, so what is judged is what another module could see:
    tokens.tk_scan, tokens.tk_kind, tokens.tk_value
    parser.ps_fits_add, parser.ps_fits_sub, parser.ps_fits_mul, parser.ps_eval
    calc.calc_eval, calc.calc_record, calc.calc_total, calc.calc_count
One group per function (or pair); a group is compiled with the modules it needs (tokens; tokens and parser; all three) and its tests are the oracle's cases in
chunks, so a build error or a trap costs the groups that need that module and nothing else. Exit 0 only if every case holds. ORACLE= overrides the oracle."""
import json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
C = os.environ.get("CANCHO", "cancho")
ORACLE = os.environ.get("ORACLE", os.path.join(HERE, "multi", "oracle.py"))
proj = os.path.abspath(sys.argv[1])
wd = os.path.dirname(proj)
cases = [json.loads(l) for l in subprocess.run([sys.executable, ORACLE], capture_output=True, text=True, check=True).stdout.splitlines() if l.strip()]
INT_MIN_LIT = "(0 - 9223372036854775807 - 1)"


def n(v):
    """An integer literal; the smallest int has no literal of its own."""
    if v == -2**63:
        return INT_MIN_LIT
    return str(v) if v >= 0 else "(0 - %d)" % -v


def s(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"').replace("\t", "\\t") + '"'


def fill(name, pairs, extra=1):
    out = ""
    for i, (k, v) in enumerate(pairs):
        out += "            %s[%d] = %d; %s[%d] = %s;\n" % (name, 2 * i, k, name, 2 * i + 1, n(v))
    return out


def chunked(fn, group, items, size):
    """The tests of one group: `size` cases per test function, each case in a region of its own, a counter of the cases that did not hold."""
    tests = []
    for k in range(0, len(items), size):
        body = "".join("        region r {\n%s        }\n" % fn(it) for it in items[k:k + size])
        tests.append("pub fn test_%s_%02d() -> [] int {\n    var bad = 0;\n%s    test.assert_eq(bad, 0);\n    return 0;\n}\n" % (group, k // size, body))
    return tests


def g_scan(c):
    cap = c["cap"]
    code = c["code"]
    t = "            let toks = alloc_slice[r](%d, 0 - 7);\n" % (2 * cap)
    t += "            if tokens.tk_scan(%s, toks) != %s { bad = bad + 1; }" % (s(c["text"]), n(code))
    if code >= 0:
        t += " else {\n"
        for i, (k, v) in enumerate(c["toks"]):
            t += "                if toks[%d] != %d || toks[%d] != %s { bad = bad + 1; }\n" % (2 * i, k, 2 * i + 1, n(v))
        t += "            }"
    return t + "\n"


def g_access(c):
    pairs = c["pairs"]
    t = "            let toks = alloc_slice[r](%d, 0);\n%s" % (2 * len(pairs), fill("toks", pairs))
    for i, (k, v) in enumerate(pairs):
        t += "            if tokens.tk_kind(toks, %d) != %d || tokens.tk_value(toks, %d) != %s { bad = bad + 1; }\n" % (i, k, i, n(v))
    return t


def g_fits(c):
    return "            if parser.ps_fits_%s(%s, %s) != %s { bad = bad + 1; }\n" % (c["op"], n(c["a"]), n(c["b"]), "true" if c["ok"] else "false")


def g_eval(c):
    toks = c["toks"]
    t = "            let toks = alloc_slice[r](%d, 0);\n            let out = alloc_slice[r](1, 0 - 123456);\n%s" % (2 * len(toks) + 2, fill("toks", toks))
    t += "            if parser.ps_eval(toks, %d, out) != %d { bad = bad + 1; }" % (len(toks), c["code"])
    if c["code"] == 0:
        t += " else { if out[0] != %s { bad = bad + 1; } }" % n(c["value"])
    return t + "\n"


def g_calc(c):
    t = "            let toks = alloc_slice[r](%d, 0 - 7);\n            let out = alloc_slice[r](1, 0 - 123456);\n" % (2 * c["cap"])
    t += "            if calc.calc_eval(%s, toks, out) != %d { bad = bad + 1; }" % (s(c["text"]), c["code"])
    if c["code"] == 0:
        t += " else { if out[0] != %s { bad = bad + 1; } }" % n(c["value"])
    return t + "\n"


def g_record(c):
    t = "            let toks = alloc_slice[r](80, 0 - 7);\n            let out = alloc_slice[r](1, 0);\n            let store = alloc_slice[r](2, 0);\n"
    for st in c["steps"]:
        t += "            if calc.calc_record(%s, toks, out, store) != %d || calc.calc_total(store) != %s || calc.calc_count(store) != %d { bad = bad + 1; }\n" % (
            s(st["text"]), st["code"], n(st["total"]), st["count"])
    return t


def g_getters(c):
    return "            let store = alloc_slice[r](2, 0);\n            store[0] = %s; store[1] = %d;\n            if calc.calc_total(store) != %s || calc.calc_count(store) != %d { bad = bad + 1; }\n" % (
        n(c["total"]), c["count"], n(c["total"]), c["count"])


GROUPS = [
    ("tk_scan", "scan", ["tokens"], g_scan, 6),
    ("tk_kind/tk_value", "access", ["tokens"], g_access, 4),
    ("ps_fits_*", "fits", ["tokens", "parser"], g_fits, 18),
    ("ps_eval", "eval", ["tokens", "parser"], g_eval, 12),
    ("calc_eval", "calc", ["tokens", "parser", "calc"], g_calc, 12),
    ("calc_record", "record", ["tokens", "parser", "calc"], g_record, 1),
    ("calc_total/count", "getters", ["tokens", "parser", "calc"], g_getters, 2),
]


def run(name, group, mods, fn, size):
    items = [c for c in cases if c["g"] == group]
    tests = chunked(fn, group, items, size)
    count = len(tests)
    files = []
    for m in mods:
        p = os.path.join(wd, m + ".cho")
        if not os.path.exists(p):
            return 0, count, "%s.cho is missing" % m
        files.append(p)
    head = "edition 7;\nimport std.test;\n" + "".join("import %s;\n" % m for m in mods)
    f = tempfile.NamedTemporaryFile("w", suffix=".cho", delete=False, encoding="utf-8")
    f.write(head + "\n".join(tests))
    f.close()
    r = subprocess.run([C, "test"] + files + [f.name, "--std", "--backend", "cranelift"], capture_output=True, text=True)
    os.unlink(f.name)
    m = re.search(r"(\d+) passed; (\d+) failed", r.stdout)
    if m:
        return int(m.group(1)), count, ""
    err = [l for l in (r.stderr + r.stdout).splitlines() if "error" in l]
    if err:
        return 0, count, "does not build: " + re.sub(r"^.*?\.cho:", "line ", err[0])[:140]
    return 0, count, "crashed (trap?) before reporting"


total = of = 0
for name, group, mods, fn, size in GROUPS:
    p, k, why = run(name, group, mods, fn, size)
    total += p
    of += k
    print("  %s: %d/%d %s" % (name, p, k, why))
print("  TOTAL %d/%d" % (total, of))
sys.exit(0 if total == of else 1)
