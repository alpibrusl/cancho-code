#!/bin/sh
# The cases gate: src/cases.cho (a plan's `cases` turned into test code, from the unit's signature) held two ways.
#
#   differential  the cancho expander and tests/reference/cases_ref.py give the SAME new plan (as parsed JSON) and the same report lines
#                 and exit code on every plan in tests/fixtures/cases (every type combination, escapes, unicode, every error), and on a
#                 generated plan bigger than one region. tests/fixtures/cases/expected.txt pins the exit code and a piece of the report
#                 of each, so the two implementations cannot be wrong in the same way unseen.
#   semantic      the generated tests are the point. For the hand-written eval items (basics roman base64 duration semver glob expr
#                 tokenbucket ini jsonptr) the public units' tests are replaced by `cases` taken from the item's oracle (or its
#                 examples), expanded, assembled with the item's reference.cho and run by `cancho test`: all must PASS. Then one expected
#                 value per unit is flipped and the run must FAIL on exactly the flipped tests. A synthetic plan covers the shapes the
#                 items do not. The expanded plans pass the plan check (src/plan.cho).
#
# CASES_SRC=path runs the gate against another copy of cases.cho (the mutation runs use it).
set -u
export PYTHONDONTWRITEBYTECODE=1

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "no python3 on PATH" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
src="${CASES_SRC:-$root/src/cases.cho}"
d=$(mktemp -d -t cc-cases-XXXXXX)
"$CANCHO" build "$root/tests/programs/cases_gate.cho" "$src" --std -o "$d/gate" >/dev/null 2>"$d/build.err" \
    || { cat "$d/build.err" >&2; echo "gate did not build" >&2; exit 2; }
"$CANCHO" build "$root/tests/programs/plancheck.cho" "$root/src/plan.cho" --std -o "$d/plancheck" >/dev/null 2>"$d/build.err" \
    || { cat "$d/build.err" >&2; echo "plancheck did not build" >&2; exit 2; }

python3 - "$d" "$root" "$CANCHO" <<'PY' || { echo "cases gate: FAILED" >&2; exit 1; }
import json, os, re, subprocess, sys, tempfile
d, root, cancho = sys.argv[1], sys.argv[2], sys.argv[3]
gate = os.path.join(d, "gate")
plancheck = os.path.join(d, "plancheck")
sys.path.insert(0, os.path.join(root, "tests", "reference"))
import cases_ref

fails = 0
def fail(msg):
    global fails
    fails += 1
    print("FAIL: " + msg, file=sys.stderr)

def run_gate(path):
    p = subprocess.run([gate, path], capture_output=True)
    return p.returncode, p.stdout, p.stderr.decode("utf-8", "replace")

def run_ref(path):
    p = subprocess.run([sys.executable, "-I", os.path.join(root, "tests", "reference", "cases_ref.py"), path], capture_output=True)
    return p.returncode, p.stdout, p.stderr.decode("utf-8", "replace")

def lines(s):
    return [l for l in s.split("\n") if l != ""]

def same(a, b):
    """Parsed-JSON equality, strict about 1 vs 1.0 vs true."""
    return json.dumps(a, sort_keys=True) == json.dumps(b, sort_keys=True)

def compare(name, path, want_rc=None, want_sub=None):
    rc, out, err = run_gate(path)
    rrc, rout, rerr = run_ref(path)
    if rc != rrc:
        fail("%s: exit code cancho %d, reference %d" % (name, rc, rrc))
    if lines(err) != lines(rerr):
        fail("%s: report differs\n  cancho:    %s\n  reference: %s" % (name, lines(err), lines(rerr)))
    try:
        a, b = json.loads(out.decode("utf-8")), json.loads(rout.decode("utf-8"))
        if not same(a, b):
            fail("%s: new plan differs\n  cancho:    %s\n  reference: %s" % (name, out[:600], rout[:600]))
    except ValueError:
        if out != rout:
            fail("%s: output differs (not JSON)\n  cancho:    %r\n  reference: %r" % (name, out[:200], rout[:200]))
    for l in lines(err):
        f = l.split("\t")
        if len(f) != 4 or f[0] != "[CASES_ERROR]" or not f[3] or not (f[2] == "-" or f[2].isdigit()):
            fail("%s: malformed report line %r" % (name, l))
    if want_rc is not None and rc != want_rc:
        fail("%s: wanted exit %d, got %d" % (name, want_rc, rc))
    if want_sub is not None and want_sub not in err:
        fail("%s: the report lacks %r: %r" % (name, want_sub, err))
    return rc, out, err

