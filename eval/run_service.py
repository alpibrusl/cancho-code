#!/usr/bin/env python3
"""Build a service with cancho-code (the `fix` loop with the service's acceptance scenarios as the acceptance command), grade it with the hidden attack, measure it.

    CANCHO=<compiler> python3 eval/run_service.py <service> --provider anthropic --model ... --key-file ... --primer <page> [--guide eval/services/service-guide.md]
        --label L --out DIR [--runs N] [--attempts 6]

For run i: <out>/<label>-<service>-<i>/ holds project.cho (starts as the stub app that answers 404 to everything), project.cho.task (the brief and the
application interface), the fix loop's files, usage.jsonl, raw.txt, fix.log, accept.log (the last acceptance output), attack.txt (the hidden attack), result.json.
The language page the builder gets is --primer followed by --guide (the service guide: the application interface and a worked handler)."""
import argparse, json, os, re, shutil, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import metrics

def interface_text():
    src = open(os.path.join(HERE, "services", "skeleton", "main.cho"), encoding="utf-8").read()
    head = []
    for line in src.splitlines():
        if line.startswith("//"): head.append(line[3:] if line.startswith("// ") else line[2:])
        elif head and line.strip() == "": break
        elif head: break
    return "\n".join(head)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("service")
    ap.add_argument("--provider", required=True); ap.add_argument("--model", required=True)
    ap.add_argument("--key-file"); ap.add_argument("--workspace")
    ap.add_argument("--primer", required=True)
    ap.add_argument("--guide", default=os.path.join(HERE, "services", "service-guide.md"))
    ap.add_argument("--max-tokens", default="16000"); ap.add_argument("--thinking"); ap.add_argument("--effort")
    ap.add_argument("--attempts", default="6"); ap.add_argument("--agent-seconds", default="600"); ap.add_argument("--accept-seconds", default="180")
    ap.add_argument("--runs", type=int, default=1); ap.add_argument("--first", type=int, default=1)
    ap.add_argument("--label", required=True); ap.add_argument("--out", required=True)
    ap.add_argument("--tools", default="/tmp/evaltools")
    a = ap.parse_args()
    cancho = os.environ.get("CANCHO") or sys.exit("run_service: set CANCHO")
    sdir = os.path.join(HERE, "services", a.service)
    brief = open(os.path.join(sdir, "brief.txt"), encoding="utf-8").read()
    fix = os.path.join(a.tools, "fix")
    for need in (fix, os.path.join(ROOT, "build", "cancho-agent"), os.path.join(sdir, "accept.py"), os.path.join(sdir, "attack.py")):
        if not os.path.exists(need): sys.exit("run_service: missing %s" % need)
    pk = os.environ.get("CANCHO_PACKAGES") or os.path.normpath(os.path.join(os.path.dirname(os.path.realpath(cancho)), "..", "..", "packages"))
    extra = "%s %s" % (os.path.join(HERE, "services", "skeleton", "main.cho"), os.path.join(pk, "http-server", "server.cho"))
    # the page the builder gets: the language page, then the service guide
    page = os.path.join(a.out, "page-%s.md" % a.label)
    os.makedirs(a.out, exist_ok=True)
    open(page, "w").write(open(a.primer).read() + "\n\n" + (open(a.guide).read() if os.path.exists(a.guide) else ""))
    for i in range(a.first, a.first + a.runs):
        wd = os.path.abspath(os.path.join(a.out, "%s-%s-%d" % (a.label, a.service, i)))
        shutil.rmtree(wd, ignore_errors=True); os.makedirs(wd)
        proj = os.path.join(wd, "project.cho")
        shutil.copy(os.path.join(HERE, "services", "skeleton", "app_stub.cho"), proj)
        open(proj + ".task", "w").write("Build this service. The file project.cho is the application part of a cancho HTTP service; it starts as a working stub that answers 404 to everything. Replace it with the full application.\n\nTHE TASK\n" + brief + "\n\nTHE PROJECT LAYOUT AND APPLICATION INTERFACE\n" + interface_text() + "\n")
        agent = [os.path.join(ROOT, "scripts", "cancho-agent.sh"), "--provider", a.provider, "--model", a.model, "--primer", page,
                 "--max-tokens", a.max_tokens, "--save-raw", os.path.join(wd, "raw.txt"), "--usage-log", os.path.join(wd, "usage.jsonl")]
        if a.key_file: agent += ["--key-file", os.path.expanduser(a.key_file)]
        if a.workspace: agent += ["--workspace", a.workspace]
        if a.thinking: agent += ["--thinking", a.thinking]
        if a.effort: agent += ["--effort", a.effort]
        accept = "CANCHO=%s CANCHO_PACKAGES=%s PATH=/usr/local/bin:/usr/bin:/bin python3 %s accept %s" % (cancho, pk, os.path.join(HERE, "service_run.py"), a.service)
        # the driver appends the project file to the acceptance command; tee keeps the last scenario output for the report
        # the exit status must be the scenarios', not tee's: keep the output in a file, show it, and exit with the status
        accept = "sh -c '%s \"$0\" > %s 2>&1; rc=$?; cat %s; exit $rc'" % (accept, os.path.join(wd, "accept.log"), os.path.join(wd, "accept.log"))
        t = time.time()
        p = subprocess.run([fix, cancho, proj, " ".join(agent), a.attempts, a.agent_seconds, accept, a.accept_seconds, extra], capture_output=True, text=True)
        secs = round(time.time() - t, 1)
        open(os.path.join(wd, "fix.log"), "w").write(p.stdout + p.stderr)
        env = dict(os.environ, CANCHO=cancho, CANCHO_PACKAGES=pk)
        at = subprocess.run([sys.executable, os.path.join(HERE, "service_run.py"), "attack", a.service, proj], capture_output=True, text=True, env=env, timeout=300)
        open(os.path.join(wd, "attack.txt"), "w").write(at.stdout + at.stderr)
        m = re.findall(r"\[ATTACK\] (\d+)/(\d+) hold", at.stdout)
        json.dump({"service": a.service, "label": a.label, "run": i, "provider": a.provider, "model": a.model, "seconds": secs, "scaffold_chars": os.path.getsize(os.path.join(HERE, "services", "skeleton", "app_stub.cho")), "cancho": cancho, "exit": p.returncode}, open(os.path.join(wd, "run.json"), "w"), indent=1)
        rows = metrics.load_jsonl(os.path.join(wd, "usage.jsonl"))
        prices = json.load(open(os.path.join(HERE, "prices.json"))); price = metrics.price_for(prices, a.provider, a.model)
        cost = round(sum(metrics.call_cost(price, r)[0] for r in rows), 6) if price else None
        verdict = next((l.split("\t")[1] for l in p.stdout.splitlines() if l.startswith("[ISSUE_VERDICT]") and "\t" in l), "?")
        res = {"service": a.service, "run": i, "fix_verdict": verdict, "attack": {"passed": int(m[-1][0]), "of": int(m[-1][1])} if m else None, "calls": len(rows),
               "out_tokens": sum(r["out"] for r in rows), "cost_usd": cost, "seconds": secs}
        json.dump(res, open(os.path.join(wd, "result.json"), "w"), indent=1)
        print("%s run %d: fix %s attack %s calls %d out_tok %d cost $%s %ss" % (a.service, i, verdict, ("%d/%d" % (res["attack"]["passed"], res["attack"]["of"])) if res["attack"] else "n/a", len(rows), res["out_tokens"], cost, secs), flush=True)

if __name__ == "__main__":
    main()
