#!/usr/bin/env python3
"""Mutation evidence for the users service (eval/services/users/mutants.json): each mutant is the reference application with ONE change; the hidden attack
must fail it, and fail the check the mutant names (`caught_by`, a substring of the failing check's name).

    CANCHO=<compiler> python3 eval/mutate_users.py [name ...]      exit 0 only if every mutant is caught by its named check

The attack's failures are printed one per line (`  - <check>: <why>`); a mutant that does not build, or whose named check still holds, is reported."""
import json, os, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
sdir = os.path.join(HERE, "services", "users")
ref = open(os.path.join(sdir, "reference", "project.cho")).read()
muts = json.load(open(os.path.join(sdir, "mutants.json")))
want = sys.argv[1:]
bad = 0
for m in muts:
    if want and m["name"] not in want: continue
    if ref.count(m["find"]) != 1:
        print("FAIL %s: the text to change occurs %d times in the reference" % (m["name"], ref.count(m["find"]))); bad += 1; continue
    d = tempfile.mkdtemp(prefix="mutuser-")
    p = os.path.join(d, "project.cho"); open(p, "w").write(ref.replace(m["find"], m["replace"]))
    r = subprocess.run([sys.executable, os.path.join(HERE, "service_run.py"), "attack", "users", p], capture_output=True, text=True)
    out = r.stdout + r.stderr
    if "does not build" in out:
        print("FAIL %s: does not build: %s" % (m["name"], out.strip().splitlines()[0][:200])); bad += 1; continue
    failed = [l for l in out.splitlines() if l.startswith("  - ")]
    named = [l for l in failed if m["caught_by"] in l]
    ok = r.returncode != 0 and named
    print("%s %s: attack %s; %d checks fail; named check %s" % ("ok  " if ok else "FAIL", m["name"], out.strip().splitlines()[-1] if out.strip() else "?", len(failed), "FAILS" if named else "STILL HOLDS"))
    if not ok: bad += 1
sys.exit(1 if bad else 0)