# ---- differential -----------------------------------------------------------------
fx = os.path.join(root, "tests", "fixtures", "cases")
table = [l.rstrip("\n").split("\t", 2) for l in open(os.path.join(fx, "expected.txt")) if l.strip() and not l.startswith("#")]
ndiff = 0
only = os.environ.get("CASES_ONLY", "")       # "semantic" or "differential": run one half (the mutation runs show each half alone catches)
for name, rc, sub in ([] if only == "semantic" else table):
    path = os.path.join(fx, name + ".json")
    r, out, err = compare(name, path, int(rc), sub if sub else None)
    ndiff += 1
    if int(rc) == 0:
        # an input without a problem: no `cases` left in any unit, every unit with cases has tests and examples, every other unit is as it was
        old = json.load(open(path))
        new = json.loads(out.decode("utf-8"))
        for ou, nu in zip(old["units"], new["units"]):
            if isinstance(ou, dict) and "cases" in ou:
                if "cases" in nu or not nu.get("tests") or not nu.get("examples"):
                    fail("%s: expanded unit %r is incomplete: %s" % (name, ou.get("id"), nu))
            elif not same(ou, nu):
                fail("%s: a unit without cases was changed: %s -> %s" % (name, ou, nu))

# a plan bigger than one region: 300 units, and a few unfit ones in it
big = {"name": "big", "units": []}
sigs = ["fn f%d(a: int, b: int) -> [] int", "fn f%d[&r](s: &r [byte]) -> [] result.Result[int, &static [byte]]",
        "fn f%d[&h, &r](heap: &!h Heap, s: &r [byte]) -> [heap] buffer.Buffer"]
for i in range(300):
    k = i % 3
    cs = {0: [{"args": [i, 2], "expect": i + 2}, {"args": [-i, 1], "expect": 1 - i}],
          1: [{"args": ["x" * (i % 17)], "expect": {"ok": i % 17}}, {"args": ["é\n"], "expect": {"err": "no"}}],
          2: [{"args": ["abc%d" % i], "expect": "ABC%d" % i}]}[k]
    big["units"].append({"id": "u%d" % i, "signature": sigs[k] % i, "description": "d" * 200, "deps": [], "cases": cs})
big["units"][6]["cases"][0]["args"] = ["wrong", 1]
bp = os.path.join(d, "big.json")
json.dump(big, open(bp, "w"))
assert os.path.getsize(bp) > 70000
if only != "semantic":
    compare("big plan (%d bytes)" % os.path.getsize(bp), bp, 1, "u6\t1\targument 1")
    ndiff += 1
# usage
p = subprocess.run([gate], capture_output=True)
if p.returncode != 2:
    fail("usage: no argument should exit 2, got %d" % p.returncode)
p = subprocess.run([gate, os.path.join(d, "no-such-file.json")], capture_output=True)
if p.returncode != 2:
    fail("usage: a missing file should exit 2, got %d" % p.returncode)
print("differential: %d plans" % ndiff)

# ---- semantic ---------------------------------------------------------------------
if only == "differential":
    print("differential only")
    sys.exit(1 if fails else 0)
tmp = tempfile.mkdtemp(prefix="cc-cases-sem-")

def example_case(text):
    """`CALL == EXPECTED` from a hand-written plan's example as a case, or None."""
    m = re.match(r'^(\w+)\((.*)\) == (.*)$', text)
    if not m:
        return None
    fn, args, want = m.groups()
    try:
        a = json.loads("[" + args.replace("heap, ", "").replace("heap", "") + "]")
    except ValueError:
        return None
    want = want.strip()
    if want == "result.Result::Err":
        e = {"err": 0}
    elif want == "option.Option::None":
        e = None
    else:
        mm = re.match(r'^(result\.Result::Ok|option\.Option::Some)\((.*)\)$', want)
        try:
            if mm:
                v = json.loads(mm.group(2))
                e = {"ok": v} if mm.group(1).startswith("result") else v
            else:
                e = json.loads(want)
        except ValueError:
            return None
    return fn, {"args": a, "expect": e}

def oracle_cases(item):
    p = subprocess.run([sys.executable, "-I", os.path.join(root, "eval", item, "oracle.py")], capture_output=True)
    out = {}
    for l in p.stdout.decode("utf-8").splitlines():
        try:
            o = json.loads(l)
        except ValueError:
            continue
        if isinstance(o, dict) and "fn" in o:
            out.setdefault(o["fn"], []).append(o)
    return out

