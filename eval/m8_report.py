#!/usr/bin/env python3
"""The M8 report (cancho-gpu docs/roadmap-models.md section 7): arms of a local model on the 13 hand-planned items, from the run directories `run_item.py` leaves.

    python3 eval/m8_report.py RUNS_DIR... [--arms A,B,...] [--json OUT.json] [--md OUT.md] [--boot 10000] [--seed 20261103]

Each RUNS_DIR holds `<arm>-<item>-<n>/` directories (the label is the arm: A, B, C, D, E). For each arm it reports, over its (item, run) observations:
  oracle pass fraction   passed/of of the hidden audit (0 when the run did not build); mean over the observations, and its 95% bootstrap interval (resampling observations with replacement)
  units verified         verified units / the plan's units; project verdicts
  attempts               `attempt` events of the journal, per run
  first-attempt compile  of the units tried, the share whose attempt 0 the compiler accepted (outcome `verified` or `acceptance_failed`)
  after the fix loop     of the units tried, the share that ended `verified` (compiler and the unit's examples)
  pass@1                 the share of units tried verified by attempt 0; "verified within 4" = by attempt 3 (the loop feeds the refusal back, so these attempts are not independent samples: not the unbiased pass@4)
  refusals               a tally of the signatures of non-verified attempts: the compiler's rule tag, `acceptance`, or `agent:gave-up:<why>`
and, when the arms needed are present, the pre-registered decision rule: C beats A iff mean(C)-mean(A) > h(A); D beats B iff mean(D)-mean(B) > h(B); D internalised iff mean(D) >= mean(A);
an arm whose mean is under 0.02 is floor-limited and its pair is also judged on the first-attempt compile rate, by the same half-width test.
Pure standard library (the bootstrap uses `random`); gate: scripts/test-m8-report.sh."""
import argparse, json, os, random, re, sys

FLOOR = 0.02


def load_events(wd):
    p = os.path.join(wd, "journal", "events.jsonl")
    ev = []
    if os.path.exists(p):
        for line in open(p, encoding="utf-8"):
            line = line.strip()
            if line:
                try:
                    ev.append(json.loads(line))
                except ValueError:
                    pass
    return ev


def run_stats(wd):
    """One run directory -> the numbers of one observation."""
    res = json.load(open(os.path.join(wd, "result.json")))
    au = res.get("audit") or {}
    passed, of = au.get("passed") or 0, au.get("of") or 0
    ev = load_events(wd)
    n_plan = res.get("units_total", 0)
    try:      # the plan's own count: metrics.py counts the units that got a verdict, and a unit skipped behind a stuck dependency has none
        n_plan = len(json.load(open(json.load(open(os.path.join(wd, "run.json")))["plan"]))["units"])
    except (OSError, ValueError, KeyError):
        pass
    units = {}      # unit -> {"attempts": [outcome...], "end": state}
    for e in ev:
        if e["kind"] == "unit_start":
            units.setdefault(e["unit"], {"outcomes": [], "end": None, "sigs": []})
        elif e["kind"] == "attempt":
            u = units.setdefault(e["unit"], {"outcomes": [], "end": None, "sigs": []})
            u["outcomes"].append(e["outcome"])
            u["sigs"].append(e.get("signature") or "")
        elif e["kind"] == "unit_end":
            units.setdefault(e["unit"], {"outcomes": [], "end": None, "sigs": []})["end"] = e["state"]
    tried = [u for u in units.values() if u["outcomes"]]
    first_ok = sum(1 for u in tried if u["outcomes"][0] in ("verified", "acceptance_failed"))
    p1 = sum(1 for u in tried if u["outcomes"][0] == "verified")
    w4 = sum(1 for u in tried if "verified" in u["outcomes"][:4])
    final = sum(1 for u in tried if u["end"] == "verified" or "verified" in u["outcomes"])
    tags = {}
    for u in tried:
        for o, s in zip(u["outcomes"], u["sigs"]):
            if o == "verified":
                continue
            tags[tag_of(o, s)] = tags.get(tag_of(o, s), 0) + 1
    return {"pass": (passed / of) if of else 0.0, "passed": passed, "of": of, "verdict": res.get("project_verdict") or "",
            "units_verified": res.get("units_verified", 0), "units_total": n_plan, "tried": len(tried),
            "attempts": sum(len(u["outcomes"]) for u in tried), "first_ok": first_ok, "pass1": p1, "within4": w4, "final": final, "tags": tags,
            "seconds": res.get("seconds"), "calls": res.get("calls")}


