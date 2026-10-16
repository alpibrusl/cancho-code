#!/usr/bin/env python3
"""The oracle for src/lessons.cho (docs/memory.md): the same lessons.jsonl, written independently, in Python.

    python3 tests/reference/lessons_ref.py [--min-count N] [--min-runs N] (--run <dir> | --trail <file>)... > lessons.jsonl

Kept as the oracle only, like the other files in tests/reference/: scripts/test-lessons.sh checks that the cancho tool and this
script give the same lines (as JSON) on every fixture under tests/lessons/.
"""
import json, os, re, sys

KEPT = set("int bool float byte fn extern struct enum static let var if else while return match true false Option Result List Vec Map String Buffer Box Heap Io".split())


def span(x):
    if x in KEPT or x == "":
        return x
    if all(ord(c) < 128 and not c.isalnum() and c not in "_ " for c in x) and 1 <= len(x) <= 3:
        return x
    if any(ord(c) >= 128 for c in x):
        return "C"
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.#]*", x):
        return "N"
    return "T"


def class_of(sig):
    b = sig.encode()
    out = bytearray()
    i = 0
    past = False
    while i < len(b):
        c = b[i]
        if i >= 240 and (c < 128 or c >= 192):
            break
        if c == 96:
            j = b.find(b"`", i + 1)
            if j >= 0:
                out += b"`" + span(b[i + 1:j].decode("utf-8", "replace")).encode() + b"`"
                i = j + 1
            else:
                out += b"`"; i += 1
        elif past and c == 47 and i > 0 and b[i - 1] in (58, 32):
            while i < len(b) and b[i] not in (32, 96):
                i += 1
            out += b"PATH"
        elif past and i >= 5 and (chr(c).isalpha() or c == 95) and b[i - 5:i] == b"test ":
            while i < len(b) and (chr(b[i]).isalnum() and b[i] < 128 or b[i] == 95):
                i += 1
            out += b"N"
        elif past and 48 <= c <= 57:
            while i < len(b) and 48 <= b[i] <= 57:
                i += 1
            out += b"#"
        else:
            if c == 58:
                past = True
            out.append(c); i += 1
    return out.decode("utf-8", "replace")


def lesson_id(cls):
    h = 5381
    for c in cls.encode():
        h = (h * 33 + c) % 4294967296
    return "L%08x" % h


def redact(text):
    def rep(m):
        w = m.group(0)
        if len(w) >= 20 and re.search("[A-Za-z]", w) and re.search("[0-9]", w) and ("-" in w or "_" not in w):
            return "[redacted]"
        return w
    return re.sub(r"[A-Za-z0-9_-]+", rep, text)


def excerpt(text):
    out, used = [], 0
    for l in text.split("\n"):
        if len(out) >= 14 or used >= 600:
            break
        l = l.rstrip("\r")
        if l[:1] in ("+", "-") and not l.startswith("+++ ") and not l.startswith("--- "):
            l = l.encode()[:160].decode("utf-8", "ignore")
            if used + len(l.encode()) + 1 <= 600:
                out.append(redact(l)); used += len(l.encode()) + 1
            else:
                used = 600
    return "".join(x + "\n" for x in out)


def plain(n):
    return 0 < len(n) <= 128 and n[0] != "." and re.fullmatch(r"[A-Za-z0-9._-]+", n) is not None and ".." not in n