def conv_value(e):
    if isinstance(e, dict) and "$variant" in e:
        v = e["$variant"]
        if v == "Ok":
            return {"ok": conv_value(e["args"][0])}
        if v == "Some":
            return conv_value(e["args"][0])
        return None
    return e

def conv_expect(o):
    if "expect_err" in o:
        return {"err": True}
    return conv_value(o["expect"])

def expressible(v):
    if isinstance(v, str):
        return True          # any text: what a literal cannot hold is built from its bytes
    if isinstance(v, dict):
        return all(expressible(x) for x in v.values())
    if isinstance(v, list):
        return all(expressible(x) for x in v)
    if isinstance(v, (int, bool)) or v is None:
        return True
    return False

def pick_cases(fn_lines, n_ok=4, n_err=2, err_first=False):
    oks, errs = [], []
    for o in fn_lines:
        c = {"args": o["args"], "expect": conv_expect(o)}
        if not expressible(c["args"]) or not expressible(c["expect"]):
            continue
        (errs if isinstance(c["expect"], dict) and "err" in c["expect"] else oks).append(c)
    # a spread, not the first few: every k-th
    def spread(xs, n):
        if len(xs) <= n:
            return xs
        step = len(xs) / n
        return [xs[int(i * step)] for i in range(n)]
    ok, er = spread(oks, n_ok), spread(errs, n_err)
    return (er + ok) if err_first else (ok + er)

def hex_text(h):
    return bytes.fromhex(h).decode("ascii")

def base64_cases():
    p = subprocess.run([sys.executable, "-I", os.path.join(root, "eval", "base64", "oracle.py")], capture_output=True)
    enc, dec = [], []
    for l in p.stdout.decode("utf-8").splitlines():
        try:
            o = json.loads(l)
        except ValueError:
            continue
        try:
            if o.get("fn") == "base64_encode" and "expect_text" in o:
                enc.append({"args": [hex_text(o["data"])], "expect": o["expect_text"]})
            elif o.get("fn") == "base64_decode":
                if "expect_err" in o:
                    dec.append({"args": [bytes.fromhex(o["text"]).decode("ascii")], "expect": {"err": True}})
                elif "expect" in o:
                    dec.append({"args": [bytes.fromhex(o["text"]).decode("ascii")], "expect": {"ok": hex_text(o["expect"])}})
        except (ValueError, UnicodeDecodeError):
            continue
    dec = [c for c in dec if expressible(c["args"]) and expressible(c["expect"])]
    return enc, dec

def mutate(v):
    if isinstance(v, bool):
        return not v
    if isinstance(v, int):
        return v - 1 if v >= (1 << 63) - 1 else v + 1
    if isinstance(v, list):
        return v + ["x"]
    if isinstance(v, dict):
        return {"bytes": v["bytes"] + [120]}
    return v + "x"

def flip(case, hint):
    """The same case with its expected value made wrong."""
    e = case["expect"]
    if isinstance(e, dict) and "err" in e:
        x = e["err"]
        if isinstance(x, int) and not isinstance(x, bool):
            return {"args": case["args"], "expect": {"err": x + 1}}
        return {"args": case["args"], "expect": {"ok": {"int": 0, "bool": True, "text": "", "list": []}[hint]}}
    if isinstance(e, dict) and "ok" in e:
        v = e["ok"]
        return {"args": case["args"], "expect": {"ok": "x" if v is None else mutate(v)}}
    if e is None:
        return {"args": case["args"], "expect": {"int": 1, "bool": True, "text": "x"}[hint]}
    return {"args": case["args"], "expect": mutate(e)}

def flip_index(cs, hint):
    """Which case to flip: for a unit that answers a list, the first with a list (so the list comparison is what must notice)."""
    if hint == "list":
        for i, c in enumerate(cs):
            if isinstance(c["expect"], dict) and isinstance(c["expect"].get("ok"), list):
                return i
    return 0

def ret_of(sig):
    return re.sub(r"^\[[^\]]*\]\s*", "", sig.split("->")[1].strip())

def has_heap(sig):
    return "Heap" in sig.split("->")[0]

def sid(u):
    return re.sub(r"[^A-Za-z0-9_]", "_", u)

stat = {"byte-built": 0, "list/vec cases": 0}

