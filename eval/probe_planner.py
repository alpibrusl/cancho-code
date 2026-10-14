#!/usr/bin/env python3
"""Does the planner say 'unclear' / 'too_big' when it should, and plan when it can?  python3 eval/probe_planner.py <runs> <outdir> <agent args...>
Runs the planner on each file in eval/probes/ <runs> times and prints the exit code per run: 0 = a plan, 3 = a question or a breakdown, 1 = failed."""
import glob, json, os, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
runs, out = int(sys.argv[1]), sys.argv[2]
extra = sys.argv[3:]
os.makedirs(out, exist_ok=True)
for brief in sorted(glob.glob(os.path.join(HERE, "probes", "*.txt"))):
    name = os.path.basename(brief)[:-4]
    codes = []
    for i in range(1, runs + 1):
        o = os.path.join(out, "%s-%d.plan.json" % (name, i))
        for f in (o, o + ".questions.json"):
            if os.path.exists(f): os.remove(f)
        p = subprocess.run([os.path.join(ROOT, "scripts", "cancho-agent.sh"), "--mode", "plan", "--guide", os.path.join(ROOT, "docs", "plan-guide.md"),
                            "--brief", brief] + extra + [o], capture_output=True, text=True)
        what = ""
        q = o + ".questions.json"
        if os.path.exists(q):
            d = json.load(open(q)); what = d.get("status", "") + " " + str(len(d.get("questions", d.get("modules", []))))
        elif os.path.exists(o):
            what = "%d units" % len(json.load(open(o))["units"])
        codes.append("%d(%s)" % (p.returncode, what))
    print("%-18s %s" % (name, "  ".join(codes)), flush=True)
