#!/usr/bin/env python3
"""Aggregate result.json files (from eval/run_item.py) into a table by item and a total.

    python3 eval/report.py <dir-with-runs> [--catalog eval/tasks.json]

One row per item: runs, done, units verified, audit points, calls, tokens (in/out/cache), cost, efficiency, seconds; then the totals. With a
catalog (eval/tasks.json) each item also shows its difficulty level."""
import glob, json, os, sys

def main():
    base = sys.argv[1]
    cat = {}
    if "--catalog" in sys.argv:
        for t in json.load(open(sys.argv[sys.argv.index("--catalog") + 1]))["tasks"]:
            cat[t["id"]] = t
    rows = {}
    for f in sorted(glob.glob(os.path.join(base, "*", "result.json"))):
        r = json.load(open(f))
        rows.setdefault(r["item"], []).append(r)
    def agg(rs):
        n = len(rs)
        s = lambda k: sum(x[k] for x in rs)
        tk = lambda k: sum(x["tokens"][k] for x in rs)
        pts = sum(x.get("audit", {}).get("passed", 0) for x in rs)
        of = sum(x.get("audit", {}).get("of", 0) for x in rs)
        cost = sum(x["cost_usd"] or 0 for x in rs)
        eff = [x["efficiency"] for x in rs if x["efficiency"] is not None]
        return dict(n=n, done=sum(1 for x in rs if x["project_verdict"] == "done"), uv=s("units_verified"), ut=s("units_total"), pts=pts, of=of,
                    calls=s("calls"), tin=tk("in"), tout=tk("out"), cw=tk("cache_write"), cr=tk("cache_read"), cost=cost,
                    eff=sum(eff) / len(eff) if eff else None, secs=sum((x["seconds"] or 0) for x in rs) / n)
    head = "%-14s %3s %5s %6s %9s %5s %8s %8s %8s %9s %6s %5s"
    print(head % ("item", "lvl", "runs", "done", "audit", "calls", "in", "out", "cache_r", "cost USD", "eff", "secs"))
    tot = []
    for item in sorted(rows):
        a = agg(rows[item]); tot += rows[item]
        print(head % (item, cat.get(item, {}).get("level", "?"), a["n"], "%d/%d" % (a["done"], a["n"]), "%d/%d" % (a["pts"], a["of"]), a["calls"], a["tin"],
                      a["tout"], a["cr"], "%.4f" % a["cost"], "-" if a["eff"] is None else "%.3f" % a["eff"], "%.0f" % a["secs"]))
    if tot:
        a = agg(tot)
        print(head % ("TOTAL", "", a["n"], "%d/%d" % (a["done"], a["n"]), "%d/%d" % (a["pts"], a["of"]), a["calls"], a["tin"], a["tout"], a["cr"],
                      "%.4f" % a["cost"], "-" if a["eff"] is None else "%.3f" % a["eff"], "%.0f" % a["secs"]))
        if a["pts"]:
            print("cost per audit point $%.6f   output tokens per audit point %.1f" % (a["cost"] / a["pts"], a["tout"] / a["pts"]))
if __name__ == "__main__":
    main()
