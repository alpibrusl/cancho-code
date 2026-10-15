#!/bin/sh
# The review gate: src/review.cho (the blind second pass over a plan's `cases`, docs/plan.md "review") held three ways.
#
#   differential  the cancho module and tests/reference/review_ref.py agree, byte for byte, on `blind` (every plan of
#                 tests/fixtures/review and tests/fixtures/cases) and on `apply` (every plan/answers pair of tests/fixtures/review: the new
#                 plan, the report lines, the exit code), and tests/fixtures/review/expected.txt pins the exit code and a piece of the report.
#   semantic      for the plans of tests/fixtures/cases that expand cleanly, an honest oracle answers every case with the planner's own
#                 value (an error payload as `true`, an ASCII text as {"bytes":...}), a few answers are perturbed and a few skipped; the
#                 surviving plan must be exactly the plan without those cases, must still expand (src/cases.cho), and the expansion must
#                 pass the plan check as the original did.
#   blind         no expected value of the planner reaches the questions: no `expect`/`examples`/`tests`/`deps` key, and no text of more
#                 than 3 characters that is in a case's `expect` or in the unit's examples and is not also in its args, signature or
#                 description.
#
# REVIEW_SRC=path runs the gate against another copy of review.cho (the mutation runs use it); REVIEW_ONLY=differential|semantic.
set -u
export PYTHONDONTWRITEBYTECODE=1

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "no python3 on PATH" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
src="${REVIEW_SRC:-$root/src/review.cho}"
d=$(mktemp -d -t cc-review-XXXXXX)
build() { "$CANCHO" build "$@" --std --backend cranelift >/dev/null 2>"$d/build.err" || { cat "$d/build.err" >&2; echo "gate did not build" >&2; exit 2; }; }
build "$root/tests/programs/review_gate.cho" "$src" -o "$d/gate"
build "$root/tests/programs/cases_gate.cho" "$root/src/cases.cho" -o "$d/cases"
build "$root/tests/programs/plancheck.cho" "$root/src/plan.cho" -o "$d/plancheck"

python3 - "$d" "$root" <<'PY' || { echo "review gate: FAILED" >&2; exit 1; }
import copy, glob, json, os, subprocess, sys
d, root = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(root, "tests", "reference"))
import review_ref as ref

only = os.environ.get("REVIEW_ONLY", "")
fails = 0
def fail(msg):
    global fails
    fails += 1
    print("FAIL: " + msg, file=sys.stderr)

def run(args):
    p = subprocess.run(args, capture_output=True)
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")

def blind_pair(path):
    rc, out, err = run([os.path.join(d, "gate"), "blind", path])
    want = ref.blind(open(path, "rb").read().decode("utf-8"))
    if rc != 0 or out != want:
        fail("blind %s: rc %d\n  cancho:    %s\n  reference: %s" % (os.path.basename(path), rc, out[:300], want[:300]))
    return out

def apply_pair(name, pp, ap):
    rc, out, err = run([os.path.join(d, "gate"), "apply", pp, ap])
    new, report, code = ref.apply(open(pp, "rb").read().decode("utf-8"), open(ap, "rb").read().decode("utf-8"))
    if rc != code:
        fail("%s: exit code cancho %d, reference %d" % (name, rc, code))
    if [l for l in err.split("\n") if l] != report:
        fail("%s: report differs\n  cancho:    %s\n  reference: %s" % (name, err.split("\n"), report))
    if out != new:
        fail("%s: new plan differs\n  cancho:    %s\n  reference: %s" % (name, out[:300], new[:300]))
    for l in report:
        f = l.split("\t")
        if not (l.startswith("[REVIEW]\t") or (len(f) == 4 and f[0] in ("[REVIEW_DROPPED]", "[REVIEW_ERROR]") and f[3])):
            fail("%s: malformed report line %r" % (name, l))
    return rc, out, err

