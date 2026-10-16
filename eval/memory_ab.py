#!/usr/bin/env python3
"""The A/B of the memory (docs/memory.md): the 13 items, brief only, with and without `--memory`, the memory of an item mined ONLY from runs of other items.

    CANCHO=<compiler> python3 eval/memory_ab.py run   <arm label> <runs> <out> [--memory-root <dir>] [--jobs 4]   # eval/run_build.py on every item
    python3 eval/memory_ab.py mine <memory root> <out> <arm out dir>...                                         # leave-one-item-out: <memory root>/<item>/lessons.jsonl
    python3 eval/memory_ab.py report <out> <a label> <b label> <result file stem> [--spent <usd of the runs before>]

`run` calls eval/run_build.py once per item (several items at a time); the Python here is the harness (bookkeeping and the table), the build, the miner and the
agent are cancho. `mine` runs scripts/cancho-lessons.sh on the journals of every item but one. `report` reads the run directories (result.json from the
metrics, journal/events.jsonl for the attempts and the memory field) and writes eval/results/<stem>.json and .md."""
import argparse, concurrent.futures, glob, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
ITEMS = "base64 basics csv duration editdistance expr glob ini jsonptr roman semver sortedmap tokenbucket".split()


def run_item(a, item):
    cmd = [sys.executable, os.path.join(HERE, "run_build.py"), item, "--provider", "anthropic", "--model", "claude-haiku-5-5",
           "--key-file", os.path.expanduser("~/.config/cancho-code/anthropic.key"), "--workspace", a.workspace, "--primer", a.primer,
           "--runs", str(a.runs), "--label", a.label, "--out", a.out]
    if a.memory_root:
        cmd += ["--memory", os.path.join(a.memory_root, item)]
    p = subprocess.run(cmd, capture_output=True, text=True)
    return item, p.stdout.strip() + (("\n" + p.stderr.strip()) if p.returncode else "")


def cmd_run(a):
    os.makedirs(a.out, exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(a.jobs) as ex:
        for item, out in ex.map(lambda i: run_item(a, i), ITEMS):
            print(out, flush=True)


def item_of(path):
    m = re.match(r"^.*?-(%s)-\d+$" % "|".join(ITEMS), os.path.basename(path.rstrip("/")))
    return m.group(1) if m else None


def cmd_mine(a):
    runs = []
    for d in a.dirs:
        runs += [p for p in sorted(glob.glob(os.path.join(d, "*"))) if os.path.exists(os.path.join(p, "journal", "events.jsonl"))]
    for item in ITEMS:
        mem = os.path.join(a.root, item)
        os.makedirs(mem, exist_ok=True)
        keep = [r for r in runs if item_of(r) != item]
        p = subprocess.run([os.path.join(ROOT, "scripts", "cancho-lessons.sh"), "--memory", mem] + keep, capture_output=True, text=True)
        print("%s: %d runs mined, %s" % (item, len(keep), p.stderr.strip().splitlines()[-1] if p.stderr.strip() else p.returncode))
        assert not any(item_of(r) == item for r in keep)


def events(rd):
    out = []
    try:
        for l in open(os.path.join(rd, "journal", "events.jsonl")):
            try: out.append(json.loads(l))
            except ValueError: pass
    except OSError:
        pass
    return out


def analyse(rd):
    r = json.load(open(os.path.join(rd, "result.json")))
    ev = events(rd)
    att = [e for e in ev if e.get("kind") == "attempt" and e.get("outcome") != "human_patch"]
    units = {e["unit"] for e in ev if e.get("kind") == "unit_start"}
    audit = r.get("audit") or {}
    recalled = [e for e in att if any(str(m.get("id", "")).startswith("L") for m in e.get("memory", []) if isinstance(m, dict))]
    refused = [e for e in att if e.get("outcome") in ("refused", "acceptance_failed")]
    return {"run": os.path.basename(rd), "item": item_of(rd), "verdict": next((e.get("verdict") for e in ev if e.get("kind") == "run_end"), None),
            "units": len(units), "units_verified": r.get("units_verified"), "units_total": r.get("units_total"),
            "audit_passed": audit.get("passed"), "audit_of": audit.get("of"), "attempts": len(att), "refused": len(refused),
            "recalled": len(recalled), "recalled_verified": sum(1 for e in recalled if e.get("outcome") == "verified"),
            "calls": r.get("calls"), "cost_usd": r.get("cost_usd")}


def summary(rows):
    n = len(rows)
    units = sum(r["units"] for r in rows)
    att = sum(r["attempts"] for r in rows)
    return {"runs": n, "done": sum(1 for r in rows if r["verdict"] == "done"),
            "fully_right": sum(1 for r in rows if r["audit_of"] and r["audit_passed"] == r["audit_of"]),
            "units": units, "attempts": att, "attempts_per_unit": round(att / units, 3) if units else None,
            "refused_attempts": sum(r["refused"] for r in rows), "recalled_attempts": sum(r["recalled"] for r in rows),
            "recalled_verified": sum(r["recalled_verified"] for r in rows), "calls": sum(r["calls"] or 0 for r in rows),
            "cost_usd": round(sum(r["cost_usd"] or 0 for r in rows), 4),
            "audit_cases": "%d/%d" % (sum(r["audit_passed"] or 0 for r in rows), sum(r["audit_of"] or 0 for r in rows))}


def cmd_report(a):
    arms = {}
    for label in (a.a, a.b):
        arms[label] = [analyse(d) for d in sorted(glob.glob(os.path.join(a.out, "*", "%s-*" % label))) if os.path.exists(os.path.join(d, "result.json"))]
        if not arms[label]:
            arms[label] = [analyse(d) for d in sorted(glob.glob(os.path.join(a.out, "%s-*" % label))) if os.path.exists(os.path.join(d, "result.json"))]
    res = {"arms": {k: {"summary": summary(v), "runs": v} for k, v in arms.items()}, "a": a.a, "b": a.b, "spent_before_usd": a.spent}
    os.makedirs(os.path.join(ROOT, "eval", "results"), exist_ok=True)
    json.dump(res, open(os.path.join(ROOT, "eval", "results", a.stem + ".json"), "w"), indent=1)
    print(json.dumps({k: v["summary"] for k, v in res["arms"].items()}, indent=1))


def main():
    ap = argparse.ArgumentParser(); sp = ap.add_subparsers(dest="cmd", required=True)
    r = sp.add_parser("run"); r.add_argument("label"); r.add_argument("runs", type=int); r.add_argument("out")
    r.add_argument("--memory-root"); r.add_argument("--jobs", type=int, default=4)
    r.add_argument("--workspace", default="wrkspc_01NnYYkfhp6fKLUr8B6UXnfX"); r.add_argument("--primer", required=True)
    m = sp.add_parser("mine"); m.add_argument("root"); m.add_argument("dirs", nargs="+")
    p = sp.add_parser("report"); p.add_argument("out"); p.add_argument("a"); p.add_argument("b"); p.add_argument("stem"); p.add_argument("--spent", type=float, default=0.0)
    a = ap.parse_args()
    {"run": cmd_run, "mine": cmd_mine, "report": cmd_report}[a.cmd](a)


main()