def assemble(name, ref, plan_obj, expect_pass=None, expect_fail=None):
    """Expand `plan_obj`, assemble reference + generated tests, run them; returns the expanded plan."""
    pp = os.path.join(tmp, name + ".plan.json")
    json.dump(plan_obj, open(pp, "w"))
    rc, out, err = run_gate(pp)
    if rc != 0:
        fail("%s: expansion reported problems: %s" % (name, err))
        return None
    new = json.loads(out.decode("utf-8"))
    tests = []
    names = []
    for u in new["units"]:
        tests.extend(u["tests"])
        names.extend(re.findall(r"pub fn (test_\w+)", " ".join(u["tests"])))
    tf = os.path.join(tmp, name + ".tests.cho")
    open(tf, "w").write("edition 7;\nimport std.test;\n" + "\n".join(tests) + "\n")
    p = subprocess.run([cancho, "test", "--std", "--backend", "cranelift", ref, tf], capture_output=True, cwd=tmp)
    text = p.stdout.decode("utf-8", "replace") + p.stderr.decode("utf-8", "replace")
    status = dict(re.findall(r"^test (\w+) \.\.\. (\w+)", text, re.M))
    if len(set(names)) != len(names):
        fail("%s: test names are not unique" % name)
    if not status:
        fail("%s: the generated tests did not build:\n%s" % (name, "\n".join([l for l in text.splitlines() if "error" in l or l.startswith(" ")][:12])))
        return new
    if sorted(status) != sorted(names):
        fail("%s: ran %d tests, generated %d" % (name, len(status), len(names)))
    failed = sorted(n for n, s in status.items() if s != "ok")
    if expect_pass and failed:
        fail("%s: generated tests of CORRECT cases failed: %s" % (name, failed))
    if expect_fail is not None and failed != sorted(expect_fail):
        fail("%s: after flipping one value per unit the failing tests are %s, wanted exactly %s" % (name, failed, sorted(expect_fail)))
    new["_ntests"] = len(names)
    if name.endswith("-right"):
        joined = "\n".join(tests)
        stat["byte-built"] += len(re.findall(r"= cases_\w+_unhex\(heap, \"", joined)) + len(re.findall(r"box\(heap, cases_\w+_unhex", joined))
        stat["list/vec cases"] += len(re.findall(r"list\.push\(|vec\.push\(|: list\.List", joined)) and len(re.findall(r"^fn cases_\w+_c\d+", "\n".join(tests), re.M))
    return new

def plancheck_ok(name, new):
    pp = os.path.join(tmp, name + ".expanded.json")
    plain = {k: v for k, v in new.items() if k != "_ntests"}
    json.dump(plain, open(pp, "w"))
    p = subprocess.run([plancheck, pp], capture_output=True)
    if p.returncode != 0:
        fail("%s: the expanded plan fails the plan check:\n%s" % (name, p.stdout.decode()[:600]))

# item -> [(unit id, function, shape hint, options)]
ITEMS = {
    "basics": [("clamp", "int", {}), ("gcd", "int", {}), ("lcm", "int", {}), ("leap", "bool", {}), ("isqrt", "int", {}), ("pow_mod", "int", {})],
    "roman": [("to_roman", "text", {}), ("from_roman", "int", {"err_first": True})],
    "duration": [("parse", "int", {"err_first": True}), ("format", "text", {})],
    "semver": [("valid", "bool", {}), ("compare", "int", {}), ("satisfies", "bool", {"err_first": True})],
    "glob": [("match", "bool", {}), ("valid", "bool", {})],
    "expr": [("eval", "int", {})],
    "tokenbucket": [("refill", "int", {}), ("take", "int", {}), ("retry", "int", {})],
    # lists of text, a vec of text, any byte, integer error payloads, a Result of an Option
    "csv": [("parse", "list", {"err_first": True}), ("format", "text", {})],
    "jsonptr": [("parse", "list", {"err_first": True}), ("format", "text", {}), ("append", "text", {}), ("parent", "text", {})],
    "editdistance": [("edit_distance", "int", {}), ("similarity_pct", "int", {}), ("closest", "text", {})],
    "ini": [("parse", "text", {}), ("get", "text", {"err_first": True}), ("raw", "text", {}), ("dedupe", "text", {})],
}