fx = os.path.join(root, "tests", "fixtures", "review")
nblind = napply = 0
if only != "semantic":
    table = [l.rstrip("\n").split("\t", 2) for l in open(os.path.join(fx, "expected.txt")) if l.strip() and not l.startswith("#")]
    for name, rc, sub in table:
        pp, ap = os.path.join(fx, name + ".plan.json"), os.path.join(fx, name + ".answers.json")
        r, out, err = apply_pair(name, pp, ap)
        napply += 1
        if r != int(rc):
            fail("%s: wanted exit %s, got %d" % (name, rc, r))
        if sub and sub not in err:
            fail("%s: the report lacks %r: %r" % (name, sub, err))
        blind_pair(pp)
        nblind += 1
    for p in sorted(glob.glob(os.path.join(root, "tests", "fixtures", "cases", "*.json"))):
        blind_pair(p)
        nblind += 1
    # a plan with no cases at all, and not a plan
    for text in ('{"name":"x","units":[{"id":"a","signature":"fn a() -> [] int","examples":["a() == 1"],"deps":[]}]}', "[1]", "nope"):
        p = os.path.join(d, "x.json")
        open(p, "w").write(text)
        if blind_pair(p) != '{"units":[]}':
            fail("blind of %r should be {\"units\":[]}" % text)
        nblind += 1
    p = subprocess.run([os.path.join(d, "gate"), "blind"], capture_output=True)
    if p.returncode != 2:
        fail("usage: blind with no file should exit 2, got %d" % p.returncode)
    p = subprocess.run([os.path.join(d, "gate"), "apply", os.path.join(d, "none.json"), os.path.join(d, "none.json")], capture_output=True)
    if p.returncode != 2:
        fail("usage: a missing file should exit 2, got %d" % p.returncode)
print("differential: %d blind, %d apply" % (nblind, napply))
if only == "differential":
    sys.exit(1 if fails else 0)

# ---- blind: the planner's values do not reach the questions -----------------------------
def strings(v, out):
    if isinstance(v, str):
        out.append(v)
    elif isinstance(v, list):
        for x in v:
            strings(x, out)
    elif isinstance(v, dict):
        if len(v) == 1 and "bytes" in v and isinstance(v["bytes"], list) and all(isinstance(x, int) and 0 <= x < 256 for x in v["bytes"]):
            try:
                out.append(bytes(v["bytes"]).decode("utf-8"))
            except UnicodeDecodeError:
                pass
        if not (len(v) == 1 and "bytes" in v):
            for k, x in v.items():
                out.append(k)
                strings(x, out)

def keys(v, out):
    if isinstance(v, dict):
        for k, x in v.items():
            out.add(k)
            keys(x, out)
    elif isinstance(v, list):
        for x in v:
            keys(x, out)

nleak = 0
for p in sorted(glob.glob(os.path.join(root, "tests", "fixtures", "cases", "*.json")) + glob.glob(os.path.join(fx, "*.plan.json"))):
    try:
        plan = json.load(open(p))
    except ValueError:
        continue
    if not isinstance(plan, dict) or not isinstance(plan.get("units"), list):
        continue
    rc, out, err = run([os.path.join(d, "gate"), "blind", p])
    q = json.loads(out)
    ks = set()
    keys(q, ks)
    # `expect` may be a key of an object value the planner wrote in an ARGUMENT; only the question's own structure is checked
    for u in q["units"]:
        if set(u.keys()) - {"id", "signature", "description", "cases"}:
            fail("blind %s: a unit has keys %s" % (os.path.basename(p), sorted(u.keys())))
        for cs in u["cases"]:
            if set(cs.keys()) - {"args"}:
                fail("blind %s: a case has keys %s" % (os.path.basename(p), sorted(cs.keys())))
    qtext = out
    for u in plan["units"]:
        if not (isinstance(u, dict) and isinstance(u.get("cases"), list) and u["cases"]):
            continue
        visible = []
        for k in ("signature", "description", "id"):
            strings(u.get(k), visible)
        for c in u["cases"]:
            if isinstance(c, dict):
                strings(c.get("args"), visible)
        hidden = []
        for c in u["cases"]:
            if isinstance(c, dict):
                strings(c.get("expect"), hidden)
        for e in u.get("examples", []) if isinstance(u.get("examples"), list) else []:
            strings(e, hidden)
        for h in hidden:
            if len(h) > 3 and not any(h in v for v in visible):
                nleak += 1
                for form in (h, json.dumps(h, ensure_ascii=False)[1:-1], json.dumps(h)[1:-1]):
                    if form in qtext:
                        fail("blind %s: the planner's value %r reached the questions" % (os.path.basename(p), h))
print("blind: %d planner texts checked for leaks" % nleak)
if nleak < 15:
    fail("the leak check saw only %d hidden texts; the fixtures should have more" % nleak)

# ---- semantic ---------------------------------------------------------------------------------
def mutate(v):
    if v is None:
        return "x"
    if isinstance(v, bool):
        return not v
    if isinstance(v, int):
        return v - 1 if v >= (1 << 63) - 1 else v + 1
    if isinstance(v, list):
        return v + ["x"]
    if isinstance(v, str):
        return v + "x"
    if "err" in v:
        x = v["err"]
        return {"err": x + 1} if isinstance(x, int) and not isinstance(x, bool) else {"ok": 1}
    if "ok" in v:
        return {"ok": mutate(v["ok"])}
    return {"bytes": v["bytes"] + [120]}

