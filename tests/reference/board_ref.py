#!/usr/bin/env python3
"""The oracle for src/board.cho (docs/dashboard.md): the same board.json, written independently, in Python.

    python3 tests/reference/board_ref.py <run dir> <prices.json | -> > board.json

Kept as the oracle only, like the other files in tests/reference/: scripts/test-board.sh checks that it reproduces every
committed tests/board/expected/*.json, and checks the cancho tool against the same files. The cost, token and efficiency
definitions are eval/metrics.py's (the gate also compares the two on the real fixtures); the arithmetic here is integer,
as in the tool, so a rounding difference between the two is not hidden by float noise.
"""
import json, os, re, sys

COLS = ["waiting", "building", "verified", "stuck", "regressed", "unknown"]


def esc(raw: bytes) -> str:
    out = []
    for b in raw:
        if b in (34, 92):
            out.append("\\" + chr(b))
        elif b < 32 or b >= 128:
            out.append("\\u%04x" % b)
        else:
            out.append(chr(b))
    return "".join(out)


def read(path):
    try:
        return open(path, "rb").read()
    except OSError:
        return None


def jload(raw):
    if raw is None:
        return None
    try:
        return json.loads(raw.decode("utf-8"))
    except Exception:
        return None


def lines(raw):
    for ln in raw.split(b"\n"):
        yield ln.rstrip(b"\r")


def micro_of(s: str) -> int:
    """'0.125' -> 125000 (millionths), at most six decimals."""
    m = re.fullmatch(r"(\d+)(?:\.(\d+))?", s)
    if not m:
        return 0
    frac = (m.group(2) or "")[:6].ljust(6, "0")
    return int(m.group(1)) * 1000000 + int(frac)


def fixed(n, digits):
    s = str(abs(n)).rjust(digits + 1, "0")
    return float(("-" if n < 0 else "") + s[:-digits] + "." + s[-digits:])


