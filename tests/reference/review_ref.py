#!/usr/bin/env python3
"""Reference for src/review.cho: the oracle of scripts/test-review.sh.

    review_ref.py blind PLAN.json                new questions on stdout
    review_ref.py apply PLAN.json ANSWERS.json   new plan on stdout, report on stderr, exit 0 (usable) or 1

The BLIND PASS (docs/plan.md, "review"): a second model re-derives each expected value of the planner's `cases` from the unit's
description alone. `blind` builds its questions: {"units":[{"id","signature","description","cases":[{"args":[...]}]}]} for every unit
with a non-empty `cases` list, in plan order, with no `expect`, no `examples`, no `tests`, no `deps`. A plan that is not JSON, has no
`units` list or is nested deeper than 55 levels gives {"units":[]}.

`apply` keeps a case iff the reviewer's answer for it is {"expect": V} and V equals the planner's `expect`. Equality: null = null;
booleans by value; integers numerically (1 is not 1.0: a float is another answer; two floats by value); a text is a JSON string or a
{"bytes": [0..255,...]} and two texts are equal iff their bytes are (so {"bytes":[104,105]} equals "hi"); arrays element by element;
objects by keys and values; and {"err": x}: equal iff both x are the same integer or neither is an integer (the error payload is
only compared when it is an integer, as cases.expand does).
"""
import json
import re
import sys

MAX_DEPTH = 55


class Raw(str):
    """A number kept as written."""


def loads(text):
    def bad(_):
        raise ValueError("constant")
    return json.loads(text, parse_int=Raw, parse_float=Raw, parse_constant=bad)


def dump(v):
    if v is None:
        return "null"
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, Raw):
        return str(v)
    if isinstance(v, str):
        return json.dumps(v, ensure_ascii=False)
    if isinstance(v, list):
        return "[" + ",".join(dump(x) for x in v) + "]"
    return "{" + ",".join(json.dumps(k, ensure_ascii=False) + ":" + dump(x) for k, x in v.items()) + "}"


def depth_of(v):
    if isinstance(v, dict):
        return 1 + max([depth_of(x) for x in v.values()] + [0])
    if isinstance(v, list):
        return 1 + max([depth_of(x) for x in v] + [0])
    return 0


INT_RE = re.compile(r"^-?[0-9]+$")


def is_int(v):
    return isinstance(v, Raw) and INT_RE.match(v) is not None


def is_float(v):
    return isinstance(v, Raw) and INT_RE.match(v) is None


def text_bytes(v):
    """The bytes of a text value (a string, or {"bytes": [...]} that is well formed), else None."""
    if isinstance(v, str) and not isinstance(v, Raw):
        return v.encode("utf-8")
    if isinstance(v, dict) and len(v) == 1 and "bytes" in v:
        lst = v["bytes"]
        if isinstance(lst, list) and all(is_int(x) and 0 <= int(x) <= 255 for x in lst):
            return bytes(int(x) for x in lst)
    return None


def int_fits(v):
    return -(1 << 63) <= int(v) <= (1 << 63) - 1


def equal(a, b):
    ta, tb = text_bytes(a), text_bytes(b)
    if ta is not None or tb is not None:
        return ta is not None and tb is not None and ta == tb
    if a is None or b is None:
        return a is None and b is None
    if isinstance(a, bool) or isinstance(b, bool):
        return isinstance(a, bool) and isinstance(b, bool) and a == b
    if isinstance(a, Raw) or isinstance(b, Raw):
        if not (isinstance(a, Raw) and isinstance(b, Raw)):
            return False
        if is_int(a) != is_int(b):
            return False
        return int(a) == int(b) if is_int(a) else float(a) == float(b)
    if isinstance(a, list) or isinstance(b, list):
        return isinstance(a, list) and isinstance(b, list) and len(a) == len(b) and all(equal(x, y) for x, y in zip(a, b))
    if isinstance(a, dict) and isinstance(b, dict):
        if len(a) == 1 and len(b) == 1 and "err" in a and "err" in b:
            x, y = a["err"], b["err"]
            if is_int(x) or is_int(y):
                return is_int(x) and is_int(y) and int(x) == int(y)
            return True
        return a.keys() == b.keys() and all(equal(a[k], b[k]) for k in a)
    return False


def reviewable(u):
    return isinstance(u, dict) and isinstance(u.get("cases"), list) and len(u["cases"]) > 0


