#!/usr/bin/env python3
"""Token, cost and efficiency metrics for one `project` run of cancho-code.

    python3 eval/metrics.py <workdir> <plan.json> [--prices eval/prices.json] [--json]

A run directory holds what the harness and the agent left (eval/run_item.py makes it):
    usage.jsonl   one line per API call (the agent's --usage-log): tokens in/out/cache, stop, outcome, program_chars, task, ms
    run.log       the driver's output: `[UNIT]<TAB>id<TAB>verdict`, `[PROJECT_VERDICT]<TAB>...`
    run.json      {"scaffold_chars": n, "seconds": n, "model": ..., "provider": ...}   (written by the harness)
    audit.txt     the hidden audit's output, ending `TOTAL n/m`   (optional)

Definitions (all stated here so a number can be argued with; none is a measurement of "thinking"):
  calls            API calls, whatever came of them
  tokens           input, output, cache write, cache read: as the API reported them, summed
  cost             sum(tokens x price per million), from prices.json for the model; a call whose prompt exceeds the model's prompt_limit is priced at the
                   higher tier and counted in `over_limit`
  kept call        for a unit that ended `verified`: the LAST call of that unit whose outcome was `written` (the program that the checker accepted)
  efficiency_calls output tokens of kept calls / all output tokens. What is lost to retries: cut-off, no-program, rejected and API-error samples
  mandatory share  (patch mode: 1.0, the reply is the unit and nothing else) of a kept call: (its program_chars - the previous kept program's chars) / its program_chars. The agent rewrites the WHOLE file
                   each time, so most of every reply repeats earlier units; only the growth is new work. The first unit's previous is the scaffold
  efficiency       sum(kept output tokens x mandatory share) / all output tokens: the share of everything generated that was both kept and new.
                   It uses characters as the proxy for how a reply's tokens split, and counts hidden reasoning tokens (which the API folds into
                   `output_tokens`) as part of the reply, so it is an upper bound on how much of the generation was the answer
  thinking         the tokens the model spent thinking before it answered, as the API reports them (usage.output_tokens_details.thinking_tokens, which are part of
                   `output_tokens`); None for runs made before the agent recorded it (unknown, not zero). `visible_out` = out - thinking, `thinking_share` = thinking / out
  efficiency_visible  like `efficiency` but over the visible tokens only: sum(kept visible x mandatory share) / all visible. It leaves hidden reasoning out, so it
                   measures the answers themselves (the rewrite of the whole file each time, and the retries), not how much the model deliberated
  per unit         the same, for each unit; `cost_per_verified_unit`, and `cost_per_audit_point` when an audit result is present
"""
import argparse, json, os, re, sys

def load_jsonl(path):
    rows = []
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows

def price_for(prices, provider, model):
    table = prices.get(provider, {})
    return table.get(model) or table.get("_any")

def call_cost(p, row):
    """USD for one call, and whether it fell in the over-limit tier."""
    over = False
    q = p
    limit = p.get("prompt_limit")
    prompt = row.get("in", 0) + row.get("cache_write", 0) + row.get("cache_read", 0)
    if limit and prompt > limit and p.get("over_limit_prices"):
        q, over = p["over_limit_prices"], True
    usd = (row.get("in", 0) * q["in"] + row.get("cache_write", 0) * q["cache_write"]
           + row.get("cache_read", 0) * q["cache_read"] + row.get("out", 0) * q["out"]) / 1e6
    return usd, over

def unit_of(task):
    m = re.match(r"UNIT:\s*(\S+)", task or "")
    return m.group(1) if m else ""

