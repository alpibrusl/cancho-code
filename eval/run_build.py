#!/usr/bin/env python3
"""Run the one-command build (build/cancho-build) on an eval item from its brief ALONE (or with the required signatures as --contract), grade the result with the
item's hidden audit and measure it (plan calls and unit calls together).

    CANCHO=<compiler> python3 eval/run_build.py <item> --provider anthropic --model claude-haiku-5-5 --key-file ... --primer <AGENTS.md> \\
        [--contract] [--runs 3] [--label build] --out <dir>

Per run: <out>/<label>-<item>-<i>/ holds what cancho-build leaves (plan.json, state.txt, build.json, run.log, usage.jsonl, ...) plus run.json, audit.txt, result.json.
The Python here is the harness (grading and bookkeeping); the build itself is cancho."""
import argparse, json, os, shutil, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import metrics, plan_item

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("item"); ap.add_argument("--provider", required=True); ap.add_argument("--model", required=True)
    ap.add_argument("--key-file"); ap.add_argument("--workspace"); ap.add_argument("--primer"); ap.add_argument("--max-tokens", default="16000")
    ap.add_argument("--memory", help="a memory directory (docs/memory.md): lessons.jsonl and facts.txt the unit agent recalls from")
    ap.add_argument("--contract", action="store_true", help="give the planner the required public signatures (what plan_item.py does)")
    ap.add_argument("--review", default="on"); ap.add_argument("--runs", type=int, default=1); ap.add_argument("--first", type=int, default=1)
    ap.add_argument("--label", default="build"); ap.add_argument("--out", required=True)
    ap.add_argument("--plan", help="a valid plan.json to start the work directory with (the planner is not asked)"); ap.add_argument("--jobs", default="1", help="units built at once (docs/parallel.md)"); ap.add_argument("--attempts", default="6"); ap.add_argument("--agent-seconds", default="300"); ap.add_argument("--timeout", type=int, default=3600)
    a = ap.parse_args()
    cancho = os.environ.get("CANCHO") or sys.exit("run_build: set CANCHO")
    exe = os.path.join(ROOT, "build", "cancho-build"); audit = os.path.join(HERE, "audit_%s.py" % a.item); brief = os.path.join(HERE, a.item, "brief.txt")
    for need in (exe, os.path.join(ROOT, "build", "cancho-agent"), audit, brief):
        if not os.path.exists(need): sys.exit("run_build: missing %s" % need)
    for i in range(a.first, a.first + a.runs):
        wd = os.path.abspath(os.path.join(a.out, "%s-%s-%d" % (a.label, a.item, i)))
        shutil.rmtree(wd, ignore_errors=True); os.makedirs(wd)
        if a.plan: shutil.copy(a.plan, os.path.join(wd, "plan.json"))
        agent = [os.path.join(ROOT, "scripts", "cancho-agent.sh"), "--max-tokens", a.max_tokens, "--save-raw", os.path.join(wd, "raw.txt"), "--output", "patch"]
        if a.key_file: agent += ["--key-file", os.path.expanduser(a.key_file)]
        if a.workspace: agent += ["--workspace", a.workspace]
        if a.primer: agent += ["--primer", os.path.abspath(a.primer)]
        cmd = [exe, cancho, brief, wd, " ".join(agent), "--provider", a.provider, "--model", a.model, "--guide", os.path.join(ROOT, "docs", "plan-guide.md"),
               "--attempts", a.attempts, "--agent-seconds", a.agent_seconds, "--jobs", a.jobs]
        if a.review == "on": cmd += ["--review", "on", "--review-guide", os.path.join(ROOT, "docs", "review-guide.md")]
        if a.memory: cmd += ["--memory", os.path.abspath(a.memory)]
        if a.contract:
            cf = os.path.join(wd, "contract.txt"); open(cf, "w").write(plan_item.contract_for(a.item)); cmd += ["--contract", cf]
        t0 = time.time()
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=a.timeout, env=dict(os.environ, CANCHO=cancho)); out, rc = p.stdout, p.returncode
        except subprocess.TimeoutExpired:
            out, rc = "", 124
        seconds = round(time.time() - t0, 1)
        open(os.path.join(wd, "stdout.txt"), "w").write(out)
        json.dump({"item": a.item, "label": a.label, "run": i, "provider": a.provider, "model": a.model, "seconds": seconds, "exit": rc, "cancho": cancho,
                   "contract": a.contract, "review": a.review, "patch": True, "primer": a.primer, "memory": a.memory}, open(os.path.join(wd, "run.json"), "w"), indent=1)
        ap_ = subprocess.run([sys.executable, audit, os.path.join(wd, "project.cho")], capture_output=True, text=True, env=dict(os.environ, CANCHO=cancho))
        open(os.path.join(wd, "audit.txt"), "w").write(ap_.stdout + ap_.stderr)
        planp = os.path.join(wd, "plan.json")
        r = metrics.analyze(wd, planp if os.path.exists(planp) else None, os.path.join(HERE, "prices.json"))
        r.update({"item": a.item, "run": i, "exit": rc}); json.dump(r, open(os.path.join(wd, "result.json"), "w"), indent=1)
        v = [l.split("\t")[1] for l in out.splitlines() if l.startswith("[BUILD_VERDICT]")]
        au = r.get("audit") or {}
        print("%s run %d: %s units %s/%s audit %s/%s calls %s out_tok %s cost $%s %ss" % (a.item, i, v[0] if v else "exit%d" % rc, r["units_verified"], r["units_total"],
              au.get("passed"), au.get("of"), r["calls"], r["tokens"]["out"], r["cost_usd"], seconds), flush=True)
main()
