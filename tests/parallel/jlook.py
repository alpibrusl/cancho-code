#!/usr/bin/env python3
"""Reads a run's journal for scripts/test-parallel.sh (standard library only).

    jlook.py WORKDIR maxconc            the most units that were in flight at once (unit_start .. unit_end), as a number
    jlook.py WORKDIR sumspans           the sum of the units' durations in ms, and the wall time from the first start to the last end, "SUM WALL"
    jlook.py WORKDIR before X Y         exit 0 when unit X had ended (its last unit_end) before unit Y started (its first unit_start)
    jlook.py WORKDIR gap X Y            the ms from X's first start to Y's first start
    jlook.py WORKDIR starts             "unit:t_ms-of-first-start-relative-to-the-first-event ..." in start order
    jlook.py WORKDIR lanes              "unit=lane ..." for the attempt events, in order, of the units that have one
    jlook.py WORKDIR whole              exit 0 when every line is a JSON object with t_ms and kind, and t_ms never goes back
    jlook.py WORKDIR kinds              the kinds in order, one line
    jlook.py WORKDIR integrate          "unit:mode:ok ..." for the integrate events, in order
"""
import json
import sys

wd, cmd = sys.argv[1], sys.argv[2]
events = []
for line in open(wd + "/journal/events.jsonl"):
    events.append(json.loads(line))

spans = {}
for e in events:
    if e["kind"] == "unit_start":
        spans.setdefault(e["unit"], []).append([e["t_ms"], None])
    elif e["kind"] == "unit_end":
        for s in spans.get(e["unit"], []):
            if s[1] is None:
                s[1] = e["t_ms"]
                break

if cmd == "maxconc":
    points = []
    for u, ss in spans.items():
        for s in ss:
            if s[1] is not None:
                points.append((s[0], 1))
                points.append((s[1], -1))
    points.sort(key=lambda p: (p[0], p[1]))
    cur = best = 0
    for _, d in points:
        cur += d
        best = max(best, cur)
    print(best)
elif cmd == "sumspans":
    total = sum(s[1] - s[0] for ss in spans.values() for s in ss if s[1] is not None)
    starts = [s[0] for ss in spans.values() for s in ss]
    ends = [s[1] for ss in spans.values() for s in ss if s[1] is not None]
    print(total, max(ends) - min(starts))
elif cmd == "before":
    x, y = sys.argv[3], sys.argv[4]
    xe = max(s[1] for s in spans[x] if s[1] is not None)
    ys = min(s[0] for s in spans[y])
    sys.exit(0 if xe <= ys else 1)
elif cmd == "gap":
    x, y = sys.argv[3], sys.argv[4]
    print(min(s[0] for s in spans[y]) - min(s[0] for s in spans[x]))
elif cmd == "starts":
    base = events[0]["t_ms"]
    firsts = sorted((min(s[0] for s in ss), u) for u, ss in spans.items())
    print(" ".join("%s:%d" % (u, t - base) for t, u in firsts))
elif cmd == "lanes":
    print(" ".join("%s=%d" % (e["unit"], e["lane"]) for e in events if e["kind"] == "attempt" and "lane" in e))
elif cmd == "whole":
    last = 0
    for e in events:
        if not isinstance(e.get("t_ms"), int) or "kind" not in e or e["t_ms"] < last:
            sys.exit(1)
        last = e["t_ms"]
elif cmd == "kinds":
    print(" ".join(e["kind"] for e in events))
elif cmd == "integrate":
    print(" ".join("%s:%s:%s" % (e["unit"], e["mode"], "ok" if e["ok"] else "no") for e in events if e["kind"] == "integrate"))