def analyze(workdir, plan_path=None, prices_path=None):
    rows = load_jsonl(os.path.join(workdir, "usage.jsonl"))
    meta = {}
    if os.path.exists(os.path.join(workdir, "run.json")):
        meta = json.load(open(os.path.join(workdir, "run.json")))
    prices = json.load(open(prices_path)) if prices_path else {}
    provider = meta.get("provider") or (rows[0]["provider"] if rows else "")
    model = meta.get("model") or (rows[0]["model"] if rows else "")
    price = price_for(prices, provider, model) if prices else None

    verdicts = {}
    order = []
    run_log = os.path.join(workdir, "run.log")
    project_verdict = ""
    if os.path.exists(run_log):
        for line in open(run_log, encoding="utf-8"):
            f = line.rstrip("\n").split("\t")
            if f[0] == "[UNIT]" and len(f) >= 3 and f[2] in ("verified", "failed", "stuck", "unavailable", "regressed", "budget"):
                verdicts[f[1]] = f[2]
                if f[1] not in order:
                    order.append(f[1])
            if f[0] == "[PROJECT_VERDICT]" and len(f) >= 2:
                project_verdict = f[1]

    units = {}
    for r in rows:
        u = unit_of(r.get("task")) or "-"
        units.setdefault(u, []).append(r)
    unit_order = [u for u in order if u in units] + [u for u in units if u not in order]

    scaffold = meta.get("scaffold_chars", 0)
    prev_chars = scaffold
    per_unit = {}
    tot = {"calls": 0, "in": 0, "out": 0, "cache_write": 0, "cache_read": 0, "ms": 0}
    known = bool(rows) and all("thinking" in r for r in rows)     # every call recorded it
    think_total = 0
    kept_visible = 0
    mandatory_visible = 0.0
    outcomes = {}
    cost = 0.0
    over_limit = 0
    kept_out = 0
    mandatory_out = 0.0
    for u in unit_order:
        calls = units[u]
        uc = {"calls": len(calls), "in": 0, "out": 0, "cache_write": 0, "cache_read": 0, "ms": 0, "cost": 0.0, "thinking": 0}
        for r in calls:
            for k in ("in", "out", "cache_write", "cache_read", "ms"):
                uc[k] += r.get(k, 0)
            uc["thinking"] += r.get("thinking", 0)
            if price:
                usd, over = call_cost(price, r)
                uc["cost"] += usd
                over_limit += 1 if over else 0
            outcomes[r.get("outcome")] = outcomes.get(r.get("outcome"), 0) + 1
        verdict = verdicts.get(u, "")
        uc["verdict"] = verdict
        kept = None
        if verdict == "verified":
            for r in calls:
                if r.get("outcome") == "written":
                    kept = r
        if kept is not None:
            pc = kept.get("program_chars", 0)
            share = max(0, pc - prev_chars) / pc if pc else 0.0
            if meta.get("patch"):
                share = 1.0 if pc else 0.0     # the reply is the unit itself, not the whole file again
            uc.update({"kept_out": kept.get("out", 0), "mandatory_share": round(share, 4), "mandatory_out": round(kept.get("out", 0) * share, 1)})
            kept_out += kept.get("out", 0)
            mandatory_out += kept.get("out", 0) * share
            kv = kept.get("out", 0) - kept.get("thinking", 0)
            kept_visible += kv
            mandatory_visible += kv * share
            prev_chars = pc
        else:
            uc.update({"kept_out": 0, "mandatory_share": 0.0, "mandatory_out": 0.0})
        uc["efficiency"] = round(uc["mandatory_out"] / uc["out"], 4) if uc["out"] else None
        uc["cost"] = round(uc["cost"], 6)
        per_unit[u] = uc
        think_total += uc["thinking"]
        if not known:
            uc["thinking"] = None
        for k in tot:
            tot[k] += uc[k]
        cost += uc["cost"]

    verified = sum(1 for v in verdicts.values() if v == "verified")
    result = {
        "provider": provider, "model": model, "project_verdict": project_verdict,
        "units_total": len(order) or len(unit_order), "units_verified": verified,
        "tokens": {**{k: tot[k] for k in ("in", "out", "cache_write", "cache_read")}, "thinking": think_total if known else None},
        "visible_out": (tot["out"] - think_total) if known else None,
        "thinking_share": round(think_total / tot["out"], 4) if known and tot["out"] else None,
        "efficiency_visible": round(mandatory_visible / (tot["out"] - think_total), 4) if known and tot["out"] - think_total > 0 else None,
        "calls": tot["calls"], "outcomes": outcomes, "agent_ms": tot["ms"], "seconds": meta.get("seconds"),
        "cost_usd": round(cost, 6) if price else None, "over_limit_calls": over_limit,
        "kept_out": kept_out,
        "efficiency_calls": round(kept_out / tot["out"], 4) if tot["out"] else None,
        "efficiency": round(mandatory_out / tot["out"], 4) if tot["out"] else None,
        "per_unit": per_unit,
    }
    if price and verified:
        result["cost_per_verified_unit"] = round(cost / verified, 6)
    audit = os.path.join(workdir, "audit.txt")
    if os.path.exists(audit):
        m = re.findall(r"(?:TOTAL|total)\s+(\d+)/(\d+)", open(audit, encoding="utf-8").read())
        if m:
            got, of = int(m[-1][0]), int(m[-1][1])
            result["audit"] = {"passed": got, "of": of}
            if price and got:
                result["cost_per_audit_point"] = round(cost / got, 8)
            if got:
                result["output_tokens_per_audit_point"] = round(tot["out"] / got, 2)
    return result

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("workdir")
    ap.add_argument("plan", nargs="?")
    ap.add_argument("--prices", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "prices.json"))
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    r = analyze(a.workdir, a.plan, a.prices)
    if a.json:
        print(json.dumps(r, indent=2))
        return
    print("verdict %s  units %d/%d  calls %d  outcomes %s" % (r["project_verdict"], r["units_verified"], r["units_total"], r["calls"], r["outcomes"]))
    print("tokens in %(in)d out %(out)d cache_write %(cache_write)d cache_read %(cache_read)d" % r["tokens"])
    if r["tokens"]["thinking"] is not None:
        print("thinking %d of %d output tokens (%.0f%%), visible %d; efficiency over visible tokens %s" % (r["tokens"]["thinking"], r["tokens"]["out"], 100 * r["thinking_share"], r["visible_out"], r["efficiency_visible"]))
    print("cost $%s  efficiency_calls %s  efficiency %s" % (r["cost_usd"], r["efficiency_calls"], r["efficiency"]))
    for u, x in r["per_unit"].items():
        print("  %-12s %-9s calls %d out %d cost $%.6f efficiency %s" % (u, x["verdict"], x["calls"], x["out"], x["cost"], x["efficiency"]))

if __name__ == "__main__":
    main()
