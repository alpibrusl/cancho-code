#!/usr/bin/env python3
"""Summarise runs of the `users` service (eval/run_service_plan.py users ...): per run the verdict, units, attack score, calls, tokens, cost, and how the
application used the two libraries, read from the run's raw replies (raw.txt) and trail.

    python3 eval/report_libs.py <runs dir> <label> [<label> ...] [--json out.json]

For every reply of the application unit: the `web.<name>` / `schema.<name>` calls it makes, split into REAL (a `pub fn` of the vendored libraries,
eval/libs) and INVENTED (not one: the compiler refuses the program), whether it calls dispatch and validate at all, and whether it writes an OpenAPI
document by hand (a string literal containing "openapi") instead of calling web.openapi. The trail gives the first line of each refusal."""
import glob, json, os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))

def real_names():
    out = {}
    for mod, path in (("schema", "libs/cancho-schema/src/schema.cho"), ("web", "libs/cancho-web/src/web.cho")):
        out[mod] = set(re.findall(r"^pub (?:res )?(?:fn|struct) (\w+)", open(os.path.join(HERE, path)).read(), re.M))
    return out

def replies(raw):
    parts = re.split(r"^=== reply \(.*\)\n", raw, flags=re.M)[1:]
    return parts

def analyze(wd, real):
    r = json.load(open(os.path.join(wd, "result.json")))
    raw = open(os.path.join(wd, "raw.txt")).read() if os.path.exists(os.path.join(wd, "raw.txt")) else ""
    reps = [p for p in replies(raw) if "app_handle" in p or "struct App" in p]
    used, invented = {}, {}
    for p in reps:
        for mod, name in re.findall(r"\b(web|schema)\.([a-z_]+)\s*\(", p):
            (used if name in real[mod] else invented).setdefault("%s.%s" % (mod, name), 0)
            d = used if name in real[mod] else invented
            d["%s.%s" % (mod, name)] += 1
    last = reps[-1] if reps else ""
    trail = []
    tp = os.path.join(wd, "trail-app.jsonl")
    if os.path.exists(tp):
        for l in open(tp):
            try: trail.append(json.loads(l))
            except Exception: pass
    return {
        "run": os.path.basename(wd), "verdict": r.get("project_verdict"), "units": "%s/%s" % (r.get("units_verified"), r.get("units_total")),
        "attack": ("%d/%d" % (r["attack"]["passed"], r["attack"]["of"])) if r.get("attack") else None,
        "calls": r.get("calls"), "out_tokens": r["tokens"]["out"], "thinking_tokens": r["tokens"]["thinking"], "in_tokens": r["tokens"]["in"] + r["tokens"]["cache_read"] + r["tokens"]["cache_write"],
        "cost_usd": r.get("cost_usd"), "seconds": r.get("seconds"),
        "app_replies": len(reps), "app_attempts": [{"outcome": t.get("outcome"), "sig": (t.get("sig") or "")[:110]} for t in trail],
        "real_calls": used, "invented_calls": invented,
        "last_reply_calls_dispatch": "web.dispatch(" in last, "last_reply_calls_validate": "schema.validate(" in last, "last_reply_calls_openapi": "web.openapi(" in last,
        "any_reply_calls_dispatch": any("web.dispatch(" in p for p in reps), "any_reply_calls_validate": any("schema.validate(" in p for p in reps), "any_reply_calls_openapi": any("web.openapi(" in p for p in reps),
        "any_reply_hand_written_openapi": any('\\"openapi\\"' in p for p in reps),
    }

def main():
    args = [a for a in sys.argv[1:]]
    jout = None
    if "--json" in args:
        i = args.index("--json"); jout = args[i + 1]; del args[i:i + 2]
    base, labels = args[0], args[1:]
    real = real_names()
    allr = {}
    for lab in labels:
        rows = [analyze(wd, real) for wd in sorted(glob.glob(os.path.join(base, "%s-users-*" % lab))) if os.path.exists(os.path.join(wd, "result.json"))]
        allr[lab] = rows
        print("## arm %s: %d runs" % (lab, len(rows)))
        for x in rows:
            print("- %s: %s, units %s, attack %s, calls %s, out %s (thinking %s), cost $%s, %ss; app replies %d; in some reply: dispatch %s validate %s openapi() %s hand-written doc %s; invented: %s" % (
                x["run"], x["verdict"], x["units"], x["attack"], x["calls"], x["out_tokens"], x["thinking_tokens"], x["cost_usd"], x["seconds"], x["app_replies"],
                x["any_reply_calls_dispatch"], x["any_reply_calls_validate"], x["any_reply_calls_openapi"], x["any_reply_hand_written_openapi"], sorted(x["invented_calls"]) or "none"))
        print("  total cost $%.4f" % sum(x["cost_usd"] or 0 for x in rows))
    if jout: json.dump(allr, open(jout, "w"), indent=1)

if __name__ == "__main__":
    main()
