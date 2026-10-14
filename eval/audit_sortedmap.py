#!/usr/bin/env python3
"""Independent audit of a built `sortedmap` (int->int map in two parallel sorted arrays) against eval/sortedmap/oracle.py.

    CANCHO=<compiler> python3 eval/audit_sortedmap.py <project.cho>

Shapes (pinned by the plan):
    sm_lower_bound[&k](keys: &k [int], n: int, key: int) -> [] int
    sm_get[&k, &v](keys: &k [int], vals: &v [int], n: int, key: int) -> [] option.Option[int]
    sm_count_in_range[&k](keys: &k [int], n: int, lo: int, hi: int) -> [] int
    sm_insert[&k, &v](keys: &!k [int], vals: &!v [int], n: int, key: int, value: int) -> [] int
    sm_remove[&k, &v](keys: &!k [int], vals: &!v [int], n: int, key: int) -> [] int
One test per (oracle sequence, function): inside it every op of that kind is replayed on arrays RESET to the oracle's
pre-state (slots at index >= n hold -999), so a wrong function costs its own group only. insert/remove also check the
returned count and keys/vals[0..n) afterwards (a failed insert must leave them untouched). Each group is its own file:
a build error or a trap costs only the groups that need it. Exit 0 only if every case holds. ORACLE= overrides the oracle."""
import json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
C = os.environ.get("CANCHO", "cancho")
ORACLE = os.environ.get("ORACLE", os.path.join(HERE, "sortedmap", "oracle.py"))
src = open(sys.argv[1], encoding="utf-8").read()
seqs = [json.loads(l) for l in subprocess.run([sys.executable, ORACLE], capture_output=True, text=True, check=True).stdout.splitlines() if l.strip()]

body = re.sub(r"fn main\(world: World\).*?\n\}\n", "", src, flags=re.S)
body = re.sub(r"^edition \d+;\s*$", "", body, flags=re.M)
body = re.sub(r"^import std\.(result|buffer|bytes|test|option);\s*$", "", body, flags=re.M)
body = re.sub(r"^fn ", "pub fn ", body, flags=re.M)
body = re.sub(r"^(struct|enum) ", r"pub \1 ", body, flags=re.M)
head = "edition 7;\nimport std.option;\nimport std.test;\n"

HELPERS = '''
fn h_tail[&k, &v](keys: &!k [int], vals: &!v [int], n: int) -> [] int {
    var i = n;
    while i < len(keys) { keys[i] = -999; vals[i] = -999; i = i + 1; }
    return 0;
}
fn h_get_is[&k, &v](keys: &k [int], vals: &v [int], n: int, key: int, want: int) -> [] int {
    match sm_get(keys, vals, n, key) {
        option.Option::Some(x) => { if x == want { return 0; } return 1; }
        option.Option::None => { return 1; }
    }
}
fn h_get_none[&k, &v](keys: &k [int], vals: &v [int], n: int, key: int) -> [] int {
    match sm_get(keys, vals, n, key) {
        option.Option::Some(x) => { return 1; }
        option.Option::None => { return 0; }
    }
}
'''
def lit(x): return str(x)

def load(op, cap):
    s = ""
    for i, (k, v) in enumerate(zip(op["keys"], op["vals"])):
        s += f"        keys[{i}] = {lit(k)}; vals[{i}] = {lit(v)};\n"
    return s + f"        h_tail(keys, vals, {len(op['keys'])});\n"

def post(op):
    s = ""
    for i, (k, v) in enumerate(zip(op["keys_after"], op["vals_after"])):
        s += f"        if keys[{i}] != {lit(k)} || vals[{i}] != {lit(v)} {{ bad = bad + 1; }}\n"
    return s

def one(op, cap):
    n = len(op["keys"]); s = "        {\n" + load(op, cap) if False else load(op, cap)
    k = op["op"]
    if k == "insert":
        s += f"        if sm_insert(keys, vals, {n}, {lit(op['key'])}, {lit(op['value'])}) != {lit(op['ret'])} {{ bad = bad + 1; }}\n" + post(op)
    elif k == "remove":
        s += f"        if sm_remove(keys, vals, {n}, {lit(op['key'])}) != {lit(op['ret'])} {{ bad = bad + 1; }}\n" + post(op)
    elif k == "get":
        s += (f"        bad = bad + h_get_is(keys, vals, {n}, {lit(op['key'])}, {lit(op['value'])});\n" if op["found"]
              else f"        bad = bad + h_get_none(keys, vals, {n}, {lit(op['key'])});\n")
    elif k == "lower_bound":
        s += f"        if sm_lower_bound(keys, {n}, {lit(op['key'])}) != {lit(op['ret'])} {{ bad = bad + 1; }}\n"
    else:
        s += f"        if sm_count_in_range(keys, {n}, {lit(op['lo'])}, {lit(op['hi'])}) != {lit(op['ret'])} {{ bad = bad + 1; }}\n"
    return s

def tests_for(kind):
    out = []
    for q in seqs:
        ops = [o for o in q["ops"] if o["op"] == kind]
        if not ops: continue
        t = f"pub fn test_{kind}_{q['seq']:02d}() -> [] int {{\n    var bad = 0;\n    region r {{\n"
        t += f"        let keys = alloc_slice[r]({q['cap']}, 0);\n        let vals = alloc_slice[r]({q['cap']}, 0);\n"
        for o in ops: t += one(o, q["cap"])
        t += "    }\n    test.assert_eq(bad, 0);\n    return 0;\n}\n"
        out.append(t)
    return out

GROUPS = [("sm_insert", "insert"), ("sm_remove", "remove"), ("sm_get", "get"), ("sm_lower_bound", "lower_bound"), ("sm_count_in_range", "count")]

def run(kind):
    tests = tests_for(kind); n = len(tests)
    f = tempfile.NamedTemporaryFile("w", suffix=".cho", delete=False, encoding="utf-8")
    f.write(head + body + HELPERS + "\n".join(tests)); f.close()
    r = subprocess.run([C, "test", f.name, "--std", "--backend", "cranelift"], capture_output=True, text=True)
    os.unlink(f.name)
    m = re.search(r"(\d+) passed; (\d+) failed", r.stdout)
    if m: return int(m.group(1)), n, ""
    err = [l for l in (r.stderr + r.stdout).splitlines() if "error" in l]
    if err: return 0, n, "does not build: " + re.sub(r"^.*?\.cho:", "line ", err[0])[:120]
    return 0, n, "crashed (trap?) before reporting"

total = cases = 0
for name, kind in GROUPS:
    p, n, why = run(kind)
    total += p; cases += n
    print(f"  {name}: {p}/{n} {why}")
print(f"  TOTAL {total}/{cases}")
sys.exit(0 if total == cases else 1)
