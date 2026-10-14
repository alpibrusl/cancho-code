#!/usr/bin/env python3
"""Ask a model to PLAN an eval item (docs/decomposition.md), from its brief and the signatures of its public functions only, and check the plan.

    CANCHO=<compiler> python3 eval/plan_item.py <item> --provider anthropic --model claude-haiku-5-5 --key-file ... --primer <AGENTS.md> \
        --guide docs/plan-guide.md --runs 3 --label gen --out <dir>

What the planner sees: eval/<item>/brief.txt and the REQUIRED PUBLIC FUNCTIONS, which are the hand plan's signatures for the functions the item's audit
grades (those whose names appear in eval/audit_<item>.py). It never sees the hand plan's descriptions, examples, tests, decomposition or the oracle. The audit
is written against exactly those signatures, so a generated plan is graded on the same terms as the hand-written one; what is tested is the
decomposition, the descriptions and the examples. For run i: <out>/<label>-<item>-<i>/ holds plan.json (only if the plan check passed), contract.txt,
plan-usage.jsonl, plan-raw.txt, plan.log (the agent's stderr) and plan-result.json (valid, rounds, units, tokens, cost, exit code)."""
import argparse, json, os, re, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import metrics

def contract_for(item):
    plan = json.load(open(os.path.join(HERE, item, "plan.json")))
    audit = open(os.path.join(HERE, "audit_%s.py" % item), encoding="utf-8").read()
    lines = []
    for u in plan["units"]:
        m = re.match(r"fn\s+(\w+)", u["signature"])
        if m and re.search(r"\b%s\b" % re.escape(m.group(1)), audit):
            lines.append(u["signature"])
    return "\n".join(lines) + "\n"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("item")
    ap.add_argument("--provider", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--key-file")
    ap.add_argument("--workspace")
    ap.add_argument("--primer")
    ap.add_argument("--guide", default=os.path.join(ROOT, "docs", "plan-guide.md"))
    ap.add_argument("--max-tokens", default="16000")
    ap.add_argument("--thinking")
    ap.add_argument("--effort")
    ap.add_argument("--rounds", default="3")
    ap.add_argument("--no-contract", action="store_true", help="give the brief only (the planner must also choose the public names and shapes)")
    ap.add_argument("--runs", type=int, default=1)
    ap.add_argument("--label", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--tools", default="/tmp/evaltools")
    a = ap.parse_args()
    brief = os.path.join(HERE, a.item, "brief.txt")
    contract = contract_for(a.item)
    for i in range(1, a.runs + 1):
        wd = os.path.abspath(os.path.join(a.out, "%s-%s-%d" % (a.label, a.item, i)))
        shutil.rmtree(wd, ignore_errors=True)
        os.makedirs(wd)
        cpath = os.path.join(wd, "contract.txt")
        open(cpath, "w").write(contract)
        out = os.path.join(wd, "plan.json")
        cmd = [os.path.join(ROOT, "scripts", "cancho-agent.sh"), "--provider", a.provider, "--model", a.model, "--mode", "plan",
               "--guide", os.path.abspath(a.guide), "--brief", brief, "--rounds", a.rounds, "--max-tokens", a.max_tokens,
               "--save-raw", os.path.join(wd, "plan-raw.txt"), "--usage-log", os.path.join(wd, "plan-usage.jsonl")]
        if not a.no_contract: cmd += ["--contract", cpath]
        if a.key_file: cmd += ["--key-file", os.path.expanduser(a.key_file)]
        if a.workspace: cmd += ["--workspace", a.workspace]
        if a.primer: cmd += ["--primer", os.path.abspath(a.primer)]
        if a.thinking: cmd += ["--thinking", a.thinking]
        if a.effort: cmd += ["--effort", a.effort]
        cmd.append(out)
        t = time.time()
        p = subprocess.run(cmd, capture_output=True, text=True)
        secs = round(time.time() - t, 1)
        open(os.path.join(wd, "plan.log"), "w").write(p.stderr)
        valid = False
        if os.path.exists(out):
            valid = subprocess.run([os.path.join(a.tools, "plancheck"), out], capture_output=True, text=True).stdout.strip().endswith("valid") and True
        rows = metrics.load_jsonl(os.path.join(wd, "plan-usage.jsonl"))
        prices = json.load(open(os.path.join(HERE, "prices.json")))
        price = metrics.price_for(prices, a.provider, a.model)
        cost = round(sum(metrics.call_cost(price, r)[0] for r in rows), 6) if price else None
        units = len(json.load(open(out))["units"]) if valid else 0
        res = {"item": a.item, "run": i, "exit": p.returncode, "valid": valid, "rounds": len(rows), "units": units, "seconds": secs,
               "outcomes": [r["outcome"] for r in rows], "out_tokens": sum(r["out"] for r in rows), "cost_usd": cost,
               "model": a.model, "contract": not a.no_contract}
        json.dump(res, open(os.path.join(wd, "plan-result.json"), "w"), indent=1)
        print("%s plan %d: exit %d valid %s rounds %d units %d out_tok %d cost $%s %ss %s" % (a.item, i, p.returncode, valid, len(rows), units,
              res["out_tokens"], cost, secs, res["outcomes"]), flush=True)

if __name__ == "__main__":
    main()