def tests_cases(item, uid, plan_unit):
    """Cases written by hand in the plan's own tests (the oracle has no integer error payloads, nor raw/dedupe): the checks
    `pa_err(heap, TEXT, N)` (ini_parse fails at line N), `raw_err`, `raw_is`/`dd_is` (TEXT gives WANT)."""
    out = []
    jtext = r'("(?:[^"\\]|\\.)*")'
    for t in plan_unit.get("tests", []):
        for pat in (r"pa_err\(heap, " + jtext + r", (\d+)\)", r"raw_err\(heap, " + jtext + r", (\d+)\)"):
            for m in re.finditer(pat, t):
                try:
                    out.append({"args": [json.loads(m.group(1))], "expect": {"err": int(m.group(2))}})
                except ValueError:
                    pass
        for m in re.finditer(r"(?:raw_is|dd_is)\(heap, " + jtext + ", " + jtext + r"\)", t):
            try:
                out.append({"args": [json.loads(m.group(1))], "expect": json.loads(m.group(2)) if uid == "dedupe" else {"ok": json.loads(m.group(2))}})
            except ValueError:
                pass
    return out

def post_cases(item, uid, cs):
    """The oracle writes ini_parse's entries as a list; the unit answers the buffer of 'name=value\\n' lines."""
    if (item, uid) == ("ini", "parse"):
        return [dict(c, expect=({"ok": "".join(e + "\n" for e in c["expect"]["ok"])} if "ok" in c["expect"] else c["expect"])) for c in cs]
    return cs
shapes = set()
nsem = 0
for item, picks in ITEMS.items():
    plan = json.load(open(os.path.join(root, "eval", item, "plan.json")))
    byid = {u["id"]: u for u in plan["units"]}
    orc = oracle_cases(item)
    units, flips, expect_fail = [], {}, []
    for uid, hint, opts in picks:
        u = byid[uid]
        fn = re.match(r"fn (\w+)", u["signature"]).group(1)
        cs = post_cases(item, uid, pick_cases(orc.get(fn, []), **opts))
        if item == "ini":
            extra = tests_cases(item, uid, u)
            cs = extra[:3] + cs if uid == "parse" else cs + extra[:3]
        if len(cs) < 2:
            fail("%s: %s: fewer than 2 usable oracle cases" % (item, uid))
            continue
        units.append({"id": uid, "signature": u["signature"], "description": u.get("description", ""), "deps": [], "cases": cs})
        flips[uid] = hint
        shapes.add((ret_of(u["signature"]), has_heap(u["signature"])))
    right = {"name": item, "units": units}
    ref = os.path.join(root, "eval", item, "reference.cho")
    good = assemble(item + "-right", ref, right, expect_pass=True)
    if good is None:
        continue
    plancheck_ok(item, good)
    wrong_units = []
    for u in units:
        cs = list(u["cases"])
        fi = flip_index(cs, flips[u["id"]])
        cs[fi] = flip(cs[fi], flips[u["id"]])
        wrong_units.append(dict(u, cases=cs))
        expect_fail.append("test_%s_%d" % (sid(u["id"]), fi + 1))
    assemble(item + "-flipped", ref, {"name": item, "units": wrong_units}, expect_fail=expect_fail)
    nsem += len(units)
    print("semantic %-12s %2d units, %3d tests pass; flipping one value per unit fails exactly %d" % (item, len(units), good["_ntests"], len(expect_fail)))

# ini and jsonptr: no oracle with these functions, so the cases are the hand-written examples of the plan
for item, uids in (("ini", ["key", "section", "kind", "unquote"]),):
    plan = json.load(open(os.path.join(root, "eval", item, "plan.json")))
    byid = {u["id"]: u for u in plan["units"]}
    units, flips, expect_fail = [], {}, []
    for uid in uids:
        u = byid[uid]
        cs = [c for c in (example_case(e) for e in u["examples"]) if c]
        cs = [c[1] for c in cs]
        if len(cs) < 2:
            fail("%s: %s: fewer than 2 usable examples" % (item, uid))
            continue
        units.append({"id": uid, "signature": u["signature"], "deps": [], "cases": cs})
        flips[uid] = "text" if "[byte]" in ret_of(u["signature"]) else ("bool" if "bool" in ret_of(u["signature"]) else "int")
        shapes.add((ret_of(u["signature"]), has_heap(u["signature"])))
    ref = os.path.join(root, "eval", item, "reference.cho")
    good = assemble(item + "-right", ref, {"name": item, "units": units}, expect_pass=True)
    if good is None:
        continue
    plancheck_ok(item, good)
    wrong = []
    for u in units:
        cs = list(u["cases"])
        cs[0] = flip(cs[0], flips[u["id"]])
        wrong.append(dict(u, cases=cs))
        expect_fail.append("test_%s_1" % sid(u["id"]))
    assemble(item + "-flipped", ref, {"name": item, "units": wrong}, expect_fail=expect_fail)
    nsem += len(units)
    print("semantic %-12s %2d units, %3d tests pass; flipping one value per unit fails exactly %d" % (item + " (ex.)", len(units), good["_ntests"], len(expect_fail)))

