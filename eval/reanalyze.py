#!/usr/bin/env python3
"""Recompute result.json in every run directory under <dir> from what the runs left (usage.jsonl, run.log, run.json, audit.txt): after a change to
eval/metrics.py, so old runs are read with the current definitions.   python3 eval/reanalyze.py <dir>"""
import glob, json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE)
import metrics
for rj in sorted(glob.glob(os.path.join(sys.argv[1], "*", "run.json"))):
    wd = os.path.dirname(rj); meta = json.load(open(rj))
    r = metrics.analyze(wd, None, os.path.join(HERE, "prices.json"))
    r.update({"item": meta["item"], "run": meta["run"], "exit": meta["exit"]})
    json.dump(r, open(os.path.join(wd, "result.json"), "w"), indent=1)