def tag_of(outcome, sig):
    if outcome == "refused":
        return sig.split(":", 1)[0] or "refused"
    if outcome == "acceptance_failed":
        return "acceptance"
    if sig.startswith("agent:gave-up:"):
        return sig
    return outcome + (":" + sig.split(":", 1)[0] if sig else "")


def mean(xs):
    return sum(xs) / len(xs) if xs else float("nan")


def boot_ci(xs, n, rng):
    """(mean, lo, hi, half width) of the percentile 95% interval of the mean of xs."""
    if not xs:
        return (float("nan"),) * 4
    m = []
    k = len(xs)
    for _ in range(n):
        m.append(sum(xs[rng.randrange(k)] for _ in range(k)) / k)
    m.sort()
    lo, hi = m[int(0.025 * n)], m[min(n - 1, int(0.975 * n))]
    return mean(xs), lo, hi, (hi - lo) / 2


def summarize(rows, n_boot, seed):
    rng = random.Random(seed)
    tried = sum(r["tried"] for r in rows)
    out = {"runs": len(rows)}
    xs = [r["pass"] for r in rows]
    out["pass_mean"], out["pass_lo"], out["pass_hi"], out["pass_h"] = boot_ci(xs, n_boot, rng)
    comp = [(r["first_ok"] / r["tried"]) if r["tried"] else 0.0 for r in rows]
    out["compile1_run_mean"], out["compile1_lo"], out["compile1_hi"], out["compile1_h"] = boot_ci(comp, n_boot, rng)
    out["units_verified"] = sum(r["units_verified"] for r in rows)
    out["units_total"] = sum(r["units_total"] for r in rows)
    out["units_tried"] = tried
    out["attempts"] = sum(r["attempts"] for r in rows)
    out["attempts_per_run"] = out["attempts"] / len(rows) if rows else float("nan")
    out["first_attempt_compile"] = sum(r["first_ok"] for r in rows) / tried if tried else float("nan")
    out["after_loop_verified"] = sum(r["final"] for r in rows) / tried if tried else float("nan")
    out["pass_at_1"] = sum(r["pass1"] for r in rows) / tried if tried else float("nan")
    out["verified_within_4"] = sum(r["within4"] for r in rows) / tried if tried else float("nan")
    out["verdicts"] = {}
    out["tags"] = {}
    for r in rows:
        out["verdicts"][r["verdict"] or "?"] = out["verdicts"].get(r["verdict"] or "?", 0) + 1
        for t, c in r["tags"].items():
            out["tags"][t] = out["tags"].get(t, 0) + c
    return out


def decide(S):
    """The pre-registered rule over the arm summaries `S` (dict arm -> summary)."""
    d = {}
    def need(*a):
        return all(x in S and S[x]["runs"] for x in a)
    for tuned, base in (("C", "A"), ("D", "B")):
        if need(tuned, base):
            diff = S[tuned]["pass_mean"] - S[base]["pass_mean"]
            h = S[base]["pass_h"]
            e = {"diff": diff, "h_base": h, "beats": diff > h, "base_floor": S[base]["pass_mean"] < FLOOR}
            if e["base_floor"]:
                cd = S[tuned]["compile1_run_mean"] - S[base]["compile1_run_mean"]
                e.update({"compile1_diff": cd, "compile1_h_base": S[base]["compile1_h"], "compile1_beats": cd > S[base]["compile1_h"]})
            d["%s_vs_%s" % (tuned, base)] = e
    if need("D", "A"):
        d["D_internalised"] = S["D"]["pass_mean"] >= S["A"]["pass_mean"]
    return d