# base64: the oracle gives bytes in hex; the printable ones become text cases
enc, dec = base64_cases()
plan = json.load(open(os.path.join(root, "eval", "base64", "plan.json")))
byid = {u["id"]: u for u in plan["units"]}
def spread(xs, n):
    if len(xs) <= n:
        return xs
    return [xs[int(i * len(xs) / n)] for i in range(n)]
errs = [c for c in dec if "err" in c["expect"]]
oks = [c for c in dec if "ok" in c["expect"]]
units = [
    {"id": "encode", "signature": byid["encode"]["signature"], "deps": [], "cases": spread(enc, 5)},
    {"id": "decode", "signature": byid["decode"]["signature"], "deps": [], "cases": spread(errs, 2) + spread(oks, 4)},
]
for u in units:
    if len(u["cases"]) < 2:
        fail("base64: %s: fewer than 2 usable oracle cases" % u["id"])
    shapes.add((ret_of(byid[u["id"]]["signature"]), True))
ref = os.path.join(root, "eval", "base64", "reference.cho")
good = assemble("base64-right", ref, {"name": "base64", "units": units}, expect_pass=True)
if good is not None:
    plancheck_ok("base64", good)
    wrong = [dict(units[0], cases=[flip(units[0]["cases"][0], "text")] + units[0]["cases"][1:]),
             dict(units[1], cases=[flip(units[1]["cases"][0], "text")] + units[1]["cases"][1:])]
    assemble("base64-flipped", ref, {"name": "base64", "units": wrong}, expect_fail=["test_encode_1", "test_decode_1"])
    nsem += 2
    print("semantic %-12s %2d units, %3d tests pass; flipping one value per unit fails exactly 2" % ("base64", 2, good["_ntests"]))

# the shapes the items do not have
syn = json.load(open(os.path.join(fx, "synthetic.json")))
ref = os.path.join(fx, "synthetic_ref.cho")
good = assemble("synthetic-right", ref, syn, expect_pass=True)
if good is not None:
    plancheck_ok("synthetic", good)
    hints = {"optb": "bool", "resb": "bool", "bufe": "text", "mid": "text", "two": "int", "noargs": "int", "neg": "int", "uni": "text", "heapint": "int", "rint": "int", "obuf": "text", "rbox": "text", "first": "int", "echo": "text", "ropt": "text"}
    wrong = [dict(u, cases=[flip(u["cases"][0], hints[u["id"]])] + u["cases"][1:]) for u in syn["units"]]
    assemble("synthetic-flipped", ref, {"name": "synthetic", "units": wrong}, expect_fail=["test_%s_1" % u["id"] for u in syn["units"]])
    nsem += len(syn["units"])
    for u in syn["units"]:
        shapes.add((ret_of(u["signature"]), has_heap(u["signature"])))
    print("semantic %-12s %2d units, %3d tests pass; flipping one value per unit fails exactly %d" % ("synthetic", len(syn["units"]), good["_ntests"], len(syn["units"])))

kinds = set()
for ret, heap in shapes:
    k = ("buffer" if ret == "buffer.Buffer" else "text" if ret.startswith("&") else "option" if ret.startswith("option") else
         "result" if ret.startswith("result") else ret)
    if k == "result":
        k += ":" + ("buffer" if "Result[buffer" in ret else "bool" if "Result[bool" in ret else "text" if "Result[&" in ret else "int")
    kinds.add(k)
print("semantic: %d units, return shapes: %s; %d heap and %d heap-less shape variants" % (nsem, sorted(kinds), sum(1 for r, h in shapes if h), sum(1 for r, h in shapes if not h)))
print("semantic: %d text values built from their bytes (not literals), %d cases built with locals (lists, vecs, bytes)" % (stat["byte-built"], stat["list/vec cases"]))
if len(kinds) < 6:
    fail("fewer than 6 return shapes covered: %s" % sorted(kinds))
if not any(h for r, h in shapes) or not any(not h for r, h in shapes):
    fail("the semantic part needs units with and without a heap")

sys.exit(1 if fails else 0)
PY
rc=$?
rm -rf "$d"
[ "$rc" = 0 ] && echo "cases gate: ok" || { echo "cases gate: FAILED" >&2; exit 1; }