def honest(v):
    """Another spelling of the same answer: an error payload as true, an ASCII text as bytes."""
    if isinstance(v, dict) and "err" in v and len(v) == 1:
        return {"err": True} if not (isinstance(v["err"], int) and not isinstance(v["err"], bool)) else v
    if isinstance(v, dict) and "ok" in v and len(v) == 1:
        return {"ok": honest(v["ok"])}
    if isinstance(v, str) and v.isascii() and v:
        return {"bytes": list(v.encode())}
    if isinstance(v, list):
        return [honest(x) for x in v]
    return v

cexp = {}
for l in open(os.path.join(root, "tests", "fixtures", "cases", "expected.txt")):
    if l.strip() and not l.startswith("#"):
        n, rc, _ = l.rstrip("\n").split("\t", 2)
        cexp[n] = int(rc)
names = [n for n, rc in cexp.items() if rc == 0] + ["synthetic"]
tmp = os.path.join(d, "sem")
os.makedirs(tmp)
nplans = ncases = ndropped = nskipped = nexp = noex = 0
for n in names:
    pp = os.path.join(root, "tests", "fixtures", "cases", n + ".json")
    plan = json.load(open(pp))
    answers = {"units": []}
    survivors = copy.deepcopy(plan)
    for u, su in zip(plan["units"], survivors["units"]):
        if not (isinstance(u, dict) and isinstance(u.get("cases"), list) and len(u["cases"]) >= 1):
            continue
        cs = u["cases"]
        ans, keep = [], []
        for i, c in enumerate(cs):
            if len(cs) >= 2 and i == 0:
                ans.append({"expect": mutate(c["expect"])}); ndropped += 1
            elif len(cs) >= 3 and i == 1:
                ans.append({"skip": True}); nskipped += 1
            else:
                ans.append({"expect": honest(c["expect"])}); keep.append(c)
        ncases += len(cs)
        su["cases"] = keep
        answers["units"].append({"id": u["id"], "answers": ans})
    ap = os.path.join(tmp, n + ".answers.json")
    json.dump(answers, open(ap, "w"))
    rc, out, err = run([os.path.join(d, "gate"), "apply", pp, ap])
    if rc != 0:
        fail("%s: apply exited %d: %s" % (n, rc, err[:400]))
        continue
    got = json.loads(out)
    if json.dumps(got, sort_keys=True) != json.dumps(survivors, sort_keys=True):
        fail("%s: the surviving cases are not exactly the unperturbed ones\n  got:  %s\n  want: %s" % (n, out[:300], json.dumps(survivors)[:300]))
        continue
    nplans += 1
    # it still expands, and the expansion passes the plan check as the original's did
    outp = os.path.join(tmp, n + ".reviewed.json")
    open(outp, "w").write(out)
    erc, eout, eerr = run([os.path.join(d, "cases"), outp])
    orc, oout, oerr = run([os.path.join(d, "cases"), pp])
    if erc != 0 and "no case can be shown as an example" in eerr and "no case can be shown as an example" not in run([os.path.join(d, "cases"), pp])[2]:
        noex += 1     # the cases left cannot be shown as documentation lines (an odd-byte text, a ==): examples are what the unit needs
        continue
    if erc != 0:
        fail("%s: the reviewed plan no longer expands: %s" % (n, eerr[:300]))
        continue
    nexp += 1
    for tag, text in (("reviewed", eout), ("original", oout)):
        open(os.path.join(tmp, n + "." + tag + ".expanded.json"), "w").write(text)
    prc = run([os.path.join(d, "plancheck"), os.path.join(tmp, n + ".reviewed.expanded.json")])[0]
    qrc = run([os.path.join(d, "plancheck"), os.path.join(tmp, n + ".original.expanded.json")])[0]
    if n == "synthetic" and prc != 0:
        fail("synthetic: the reviewed and expanded plan fails the plan check")
    if prc != qrc and n != "synthetic":
        # dropping cases may only break the plan check when it was already broken for another reason
        if qrc == 0:
            fail("%s: the original expansion passes the plan check, the reviewed one does not" % n)
print("semantic: %d plans, %d cases, %d perturbed (dropped), %d skipped (dropped); %d reviewed plans still expand (%d more only need examples)" % (nplans, ncases, ndropped, nskipped, nexp, noex))
sys.exit(1 if fails else 0)
PY
rc=$?
rm -rf "$d"
[ "$rc" = 0 ] && echo "review gate: ok" || { echo "review gate: FAILED" >&2; exit 1; }
