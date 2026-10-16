#!/usr/bin/env python3
"""Build a service from its hand plan (eval/services/<service>/plan.json) with the project driver and the native agent, grade it with the hidden attack,
measure it (docs/project.md, "Services").

    CANCHO=<compiler> CANCHO_PACKAGES=<packages> python3 eval/run_service_plan.py <service> --provider anthropic --model claude-haiku-5-5 \
        --key-file <path> --workspace <id> --primer <language page> --label L --out DIR [--runs N] [--first N] [--effort E] [--max-tokens 16000]

The units are built one at a time by the driver (`project`, the `--tools` directory) with `build/cancho-agent --output patch`. The pure units are judged by
their own tests; the last unit, the application (`integration` in the plan), by the service's acceptance scenarios (eval/service_run.py accept --bare),
whose output is the next attempt's feedback. The page the builder gets is --primer followed by eval/services/service-guide.md.
For run i: <out>/<label>-<service>-<i>/ holds project.cho (starts as `bare.sh --header` of the reference: the imports, no code), the driver's files,
raw.txt, usage.jsonl, run.log, accept.log of the last acceptance (the driver's feedback), attack.txt (the hidden attack), result.json."""
import argparse, json, os, re, shutil, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import metrics, service_run

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("service")
    ap.add_argument("--provider", required=True); ap.add_argument("--model", required=True)
    ap.add_argument("--key-file"); ap.add_argument("--workspace"); ap.add_argument("--primer", required=True)
    ap.add_argument("--guide", default=os.path.join(HERE, "services", "service-guide.md"))
    ap.add_argument("--max-tokens", default="16000"); ap.add_argument("--thinking"); ap.add_argument("--effort")
    ap.add_argument("--attempts", default="6"); ap.add_argument("--agent-seconds", default="600")
    ap.add_argument("--runs", type=int, default=1); ap.add_argument("--first", type=int, default=1)
    ap.add_argument("--label", required=True); ap.add_argument("--out", required=True)
    ap.add_argument("--plan", help="a plan to build instead of eval/services/<service>/plan.json")
    ap.add_argument("--tools", default="/tmp/evaltools")
    ap.add_argument("--timeout", type=int, default=5400)
    a = ap.parse_args()
    cancho = os.environ.get("CANCHO") or sys.exit("run_service_plan: set CANCHO")
    pk = os.environ.get("CANCHO_PACKAGES") or os.path.normpath(os.path.join(os.path.dirname(os.path.realpath(cancho)), "..", "..", "packages"))
    sdir = os.path.join(HERE, "services", a.service)
    plan_path = os.path.abspath(a.plan) if a.plan else os.path.join(sdir, "plan.json")
    ref = os.path.join(sdir, "reference", "project.cho")
    for need in (os.path.join(a.tools, "project"), os.path.join(ROOT, "build", "cancho-agent"), plan_path, ref, os.path.join(pk, "http-server", "server.cho")):
        if not os.path.exists(need): sys.exit("run_service_plan: missing %s" % need)
    os.makedirs(a.out, exist_ok=True)
    page = os.path.join(a.out, "page-%s.md" % a.label)
    open(page, "w").write(open(a.primer).read() + "\n\n" + open(a.guide).read())
    header = subprocess.run(["sh", os.path.join(HERE, "services", "bare.sh"), "--header", ref], capture_output=True, text=True, check=True).stdout
    for i in range(a.first, a.first + a.runs):
        wd = os.path.abspath(os.path.join(a.out, "%s-%s-%d" % (a.label, a.service, i)))
        shutil.rmtree(wd, ignore_errors=True); os.makedirs(wd)
        open(os.path.join(wd, "project.cho"), "w").write(header)
        agent = [os.path.join(ROOT, "scripts", "cancho-agent.sh"), "--provider", a.provider, "--model", a.model, "--primer", page, "--output", "patch",
                 "--max-tokens", a.max_tokens, "--save-raw", os.path.join(wd, "raw.txt"), "--usage-log", os.path.join(wd, "usage.jsonl")]
        if a.key_file: agent += ["--key-file", os.path.expanduser(a.key_file)]
        if a.workspace: agent += ["--workspace", a.workspace]
        if a.thinking: agent += ["--thinking", a.thinking]
        if a.effort: agent += ["--effort", a.effort]
        # the scenarios' output is the feedback; the driver appends the project file to this command
        accept = "CANCHO=%s CANCHO_PACKAGES=%s PATH=/usr/local/bin:/usr/bin:/bin python3 %s accept --bare %s" % (cancho, pk, os.path.join(HERE, "service_run.py"), a.service)
        started = time.time()
        try:
            p = subprocess.run([os.path.join(a.tools, "project"), cancho, plan_path, wd, " ".join(agent), a.attempts, a.agent_seconds, accept, " ".join([os.path.join(pk, "http-server", "server.cho")] + service_run.service_libs(a.service))],
                               capture_output=True, text=True, timeout=a.timeout)
            out, rc = p.stdout, p.returncode
        except subprocess.TimeoutExpired as e:
            out, rc = (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or ""), 124
        seconds = round(time.time() - started, 1)
        open(os.path.join(wd, "run.log"), "w").write(out)
        json.dump({"item": a.service, "label": a.label, "run": i, "provider": a.provider, "model": a.model, "scaffold_chars": len(header), "seconds": seconds, "exit": rc,
                   "cancho": cancho, "primer": a.primer, "max_tokens": a.max_tokens, "thinking": a.thinking, "effort": a.effort, "plan": plan_path, "patch": True},
                  open(os.path.join(wd, "run.json"), "w"), indent=1)
        env = dict(os.environ, CANCHO=cancho, CANCHO_PACKAGES=pk)
        at = subprocess.run([sys.executable, os.path.join(HERE, "service_run.py"), "attack", "--bare", a.service, os.path.join(wd, "project.cho")], capture_output=True, text=True, env=env, timeout=600)
        open(os.path.join(wd, "attack.txt"), "w").write(at.stdout + at.stderr)
        m = re.findall(r"\[ATTACK\] (\d+)/(\d+) hold", at.stdout)
        r = metrics.analyze(wd, plan_path, os.path.join(HERE, "prices.json"))
        r.update({"service": a.service, "run": i, "exit": rc, "attack": {"passed": int(m[-1][0]), "of": int(m[-1][1])} if m else None})
        json.dump(r, open(os.path.join(wd, "result.json"), "w"), indent=1)
        print("%s run %d: %s units %d/%d attack %s calls %d out_tok %d cost $%s %ss" % (
            a.service, i, r["project_verdict"] or "exit%d" % rc, r["units_verified"], r["units_total"],
            ("%d/%d" % (r["attack"]["passed"], r["attack"]["of"])) if r["attack"] else "n/a", r["calls"], r["tokens"]["out"], r["cost_usd"], seconds), flush=True)

if __name__ == "__main__":
    main()
