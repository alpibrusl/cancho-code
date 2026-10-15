#!/bin/sh
# The metrics gate: eval/metrics.py on a run directory made by hand, every expected number computed here on paper (comments), not by the
# code under test. Cases:
#   tokens, cost    sums; cost = tokens x price / 1e6 per category; a prompt over the model's limit is priced at the higher tier and counted
#   kept            the last `written` call of a VERIFIED unit; nothing is kept for a unit that did not verify
#   efficiency      kept output / all output; times the mandatory share (growth of the program over the previous kept program) for `efficiency`
#   audit           cost and output tokens per audit point when audit.txt has a TOTAL line
#   absent          an empty directory is an empty report, not a crash
set -u
command -v python3 >/dev/null 2>&1 || { echo "no python3 on PATH" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
python3 -I - "$root" <<'PY'
import json, os, sys, tempfile
root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "eval"))
import metrics

fails = 0
def check(name, got, want):
    global fails
    if got != want:
        fails += 1
        print("FAIL: %s: wanted %r, got %r" % (name, want, got), file=sys.stderr)

d = tempfile.mkdtemp(prefix="cc-metrics-")
prices = os.path.join(d, "prices.json")
json.dump({"anthropic": {"m": {"prompt_limit": 1000, "in": 1.0, "cache_write": 1.25, "cache_read": 0.1, "out": 5.0,
                                "over_limit_prices": {"in": 2.0, "cache_write": 2.5, "cache_read": 0.2, "out": 10.0}}}}, open(prices, "w"))

def call(task, outcome, tin, tout, cw, cr, pc, ms=1000, think=None):
    r = {"provider": "anthropic", "model": "m", "task": task, "sample": 1, "in": tin, "out": tout, "cache_write": cw, "cache_read": cr,
            "stop": "end_turn", "outcome": outcome, "status": 200, "reply_chars": pc, "program_chars": pc, "ms": ms}
    if think is not None: r["thinking"] = think
    return r

rows = [
    call("UNIT: a", "cut_off", 100, 100, 0, 0, 0, think=60),            # a: a wasted sample
    call("UNIT: a", "written", 100, 300, 500, 0, 400, think=200),        # a: kept, program 400 chars
    call("UNIT: b", "no_program", 100, 50, 0, 500, 0, think=10),        # b: wasted
    call("UNIT: b", "written", 100, 500, 0, 500, 900, think=400),        # b: written, then rejected by the checker (not the last written)
    call("UNIT: b", "written", 100, 600, 0, 500, 1000, think=450),       # b: kept, program 1000 chars
    call("UNIT: c", "written", 100, 200, 0, 500, 1100, think=100),       # c: written but the unit never verified: nothing kept
]
os.makedirs(os.path.join(d, "run"))
w = os.path.join(d, "run")
open(os.path.join(w, "usage.jsonl"), "w").write("".join(json.dumps(r) + "\n" for r in rows))
open(os.path.join(w, "run.log"), "w").write("[PLAN]\tvalid\n[UNIT]\ta\tbuilding\n[UNIT]\ta\tverified\n[UNIT]\tb\tbuilding\n[UNIT]\tb\tverified\n[UNIT]\tc\tbuilding\n[UNIT]\tc\tfailed\n[PROJECT_VERDICT]\tstuck\n")
json.dump({"scaffold_chars": 40, "seconds": 12, "provider": "anthropic", "model": "m"}, open(os.path.join(w, "run.json"), "w"))
open(os.path.join(w, "audit.txt"), "w").write("a: 3/3\nTOTAL 7/10\n")

r = metrics.analyze(w, None, prices)
# tokens: in 6 x 100 = 600; out 100+300+50+500+600+200 = 1750; cache_write 500; cache_read 4 x 500 = 2000
check("tokens", r["tokens"], {"in": 600, "out": 1750, "cache_write": 500, "cache_read": 2000, "thinking": 1220})
check("calls", r["calls"], 6)
check("outcomes", r["outcomes"], {"cut_off": 1, "written": 4, "no_program": 1})
# cost: no call has a prompt over 1000 (the largest is 100 + 500 = 600): in 600 x 1.0 + cw 500 x 1.25 + cr 2000 x 0.1 + out 1750 x 5.0
#       = 600 + 625 + 200 + 8750 = 10175 micro-USD = 0.010175
check("cost", r["cost_usd"], 0.010175)
check("over limit", r["over_limit_calls"], 0)
# kept: a -> the 300-token call; b -> the 600-token call (the last written); c never verified -> none. kept_out = 900
check("kept_out", r["kept_out"], 900)
check("efficiency_calls", r["efficiency_calls"], round(900 / 1750, 4))
# mandatory share: a (400 - 40 scaffold) / 400 = 0.9; b (1000 - 400) / 1000 = 0.6. mandatory out = 300 x 0.9 + 600 x 0.6 = 270 + 360 = 630
check("efficiency", r["efficiency"], round(630 / 1750, 4))
check("unit a", (r["per_unit"]["a"]["kept_out"], r["per_unit"]["a"]["mandatory_share"], r["per_unit"]["a"]["out"]), (300, 0.9, 400))
check("unit b", (r["per_unit"]["b"]["kept_out"], r["per_unit"]["b"]["mandatory_share"], r["per_unit"]["b"]["out"]), (600, 0.6, 1150))
check("unit c: nothing kept", (r["per_unit"]["c"]["kept_out"], r["per_unit"]["c"]["verdict"]), (0, "failed"))
check("unit efficiency a", r["per_unit"]["a"]["efficiency"], round(270 / 400, 4))
check("units", (r["units_total"], r["units_verified"]), (3, 2))
check("verdict", r["project_verdict"], "stuck")
check("audit", r["audit"], {"passed": 7, "of": 10})
check("cost per verified unit", r["cost_per_verified_unit"], round(0.010175 / 2, 6))
check("cost per audit point", r["cost_per_audit_point"], round(0.010175 / 7, 8))
check("output tokens per audit point", r["output_tokens_per_audit_point"], round(1750 / 7, 2))
# unit a's cost alone: calls 1,2: in 200 + cw 500 x 1.25 + out 400 x 5 = 200 + 625 + 2000 = 2825 micro-USD
check("unit a cost", r["per_unit"]["a"]["cost"], 0.002825)

