"""Read a run's journal and say what it holds, for scripts/test-journal.sh. Usage: check.py <workdir> <what>
Every line printed is a fact the gate compares; a journal that cannot be read as the schema says (docs/journal.md) prints `BAD <why>`."""
import json, os, subprocess, sys

wd, what = sys.argv[1], sys.argv[2]
j = os.path.join(wd, "journal")

def bad(why):
    print("BAD", why); sys.exit(0)

def events():
    p = os.path.join(j, "events.jsonl")
    if not os.path.exists(p): bad("no events.jsonl")
    raw = open(p, "rb").read()
    if raw and not raw.endswith(b"\n"): bad("the last line has no newline (a half line)")
    out, last = [], 0
    for i, line in enumerate(raw.split(b"\n")[:-1]):
        try: e = json.loads(line)
        except Exception as x: bad("line %d is not JSON: %s" % (i + 1, x))
        if not isinstance(e, dict) or "t_ms" not in e or "kind" not in e: bad("line %d lacks t_ms or kind" % (i + 1))
        if e["t_ms"] < last: bad("line %d: t_ms goes backwards" % (i + 1))
        last = e["t_ms"]; out.append(e)
    return out

def blob(name):
    p = os.path.join(j, "blobs", name)
    if not os.path.exists(p): bad("blob %s is named and not there" % name)
    return open(p, "rb").read()

ev = events()
atts = [e for e in ev if e["kind"] == "attempt"]
def att(u, n):
    for e in atts:
        if e["unit"] == u and e["n"] == n: return e
    bad("no attempt %s/%d" % (u, n))

if what == "kinds":
    print(" ".join(e["kind"] for e in ev))
elif what == "attempts":
    print(" ".join("%s/%d:%s:%s" % (e["unit"], e["n"], e["outcome"], e["decision"]) for e in atts))
elif what == "units":
    print(" ".join("%s:%s:%d" % (e["unit"], e["state"], e["attempts"]) for e in ev if e["kind"] == "unit_end"))
elif what == "blobs":
    # every blob an event names is there, none is over the cap
    for e in ev:
        for k, v in e.items():
            if k in ("prompt", "reply", "code", "feedback", "checker", "acceptance", "diff", "stderr", "plan", "blob") and isinstance(v, str):
                b = blob(v)
                if len(b) > 262144: bad("blob %s is %d bytes" % (v, len(b)))
    print("ok")
elif what == "refusal":
    # the checker blob of an attempt is the compiler's whole answer for that code: run the compiler on the code blob and compare
    u, n = sys.argv[3], int(sys.argv[4])
    e = att(u, n)
    code = os.path.join(j, "blobs", e["code"])
    tmp = os.path.join(wd, "probe.cho"); open(tmp, "wb").write(blob(e["code"]))
    r = subprocess.run([os.environ["CANCHO"], "check", "--std", "--output", "json", "--backend", "cranelift", tmp, os.path.join(wd, "main.cho")], capture_output=True)
    os.remove(tmp)
    # the compiler names the file it was given: the journal's answer names the project file, the probe has a path of its own
    want = blob(e["checker"]).replace(os.path.join(wd, "project.cho").encode(), tmp.encode())
    print("same" if r.stdout == want else "DIFFERENT")
    print("refused" if b'"refused": []' not in blob(e["checker"]) else "clean")
elif what == "diff":
    # the diff of an attempt turns the previous code (attempt n-1, or the file before the unit for n=0) into this attempt's code
    u, n = sys.argv[3], int(sys.argv[4])
    e = att(u, n)
    prev = blob(att(u, n - 1)["code"]) if n > 0 else open(sys.argv[5], "rb").read()
    src = os.path.join(wd, "probe.prev"); open(src, "wb").write(prev)
    r = subprocess.run(["patch", "-s", "-o", "-", src], input=blob(e["diff"]), capture_output=True)
    os.remove(src)
    print("rebuilds" if r.stdout == blob(e["code"]) else "WRONG")
elif what == "field":
    u, n, k = sys.argv[3], int(sys.argv[4]), sys.argv[5]
    e = att(u, n)
    v = e.get(k, "<absent>")
    print(json.dumps(v, sort_keys=True) if not isinstance(v, str) else v)
elif what == "blobtext":
    u, n, k = sys.argv[3], int(sys.argv[4]), sys.argv[5]
    e = att(u, n)
    if k not in e: print("<absent>")
    else: print(blob(e[k]).decode("utf-8", "replace").strip().replace("\n", " | ")[:200])
elif what == "blobsize":
    u, n, k = sys.argv[3], int(sys.argv[4]), sys.argv[5]
    e = att(u, n)
    b = blob(e[k]); print("within" if len(b) <= 262144 else "OVER", "marker" if b"cut here" in b else "whole", "long" if len(b) > 262000 else "short")
elif what == "first":
    k = sys.argv[3]
    for e in ev:
        if e["kind"] == k: print(json.dumps({x: y for x, y in e.items() if x != "t_ms"}, sort_keys=True)); break
elif what == "count":
    print(sum(1 for e in ev if e["kind"] == sys.argv[3]))
elif what == "primer":
    n = [f for f in os.listdir(os.path.join(j, "blobs")) if b"THE-PRIMER-TEXT-ONCE" in open(os.path.join(j, "blobs", f), "rb").read()]
    print(" ".join(sorted(n)))
elif what == "sweeps":
    print(" ".join("%s>%s|%s" % (e["after_unit"], ",".join(e["held"]), ",".join(e["regressed"])) for e in ev if e["kind"] == "sweep"))
else:
    bad("unknown question " + what)
