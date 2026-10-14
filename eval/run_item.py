#!/usr/bin/env python3
"""Run one eval item through cancho-code's `project` driver with the native agent, grade it with the hidden audit, and measure it.

    CANCHO=<compiler> python3 eval/run_item.py <item> --provider anthropic --model claude-haiku-5-5 \
        --key-file ~/.config/cancho-code/anthropic.key --workspace <id> --primer <file> --runs 3 --label baseline --out <dir>

For run i it makes <out>/<label>-<item>-<i>/ holding: project.cho and the driver's files, raw.txt (every raw reply), usage.jsonl (one line per API
call), run.log, run.json, audit.txt (the hidden audit's output) and result.json (eval/metrics.py's numbers). The scaffold is `edition 7;` plus the
imports the plan's signatures name (std.result / std.buffer / std.option); nothing else is given to the builder besides the plan and the primer.
Exit 0 when every run was graded (not when it passed). Needs: the `project` binary and build/cancho-agent (scripts/build-agent.sh); --tools names
the directory holding `project` (default /tmp/evaltools)."""
import argparse, json, os, re, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import metrics

def scaffold_for(plan):
    sigs = " ".join(u["signature"] for u in plan["units"])
    s = "edition 7;\n"
    for mod in ("result", "buffer", "option"):
        if re.search(r"\b%s\." % mod, sigs):
            s += "import std.%s;\n" % mod
    return s

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("item")
    ap.add_argument("--provider", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--key-file")
    ap.add_argument("--workspace")
    ap.add_argument("--primer")
    ap.add_argument("--max-tokens", default="16000")
    ap.add_argument("--thinking")
    ap.add_argument("--effort")
    ap.add_argument("--runs", type=int, default=1)
    ap.add_argument("--first", type=int, default=1)
    ap.add_argument("--label", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--attempts", default="6")
    ap.add_argument("--agent-seconds", default="300")
    ap.add_argument("--plan", help="a plan to build instead of eval/<item>/plan.json (e.g. one a model wrote)")
    ap.add_argument("--tools", default="/tmp/evaltools")
    ap.add_argument("--timeout", type=int, default=3600)
    a = ap.parse_args()
    cancho = os.environ.get("CANCHO")
    if not cancho:
        sys.exit("run_item: set CANCHO to the compiler")
    plan_path = os.path.abspath(a.plan) if a.plan else os.path.join(HERE, a.item, "plan.json")
    audit = os.path.join(HERE, "audit_%s.py" % a.item)
    plan = json.load(open(plan_path))
    scaffold = scaffold_for(plan)
    for need in (os.path.join(a.tools, "project"), os.path.join(ROOT, "build", "cancho-agent"), plan_path, audit):
        if not os.path.exists(need):
            sys.exit("run_item: missing %s" % need)
    results = []
    for i in range(a.first, a.first + a.runs):
        wd = os.path.abspath(os.path.join(a.out, "%s-%s-%d" % (a.label, a.item, i)))
        shutil.rmtree(wd, ignore_errors=True)
        os.makedirs(wd)
        open(os.path.join(wd, "project.cho"), "w").write(scaffold)
        agent = [os.path.join(ROOT, "scripts", "cancho-agent.sh"), "--provider", a.provider, "--model", a.model,
                 "--max-tokens", a.max_tokens, "--save-raw", os.path.join(wd, "raw.txt"), "--usage-log", os.path.join(wd, "usage.jsonl")]
        if a.key_file: agent += ["--key-file", os.path.expanduser(a.key_file)]
        if a.workspace: agent += ["--workspace", a.workspace]
        if a.primer: agent += ["--primer", os.path.abspath(a.primer)]
        if a.thinking: agent += ["--thinking", a.thinking]
        if a.effort: agent += ["--effort", a.effort]
        started = time.time()
        try:
            p = subprocess.run([os.path.join(a.tools, "project"), cancho, plan_path, wd, " ".join(agent), a.attempts, a.agent_seconds],
                               capture_output=True, text=True, timeout=a.timeout)
            out, rc = p.stdout, p.returncode
        except subprocess.TimeoutExpired as e:
            out, rc = (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or ""), 124
        seconds = round(time.time() - started, 1)
        open(os.path.join(wd, "run.log"), "w").write(out)
        json.dump({"item": a.item, "label": a.label, "run": i, "provider": a.provider, "model": a.model, "scaffold_chars": len(scaffold),
                   "seconds": seconds, "exit": rc, "cancho": cancho, "primer": a.primer, "max_tokens": a.max_tokens,
                   "thinking": a.thinking, "effort": a.effort, "plan": plan_path}, open(os.path.join(wd, "run.json"), "w"), indent=1)
        env = dict(os.environ, CANCHO=cancho)
        ap_ = subprocess.run([sys.executable, audit, os.path.join(wd, "project.cho")], capture_output=True, text=True, env=env)
        open(os.path.join(wd, "audit.txt"), "w").write(ap_.stdout + ap_.stderr)
        r = metrics.analyze(wd, plan_path, os.path.join(HERE, "prices.json"))
        r.update({"item": a.item, "run": i, "exit": rc})
        json.dump(r, open(os.path.join(wd, "result.json"), "w"), indent=1)
        results.append(r)
        au = r.get("audit", {})
        print("%s run %d: %s units %d/%d audit %s/%s calls %d out_tok %d cost $%s eff %s %ss" % (
            a.item, i, r["project_verdict"] or "exit%d" % rc, r["units_verified"], r["units_total"], au.get("passed"), au.get("of"),
            r["calls"], r["tokens"]["out"], r["cost_usd"], r["efficiency"], seconds), flush=True)

if __name__ == "__main__":
    main()