class Miner:
    def __init__(self, min_count, min_runs):
        self.cl = {}; self.order = []; self.runs = []; self.mc = min_count; self.mr = min_runs
        self.units = {}

    def klass(self, cls, example):
        if cls not in self.cl:
            self.cl[cls] = dict(cls=cls, example=example, count=0, runs=0, units=0, ns=0, nv=0, first=0, last=0, contra=0, confirm=0,
                                last_run=-1, last_unit=None, fixes=[], ev=[], sj=0, sl=0)
            self.order.append(cls)
        return self.cl[cls]

    def begin(self, name):
        if self.runs and self.runs[-1] == name:
            return len(self.runs) - 1
        self.runs.append(name); self.pend = {}
        return len(self.runs) - 1

    def attempt(self, run, rd, unit, attempt, t_ms, kind, sig, rec_ids, diff):
        key = (run, unit)
        prev = self.pend.get(unit)
        if prev is not None:
            p = self.cl[prev]
            if kind in (0, 1):
                p["ns"] += 1
                recalled = lesson_id(prev) in rec_ids
                if kind == 0:
                    p["nv"] += 1
                    if recalled: p["confirm"] += 1
                    if diff and plain(diff) and rd:
                        try:
                            t = open(os.path.join(rd, "journal", "blobs", diff), "rb").read()[:262144].decode("utf-8", "replace")
                            ex = excerpt(t)
                            if ex:
                                if len(p["fixes"]) < 3: p["fixes"].append((ex, self.runs[run], unit, attempt))
                                else:
                                    # the first of the longest is replaced, when the new one is shorter
                                    w = 0
                                    for i in range(1, 3):
                                        if len(p["fixes"][i][0].encode()) > len(p["fixes"][w][0].encode()): w = i
                                    if len(ex.encode()) < len(p["fixes"][w][0].encode()): p["fixes"][w] = (ex, self.runs[run], unit, attempt)
                        except OSError:
                            pass
                elif recalled and class_of(sig) == prev:
                    p["contra"] += 1
            del self.pend[unit]
        if kind == 1:
            example = redact(sig[:200])
            c = self.klass(class_of(example), example)
            c["count"] += 1
            if c["last_run"] != run: c["runs"] += 1; c["last_run"] = run
            if c["last_unit"] != key: c["units"] += 1; c["last_unit"] = key
            if t_ms > 0:
                if c["first"] == 0 or t_ms < c["first"]: c["first"] = t_ms
                c["last"] = max(c["last"], t_ms); c["sj"] += 1
            else:
                c["sl"] += 1
            if len(c["ev"]) < 12: c["ev"].append((self.runs[run], unit, attempt))
            self.pend[unit] = c["cls"]

    def journal(self, rd):
        try:
            data = open(os.path.join(rd, "journal", "events.jsonl"), "rb").read()[:2300000]
        except OSError:
            return
        if not data:
            return
        run = self.begin(os.path.basename(rd.rstrip("/")))
        for raw in data.split(b"\n"):
            raw = raw.rstrip(b"\r")
            if not raw or len(raw) >= 65536:
                continue
            try:
                e = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(e, dict) or e.get("kind") != "attempt" or not isinstance(e.get("unit"), str):
                continue
            o = e.get("outcome")
            kind = 0 if o == "verified" else 1 if o in ("refused", "acceptance_failed") else 2
            sig = e.get("signature")
            if kind == 1 and not (isinstance(sig, str) and sig):
                kind = 2
            ids = {m.get("id") for m in e.get("memory", []) if isinstance(m, dict)} if isinstance(e.get("memory"), list) else set()
            t = e.get("t_ms") if isinstance(e.get("t_ms"), int) else 0
            self.attempt(run, rd, e["unit"], e["n"] if isinstance(e.get("n"), int) else -1, max(t, 1), kind, sig or "", ids,
                         e["diff"] if isinstance(e.get("diff"), str) else "")

    def trail(self, f):
        try:
            data = open(f, "rb").read()
        except OSError:
            return
        leaf = os.path.basename(f)
        if not data or not leaf.startswith("trail-") or not leaf.endswith(".jsonl") or len(leaf) <= 12:
            return
        unit = leaf[6:-6]
        run = self.begin(os.path.basename(os.path.dirname(f)))
        for raw in data.split(b"\n"):
            raw = raw.rstrip(b"\r")
            if not raw:
                continue
            try:
                e = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(e, dict):
                continue
            o = e.get("outcome")
            kind = 0 if o == "verified" else 1 if o in ("refused", "acceptance_failed") else 2
            sig = e.get("sig")
            if kind == 1 and not (isinstance(sig, str) and sig):
                kind = 2
            self.attempt(run, None, unit, e["attempt"] if isinstance(e.get("attempt"), int) else -1, 0, kind, sig or "", set(), "")

    def status(self, c):
        if c["contra"] >= 2 and c["contra"] > c["confirm"]:
            return 1
        return 0 if c["count"] >= self.mc and c["runs"] >= self.mr else 2

    def lines(self):
        rank = sorted(range(len(self.order)), key=lambda i: (self.status(self.cl[self.order[i]]), -self.cl[self.order[i]]["count"], i))
        for i in rank:
            c = self.cl[self.order[i]]
            src = "mixed" if c["sj"] and c["sl"] else "journal" if c["sj"] else "legacy"
            yield dict(id=lesson_id(c["cls"]), rule=c["cls"].split(":")[0], **{"class": c["cls"]}, example=c["example"],
                       status=["active", "superseded", "insufficient"][self.status(c)], count=c["count"], runs=c["runs"], units=c["units"],
                       next_seen=c["ns"], next_verified=c["nv"], first=c["first"], last=c["last"], contradicted=c["contra"], confirmed=c["confirm"],
                       source=src, fixes=[dict(run=r, unit=u, attempt=a, diff=d) for d, r, u, a in c["fixes"]],
                       evidence=[dict(run=r, unit=u, attempt=a) for r, u, a in c["ev"]])


def main(argv):
    mc, mr, inputs = 3, 2, []
    i = 0
    while i < len(argv):
        if argv[i] == "--min-count": mc = int(argv[i + 1]); i += 2
        elif argv[i] == "--min-runs": mr = int(argv[i + 1]); i += 2
        else: inputs.append((argv[i], argv[i + 1])); i += 2
    m = Miner(mc, mr)
    for kind, path in inputs:
        (m.journal if kind == "--run" else m.trail)(path)
    for l in m.lines():
        print(json.dumps(l))


if __name__ == "__main__":
    main(sys.argv[1:])
