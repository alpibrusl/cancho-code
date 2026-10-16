#!/usr/bin/env python3
"""How right is a model-written plan? Run a plan's examples and tests against the item's hand-checked reference.cho (which scores full marks on the hidden audit).

    CANCHO=<compiler> python3 eval/plan_vs_reference.py <item> <plan.json> [--json]

For each unit whose function the reference defines (the public ones; helper units the planner invented are not in the reference and cannot be judged), the
unit's tests (or, with none, the tests the driver would make from its examples) are compiled with the reference and run. A test that FAILS against the
reference is a wrong test: a builder that satisfied it would be wrong, and one that is right cannot. A test file that does not build is reported apart
(it may call a helper the reference lacks). Prints one line per judged unit and a total `wrong/judged`."""
import json, os, re, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
C = os.environ.get("CANCHO", "cancho")

def tests_for(unit):
    if unit.get("tests"):
        return "\n".join(unit["tests"]), None
    sid = re.sub(r"[^A-Za-z0-9_]", "_", unit["id"])
    out = []
    for k, ex in enumerate(unit["examples"], 1):
        out.append("pub fn test_%s_%d() -> [] int { test.assert(%s); return 0; }" % (sid, k, ex))
    return "\n".join(out), None

def run(ref_path, body, module=""):
    """ref_path is the reference file, or a list of the module files of a multi-file item (docs/multi-file.md); a unit of a module has its tests in that module and
    they run on the module files, as the project driver runs them."""
    d = tempfile.mkdtemp(prefix="pvr-")
    t = os.path.join(d, "tests.cho")
    open(t, "w").write("edition 7;\n" + ("module %s;\n" % module if module else "") + "import std.test;\n" + body + "\n")
    p = subprocess.run([C, "test", "--std", "--backend", "cranelift"] + (ref_path if isinstance(ref_path, list) else [ref_path]) + [t], capture_output=True, text=True)
    out = p.stdout + p.stderr
    m = re.search(r"test result: \w+\. (\d+) passed; (\d+) failed", out)
    if m:
        return int(m.group(1)), int(m.group(2)), ""
    first = next((l for l in out.splitlines() if "error" in l), out.strip().splitlines()[-1] if out.strip() else "")
    return 0, 0, first[:160]

def main():
    item, plan_path = sys.argv[1], sys.argv[2]
    ref = os.path.join(HERE, item, "reference.cho")
    plan = json.load(open(plan_path))
    # an item of several files has its reference in a directory, one file per module (eval/multi/reference/)
    refdir = os.path.join(HERE, item, "reference")
    modules = {}
    if os.path.isdir(refdir):
        ref = sorted(os.path.join(refdir, f) for f in os.listdir(refdir) if f.endswith(".cho") and f != "project.cho")
        src = "\n".join(open(f).read() for f in ref)
        modules = {e["file"]: e.get("module", "") for e in plan.get("files", []) if isinstance(e, dict) and "file" in e}
    else:
        src = open(ref).read()
    judged = wrong = unbuilt = tot_pass = tot_fail = 0
    rows = []
    for u in plan["units"]:
        m = re.match(r"fn\s+(\w+)", u["signature"])
        if not m or not re.search(r"\bfn\s+%s\b" % re.escape(m.group(1)), src):
            continue
        body, _ = tests_for(u)
        passed, failed, err = run(ref, body, modules.get(u.get("file", ""), "") if modules else "")
        judged += 1
        if err:
            unbuilt += 1
            rows.append((u["id"], "does not build: " + err))
        else:
            tot_pass += passed; tot_fail += failed
            if failed:
                wrong += 1
            rows.append((u["id"], "%d pass, %d FAIL" % (passed, failed)))
    res = {"item": item, "judged": judged, "units_with_wrong_tests": wrong, "units_unbuilt": unbuilt, "tests_passed": tot_pass, "tests_failed": tot_fail}
    if "--json" in sys.argv:
        print(json.dumps(res))
    else:
        for r in rows: print("  %-14s %s" % r)
        print("%s: %d judged units, %d with a failing test, %d tests build-failed; %d pass %d fail" % (item, judged, wrong, unbuilt, tot_pass, tot_fail))
if __name__ == "__main__":
    main()