def parse_plan(text):
    try:
        plan = loads(text)
    except ValueError:
        return None
    if not (isinstance(plan, dict) and isinstance(plan.get("units"), list)) or depth_of(plan) > MAX_DEPTH:
        return None
    return plan


def blind(text):
    plan = parse_plan(text)
    units = []
    if plan is not None:
        for u in plan["units"]:
            if not reviewable(u):
                continue
            q = {}
            for k in ("id", "signature", "description"):
                if k in u:
                    q[k] = u[k]
            q["cases"] = [({"args": c["args"]} if isinstance(c, dict) and "args" in c else {}) for c in u["cases"]]
            units.append(q)
    return dump({"units": units})


def apply(plan_text, ans_text):
    """(new plan text, report lines, code)"""
    plan = parse_plan(plan_text)
    if plan is None:
        return plan_text, ["[REVIEW_ERROR]\t-\t-\tthe plan is not a JSON object with a units list"], 1
    try:
        ans = loads(ans_text)
    except ValueError:
        ans = None
    if not (isinstance(ans, dict) and isinstance(ans.get("units"), list)) or depth_of(ans) > MAX_DEPTH:
        return plan_text, ['[REVIEW_ERROR]\t-\t-\tthe answers are not a JSON object with a "units" list'], 1
    report = []
    errors = False
    kept_total = 0
    all_total = 0
    new_units = []
    for u in plan["units"]:
        if not reviewable(u):
            new_units.append(u)
            continue
        uid = u.get("id")
        who = uid if isinstance(uid, str) else "-"
        cases = u["cases"]
        au = None
        if isinstance(uid, str):
            for x in ans["units"]:
                if isinstance(x, dict) and isinstance(x.get("id"), str) and x["id"] == uid:
                    au = x
                    break
        if au is None:
            report.append("[REVIEW_ERROR]\t%s\t-\tthe reviewer gave no answers for this unit" % who)
            errors = True
            new_units.append(u)
            continue
        al = au.get("answers")
        if not isinstance(al, list) or len(al) != len(cases):
            n = len(al) if isinstance(al, list) else 0
            report.append("[REVIEW_ERROR]\t%s\t-\tthe reviewer gave %d answers for %d cases" % (who, n, len(cases)))
            errors = True
            new_units.append(u)
            continue
        bad = False
        for k, a in enumerate(al, 1):
            if not (isinstance(a, dict) and len(a) == 1 and ("expect" in a or a.get("skip") is True)):
                report.append("[REVIEW_ERROR]\t%s\t-\tanswer %d is neither {\"expect\": ...} nor {\"skip\": true}" % (who, k))
                bad = True
        if bad:
            errors = True
            new_units.append(u)
            continue
        kept = []
        for k, (c, a) in enumerate(zip(cases, al), 1):
            planner = c["expect"] if isinstance(c, dict) and "expect" in c else None
            ok = "expect" in a and equal(planner, a["expect"])
            if ok:
                kept.append(c)
            else:
                rev = dump(a["expect"]) if "expect" in a else "skip"
                report.append("[REVIEW_DROPPED]\t%s\t%d\tplanner %s reviewer %s" % (who, k, dump(planner), rev))
        all_total += len(cases)
        kept_total += len(kept)
        if not kept and not (isinstance(u.get("tests"), list) and len(u["tests"]) > 0):
            report.append("[REVIEW_ERROR]\t%s\t-\tthe reviewer agreed with none of the %d cases: the description may be unclear or the cases wrong" % (who, len(cases)))
            errors = True
        new_units.append(dict(u, cases=kept))
    report.append("[REVIEW]\tkept %d of %d cases" % (kept_total, all_total))
    if errors:
        return plan_text, report, 1
    plan["units"] = new_units
    return dump(plan), report, 0


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "blind":
        sys.stdout.write(blind(open(sys.argv[2], "rb").read().decode("utf-8")))
        return 0
    if len(sys.argv) == 4 and sys.argv[1] == "apply":
        new, report, code = apply(open(sys.argv[2], "rb").read().decode("utf-8"), open(sys.argv[3], "rb").read().decode("utf-8"))
        sys.stdout.write(new)
        sys.stdout.flush()
        for line in report:
            sys.stderr.write(line + "\n")
        return code
    sys.stderr.write("usage: review_ref.py blind PLAN | apply PLAN ANSWERS\n")
    return 2


if __name__ == "__main__":
    sys.exit(main())