def ratio4(num, den):
    if den <= 0:
        return None
    return fixed((num * 20000 + den) // (2 * den), 4)


def price_table(path, provider, model):
    doc = jload(read(path)) if path else None
    if not isinstance(doc, dict) or provider is None or model is None:
        return None
    table = doc.get(provider)
    if not isinstance(table, dict):
        return None
    p = table.get(model) or table.get("_any")
    if not isinstance(p, dict):
        return None

    def tier(d):
        return [micro_of(repr_num(d.get(k, 0))) for k in ("in", "cache_write", "cache_read", "out")]

    res = {"limit": 0, "base": tier(p), "over": None}
    lim = p.get("prompt_limit")
    if isinstance(lim, int) and not isinstance(lim, bool):
        res["limit"] = lim
    if isinstance(p.get("over_limit_prices"), dict):
        res["over"] = tier(p["over_limit_prices"])
    return res


def repr_num(v):
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return "0"
    return repr(v) if isinstance(v, float) else str(v)


def intval(row, key):
    v = row.get(key)
    if isinstance(v, int) and not isinstance(v, bool):
        return v
    return None


# ---- the journal (docs/dashboard.md "The journal") ---------------------------------------------------------------------
BLOB_CAP = 32768          # bytes of a blob kept in board.json
BLOB_MAX = 262144         # the most the tool reads of one blob file
BLOB_BUDGET = 2097152     # all blob text in one board.json
MAX_EVENTS = 20000
MAX_LINE = 65536
SEEN_MAX = 65536
BLOB_KEYS = ["prompt", "reply", "code", "feedback", "checker", "acceptance", "diff", "stderr", "blob", "plan"]


def plain_name(n):
    if not n or len(n) > 100 or ".." in n:
        return False
    return all(33 <= ord(c) <= 126 and c not in '"\\/' for c in n)


def journal_of(wd, price):
    path = os.path.join(wd, "journal", "events.jsonl")
    raw = read(path)
    if raw is None:
        return None
    pieces = raw.split(b"\n")
    events, costs = [], []
    skipped = dropped = 0
    partial = False
    for i, ln in enumerate(pieces):
        if ln.endswith(b"\r"):
            ln = ln[:-1]
        if not ln:
            continue
        ev = None
        if len(ln) < MAX_LINE:
            try:
                ev = json.loads(ln.decode("utf-8"))
            except Exception:
                ev = None
        if not isinstance(ev, dict):
            if i == len(pieces) - 1:
                partial = True
            else:
                skipped += 1
            continue
        if len(events) >= MAX_EVENTS:
            dropped += 1
            continue
        events.append(ev)
    blobs = {}
    seen_used = 0
    total = omitted = 0

    def add(name):
        nonlocal seen_used, total, omitted
        if name in blobs or not plain_name(name):
            return
        if seen_used + len(name) + 1 > SEEN_MAX:
            omitted += 1
            return
        seen_used += len(name) + 1
        data = read(os.path.join(wd, "journal", "blobs", name))
        if data is None or os.path.isdir(os.path.join(wd, "journal", "blobs", name)):
            blobs[name] = None
            return
        data = data[:BLOB_MAX]
        cut = len(data)
        if len(data) > BLOB_CAP:
            cut = BLOB_CAP
            while cut > 0 and 128 <= data[cut] < 192:
                cut -= 1
        if total + cut > BLOB_BUDGET:
            blobs[name] = {"omitted": True}
            omitted += 1
            return
        total += cut
        blobs[name] = {"bytes": len(data), "truncated": len(data) > BLOB_CAP, "text": data[:cut].decode("utf-8", "replace")}

    for ev in events:
        if ev.get("primer") is True:
            add("primer.txt")
        for k in BLOB_KEYS:
            if isinstance(ev.get(k), str):
                add(ev[k])
        tk = ev.get("tokens")
        if isinstance(tk, dict) and price:
            g = lambda k: max(0, intval(tk, k) or 0)
            tier = price["base"]
            if price["limit"] and g("in") + g("cache_write") + g("cache_read") > price["limit"] and price["over"]:
                tier = price["over"]
            pico = g("in") * tier[0] + g("cache_write") * tier[1] + g("cache_read") * tier[2] + g("out") * tier[3]
            costs.append(fixed((pico + 500000) // 1000000, 6))
        else:
            costs.append(None)
    return {"events": events, "costs": costs, "blobs": blobs, "skipped_lines": skipped, "partial_tail": partial,
            "events_dropped": dropped, "blobs_omitted": omitted, "limits": {"blob_bytes": BLOB_CAP, "total_bytes": BLOB_BUDGET}}


def main():
    wd = sys.argv[1]
    prices_path = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] != "-" else None
    f = lambda n: read(os.path.join(wd, n))

    run_json = jload(f("run.json"))
    run_json = run_json if isinstance(run_json, dict) else None
    build_json = jload(f("build.json"))
    build_json = build_json if isinstance(build_json, dict) else None
    plan_raw = f("plan.json")
    plan_from = "plan.json"
    if plan_raw is None and run_json and isinstance(run_json.get("plan"), str):
        pp = run_json["plan"]
        if pp.startswith("/") and ".." not in pp:
            plan_raw = read(pp)
    plan = jload(plan_raw)
    plan = plan if isinstance(plan, dict) and isinstance(plan.get("units"), list) else None
    log = f("run.log")
    state = f("state.txt")
    usage = f("usage.jsonl")
    audit = f("audit.txt")
    pj = prices_path is not None and read(prices_path) is not None

    def strof(d, k):
        v = d.get(k) if d else None
        return v if isinstance(v, str) else None

    # ---- the registry -------------------------------------------------------------------------------------
    units = []  # dicts, in order
    index = {}

    def reg(id_esc):
        if id_esc not in index:
            index[id_esc] = len(units)
            units.append({"id": id_esc, "function": None, "deps": None, "ev": 0, "mv": 0, "reg": 0, "ord": -1, "sver": 0, "sbld": 0,
                          "calls": 0, "in": 0, "out": 0, "cw": 0, "cr": 0, "think": 0, "pico": 0, "over": 0,
                          "kept": None})
        return units[index[id_esc]]

    if plan:
        for u in plan["units"]:
            if not isinstance(u, dict) or not isinstance(u.get("id"), str):
                continue
            d = reg(json.dumps(u["id"], ensure_ascii=False)[1:-1])
            sig = u.get("signature")
            if isinstance(sig, str):
                m = re.match(r"fn\s+([A-Za-z_][A-Za-z_0-9]*)", sig)
                if m:
                    d["function"] = m.group(1)
            deps = u.get("deps")
            if isinstance(deps, list) and all(isinstance(x, str) for x in deps):
                d["deps"] = [json.dumps(x, ensure_ascii=False)[1:-1] for x in deps]
            else:
                d["deps"] = []
    nplan = len(units)

    EV = {b"building": 1, b"verified": 2, b"kept": 2, b"failed": 3, b"unavailable": 3, b"skipped": 4, b"regressed": 5}
    MV = {b"verified": 2, b"failed": 3, b"regressed": 5, b"unavailable": 6}
    order = []
    verdict = None
    if log is not None:
        for ln in lines(log):
            f_ = ln.split(b"\t")
            if f_[0] == b"[UNIT]" and len(f_) >= 3 and f_[2] in EV and f_[1]:
                d = reg(esc(f_[1]))
                code = EV[f_[2]]
                if code == 5:
                    d["reg"] += 1
                if not (code == 4 and d["ev"] == 5):
                    d["ev"] = code
                if f_[2] in MV:
                    d["mv"] = MV[f_[2]]
                    if d["ord"] < 0:
                        d["ord"] = len(order)
                        order.append(d)
            elif f_[0] == b"[PROJECT_VERDICT]" and len(f_) >= 2 and f_[1]:
                verdict = esc(f_[1])
    if state is not None:
        for ln in lines(state):
            t = ln.strip()
            for word, key in ((b"verified ", "sver"), (b"building ", "sbld")):
                if t.startswith(word) and t[len(word):].strip():
                    reg(esc(t[len(word):].strip()))[key] = 1

    # ---- usage ----------------------------------------------------------------------------------------------
    provider = strof(run_json, "provider") or strof(build_json, "provider")
    model = strof(run_json, "model") or strof(build_json, "model")
    rows = 0
    known = True
    first_pm = None
    parsed = []
    if usage is not None:
        for ln in lines(usage):
            try:
                row = json.loads(ln.decode("utf-8"))
            except Exception:
                continue
            if not isinstance(row, dict):
                continue
            parsed.append(row)
        if parsed and (provider is None or model is None):
            r0 = parsed[0]
            provider = provider or (r0["provider"] if isinstance(r0.get("provider"), str) else None)
            model = model or (r0["model"] if isinstance(r0.get("model"), str) else None)
    price = price_table(prices_path, provider, model) if usage is not None and pj else None
    patch = bool(run_json and run_json.get("patch") is True)
    scaffold = intval(run_json, "scaffold_chars") if run_json else None
    scaffold = scaffold or 0
    for row in parsed:
        task = row.get("task")
        uid = "-"
        if isinstance(task, str) and task.startswith("UNIT:"):
            t = task[5:].lstrip(" ")
            m = re.match(r"[^ \\\n]+", t)
            uid = m.group(0) if m else "-"
        d = reg(esc(uid.encode("utf-8")))
        if d["ord"] < 0:
            d["ord"] = len(order)
            order.append(d)
        rows += 1
        g = lambda k: intval(row, k) or 0
        if intval(row, "thinking") is None:
            known = False
        d["calls"] += 1
        for k, kk in (("in", "in"), ("out", "out"), ("cache_write", "cw"), ("cache_read", "cr")):
            d[kk] += g(k)
        d["think"] += g("thinking")
        if price:
            tier = price["base"]
            prompt = g("in") + g("cache_write") + g("cache_read")
            if price["limit"] and prompt > price["limit"] and price["over"]:
                tier = price["over"]
                d["over"] += 1
            d["pico"] += g("in") * tier[0] + g("cache_write") * tier[1] + g("cache_read") * tier[2] + g("out") * tier[3]
        if row.get("outcome") == "written":
            d["kept"] = (g("out"), g("thinking"), g("program_chars"))
    cards = [d for d in units if d["id"] != "-"]
    for d in units:
        d["micro"] = (d["pico"] + 500000) // 1000000

    tot = {k: sum(d[k] for d in units) for k in ("calls", "in", "out", "cw", "cr", "think", "over", "micro")}
    prev = scaffold
    mand = mandv = kept_out = 0
    for d in order:
        if d["calls"] == 0 or d["mv"] != 2 or d["kept"] is None:
            continue
        out, think, pc = d["kept"]
        share = (1000000 if pc else 0) if patch else (max(0, pc - prev) * 1000000 // pc if pc else 0)
        mand += out * share
        mandv += (out - think) * share
        kept_out += out
        prev = pc

    # ---- trails -----------------------------------------------------------------------------------------------
    def trail_of(name):
        raw = f(name)
        if raw is None:
            return None
        out = []
        for ln in lines(raw):
            try:
                row = json.loads(ln.decode("utf-8"))
            except Exception:
                continue
            if not isinstance(row, dict):
                continue
            iv = lambda k: row[k] if isinstance(row.get(k), int) and not isinstance(row.get(k), bool) else None
            sv = lambda k: row[k] if isinstance(row.get(k), str) else None
            out.append({"attempt": iv("attempt"), "agent_ms": iv("agent_ms"), "outcome": sv("outcome"), "sig": sv("sig"), "decision": sv("decision")})
        return out

    def safe_id(s):
        return s != "" and ".." not in s and "/" not in s and "\\" not in s

    def col(d, trail):
        e = d["ev"]
        if e == 1: return "building"
        if e == 2: return "verified"
        if e == 3: return "stuck"
        if e == 5: return "regressed"
        if e == 4: return "waiting"
        if d["sver"]: return "verified"
        if d["sbld"]: return "building"
        if log is not None: return "waiting"
        if trail and trail[-1]["decision"] in ("signature", "ceiling", "defect", "provider"):
            return "stuck"
        return "unknown"

    have_usage = usage is not None
    ucards = []
    counts = {c: 0 for c in COLS}
    for d in cards:
        trail = trail_of("trail-" + d["id"] + ".jsonl") if safe_id(d["id"]) else None
        c = col(d, trail)
        if c == "building" and (lt := trail_of("project.cho.trail.jsonl")) is not None:
            trail = lt
        counts[c] += 1
        known_t = have_usage and rows > 0 and known
        ucards.append({
            "id": d["id"], "function": d["function"], "column": c, "deps": d["deps"],
            "attempts": len(trail) if trail is not None else None, "regressions": d["reg"],
            "calls": d["calls"] if have_usage else None,
            "tokens": ({"in": d["in"], "out": d["out"], "thinking": d["think"] if known_t else None,
                        "cache_write": d["cw"], "cache_read": d["cr"]} if have_usage else None),
            "cost_usd": fixed(d["micro"], 6) if have_usage and price else None,
            "trail": trail,
        })

    nverified = counts["verified"]
    known_t = have_usage and rows > 0 and known
    m = {"units_total": len(cards), "units_verified": nverified, "columns": counts}
    m["calls"] = tot["calls"] if have_usage else None
    m["tokens"] = ({"in": tot["in"], "out": tot["out"], "cache_write": tot["cw"], "cache_read": tot["cr"], "thinking": tot["think"] if known_t else None}
                   if have_usage else None)
    m["visible_out"] = tot["out"] - tot["think"] if known_t else None
    m["thinking_share"] = ratio4(tot["think"], tot["out"]) if known_t else None
    inp = tot["in"] + tot["cw"] + tot["cr"]
    m["cache_read_share"] = ratio4(tot["cr"], inp) if have_usage else None
    m["efficiency"] = ratio4(mand, tot["out"] * 1000000) if have_usage else None
    m["efficiency_calls"] = ratio4(kept_out * 1000000, tot["out"] * 1000000) if have_usage else None
    vis = tot["out"] - tot["think"]
    m["efficiency_visible"] = ratio4(mandv, vis * 1000000) if known_t else None
    m["cost_usd"] = fixed(tot["micro"], 6) if have_usage and price else None
    m["cost_per_verified_unit"] = fixed((2 * tot["micro"] + nverified) // (2 * nverified), 6) if have_usage and price and nverified else None
    m["over_limit_calls"] = tot["over"] if have_usage and price else None
    au = None
    if audit is not None:
        hits = re.findall(rb"(?:TOTAL|total)\s+(\d+)/(\d+)", audit)
        if hits:
            au = {"passed": int(hits[-1][0]), "of": int(hits[-1][1])}
    m["audit"] = au

    secs = None
    for src in (run_json, build_json):
        v = src.get("seconds") if src else None
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            secs = v
            break
    name = strof(plan, "name") if plan else None
    name = name or strof(run_json, "item")
    started = build_json.get("started_unix") if build_json else None
    started = started if isinstance(started, (int, float)) and not isinstance(started, bool) else None
    pv = build_json.get("plan_valid") if build_json else None
    pv = pv if isinstance(pv, bool) else None
    vd = verdict if verdict is not None else strof(build_json, "verdict")
    board = {
        "schema": 1,
        "run": {"name": name, "brief": strof(build_json, "brief"), "stage": strof(build_json, "stage"), "plan_valid": pv,
                "provider": provider, "model": model, "started_unix": started, "seconds": secs, "verdict": vd},
        "files": {"plan": plan is not None, "run_log": log is not None, "state": state is not None, "usage": usage is not None,
                  "run_json": run_json is not None, "build_json": build_json is not None, "audit": audit is not None, "prices": bool(price)},
        "metrics": m,
        "truncated": False,
        "units": ucards,
    }
    jr = journal_of(wd, price)
    if jr is not None:
        board["journal"] = jr
    print(json.dumps(board, indent=1))


if __name__ == "__main__":
    main()