def markdown(S, per_item, decision, items):
    L = []
    L.append("| arm | runs | oracle pass (95% CI) | units verified | verdicts | first-attempt compile | after the fix loop | pass@1 | verified within 4 | attempts/run |")
    L.append("|---|---|---|---|---|---|---|---|---|---|")
    for a, s in S.items():
        L.append("| %s | %d | %.3f (%.3f to %.3f; h %.3f) | %d/%d | %s | %.3f | %.3f | %.3f | %.3f | %.1f |" % (
            a, s["runs"], s["pass_mean"], s["pass_lo"], s["pass_hi"], s["pass_h"], s["units_verified"], s["units_total"],
            ", ".join("%s %d" % kv for kv in sorted(s["verdicts"].items())), s["first_attempt_compile"], s["after_loop_verified"], s["pass_at_1"],
            s["verified_within_4"], s["attempts_per_run"]))
    L.append("")
    L.append("Per item (oracle pass fraction, mean over runs; units verified / units total over runs):")
    L.append("")
    L.append("| item | " + " | ".join(S) + " |")
    L.append("|---|" + "---|" * len(S))
    for it in items:
        cells = []
        for a in S:
            rs = per_item.get(a, {}).get(it, [])
            cells.append("%.3f (%d/%d)" % (mean([r["pass"] for r in rs]), sum(r["units_verified"] for r in rs), sum(r["units_total"] for r in rs)) if rs else "-")
        L.append("| %s | %s |" % (it, " | ".join(cells)))
    L.append("")
    for a, s in S.items():
        top = sorted(s["tags"].items(), key=lambda kv: -kv[1])[:12]
        L.append("Refusal tags of arm %s (non-verified attempts): %s" % (a, ", ".join("%s %d" % kv for kv in top) or "none"))
    L.append("")
    if decision:
        L.append("Decision rule: " + json.dumps(decision))
    return "\n".join(L) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("runs", nargs="+")
    ap.add_argument("--arms")
    ap.add_argument("--json")
    ap.add_argument("--md")
    ap.add_argument("--boot", type=int, default=10000)
    ap.add_argument("--seed", type=int, default=20261103)
    a = ap.parse_args()
    arms = {}
    per_item = {}
    dirs = sorted((os.path.join(r, d) for r in a.runs for d in os.listdir(r)), key=os.path.basename)
    for wd in dirs:
        d = os.path.basename(wd)
        m = re.match(r"^([A-Z])-([a-z0-9_]+)-(\d+)$", d)
        if not m or not os.path.exists(os.path.join(wd, "result.json")):
            continue
        arm, item = m.group(1), m.group(2)
        r = run_stats(wd)
        r["item"], r["run"] = item, int(m.group(3))
        arms.setdefault(arm, []).append(r)
        per_item.setdefault(arm, {}).setdefault(item, []).append(r)
    want = a.arms.split(",") if a.arms else sorted(arms)
    S = {k: summarize(arms[k], a.boot, a.seed) for k in want if k in arms}
    items = sorted({r["item"] for k in arms for r in arms[k]})
    dec = decide(S)
    out = {"arms": S, "decision": dec, "items": items, "per_item": {k: {i: {"pass": mean([r["pass"] for r in rs]), "runs": len(rs), "units_verified": sum(r["units_verified"] for r in rs),
                                                                              "units_total": sum(r["units_total"] for r in rs)} for i, rs in v.items()} for k, v in per_item.items()},
           "runs": {k: [{kk: vv for kk, vv in r.items()} for r in v] for k, v in arms.items()}}
    if a.json:
        json.dump(out, open(a.json, "w"), indent=1)
    text = markdown(S, per_item, dec, items)
    if a.md:
        open(a.md, "w").write(text)
    print(text)


if __name__ == "__main__":
    main()
