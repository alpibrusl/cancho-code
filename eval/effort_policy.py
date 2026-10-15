#!/usr/bin/env python3
"""Give every unit of a plan an `effort` by a policy (docs/plan.md): how hard the model should think about that unit.

    python3 eval/effort_policy.py <policy> <plan.json> <out.json>

policies:
  low       every unit low
  medium    every unit medium
  tiered    by what the unit asks of the model, from things a plan already holds: description under 500 characters -> low; under 900 -> medium;
            longer, or a function that returns a list/vec/Result of those, or any unit that depends on three or more others -> no effort (the model's own default)
  none      no effort anywhere (the control)
The tiers were chosen from the measured thinking per unit (eval/results/2026-10-17-edit-mode.md: thinking tracks description length, r = 0.72), not tuned on the outcome."""
import json, sys

def tier(u):
    d = len(u.get("description", ""))
    ret = u["signature"].split("->", 1)[1] if "->" in u["signature"] else ""
    heavy = "list." in ret or "vec." in ret
    if heavy or d >= 900 or len(u.get("deps", [])) >= 3:
        return None
    return "low" if d < 500 else "medium"

def main():
    policy, src, dst = sys.argv[1:4]
    plan = json.load(open(src))
    for u in plan["units"]:
        u.pop("effort", None)
        e = {"low": "low", "medium": "medium", "none": None}.get(policy) if policy != "tiered" else tier(u)
        if e: u["effort"] = e
    json.dump(plan, open(dst, "w"), indent=1)
    counts = {}
    for u in plan["units"]:
        counts[u.get("effort", "default")] = counts.get(u.get("effort", "default"), 0) + 1
    print(policy, counts)

if __name__ == "__main__":
    main()