# thinking tokens (inside output_tokens): 60 + 200 + 10 + 400 + 450 + 100 = 1220 of 1750; visible output = 1750 - 1220 = 530
check("thinking tokens", r["tokens"]["thinking"], 1220)
check("thinking share", r["thinking_share"], round(1220 / 1750, 4))
check("visible output", r["visible_out"], 530)
# kept calls' visible tokens: a 300 - 200 = 100, b 600 - 450 = 150; times the mandatory shares 0.9 and 0.6 = 90 + 90 = 180 of 530 visible
check("efficiency over visible tokens", r["efficiency_visible"], round(180 / 530, 4))
# unit a: thinking 60 + 200 = 260 of 400
check("unit a thinking", (r["per_unit"]["a"]["thinking"], r["per_unit"]["a"]["out"]), (260, 400))

# patch mode (run.json "patch": true): the model returned only the unit, so program_chars is the patch and all of a kept call is mandatory (share 1.0), not the growth of a file it did not rewrite
w2 = os.path.join(d, "run2"); os.makedirs(w2)
for fn in ("usage.jsonl", "run.log", "audit.txt"):
    open(os.path.join(w2, fn), "w").write(open(os.path.join(w, fn)).read())
json.dump({"scaffold_chars": 40, "seconds": 12, "provider": "anthropic", "model": "m", "patch": True}, open(os.path.join(w2, "run.json"), "w"))
rp = metrics.analyze(w2, None, prices)
check("patch mode: kept calls are all mandatory", (rp["per_unit"]["a"]["mandatory_share"], rp["per_unit"]["b"]["mandatory_share"]), (1.0, 1.0))
# mandatory out = kept 300 + 600 = 900 of 1750
check("patch mode: efficiency equals the kept share", rp["efficiency"], round(900 / 1750, 4))

# a prompt over the limit is priced at the higher tier: in 1500, out 10 -> 1500 x 2.0 + 10 x 10 = 3100 micro-USD
d2 = os.path.join(d, "over"); os.makedirs(d2)
open(os.path.join(d2, "usage.jsonl"), "w").write(json.dumps(call("UNIT: a", "written", 1500, 10, 0, 0, 50)) + "\n")
r2 = metrics.analyze(d2, None, prices)
check("over limit cost", r2["cost_usd"], 0.0031)
check("over limit count", r2["over_limit_calls"], 1)

# a local model: no price, no cost number, but tokens are still counted
d3 = os.path.join(d, "local"); os.makedirs(d3)
row = call("UNIT: a", "written", 10, 20, 0, 0, 50); row["provider"] = "ollama"; row["model"] = "q"
open(os.path.join(d3, "usage.jsonl"), "w").write(json.dumps(row) + "\n")
r3 = metrics.analyze(d3, None, prices)
check("no price: no cost", r3["cost_usd"], None)
check("no price: tokens", r3["tokens"]["out"], 20)

# tokenbucket's audit ends `STRICT total 46/46` rather than `TOTAL`
d5 = os.path.join(d, "strict"); os.makedirs(d5)
open(os.path.join(d5, "usage.jsonl"), "w").write(json.dumps(call("UNIT: a", "written", 10, 10, 0, 0, 50)) + "\n")
open(os.path.join(d5, "audit.txt"), "w").write("bucket_refill: 12/12\nSTRICT total 46/46\n")
check("strict total", metrics.analyze(d5, None, prices).get("audit"), {"passed": 46, "of": 46})
# runs made before the API reported thinking tokens have no such field: unknown, not zero
r5 = metrics.analyze(d5, None, prices)
check("no thinking field: unknown", (r5["tokens"]["thinking"], r5["thinking_share"], r5["visible_out"], r5["efficiency_visible"]), (None, None, None, None))

# nothing at all
d4 = os.path.join(d, "empty"); os.makedirs(d4)
r4 = metrics.analyze(d4, None, prices)
check("empty: calls", r4["calls"], 0)
check("empty: efficiency", r4["efficiency"], None)

print("metrics: 33 checks")
sys.exit(1 if fails else 0)
PY
rc=$?
[ "$rc" = 0 ] && echo "metrics gate: ok" || { echo "metrics gate: FAILED" >&2; exit 1; }
