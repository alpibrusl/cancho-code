#!/bin/sh
# The splice gate: src/splice.cho (the edit mode: a model returns only the code a unit adds, a program puts it into the project file;
# docs/plan.md "edit mode") held two ways.
#
#   differential  the cancho module and tests/reference/splice_ref.py agree, byte for byte, on `splice` (every fixture of tests/fixtures/splice:
#                 the new file, the report lines, the exit code; expected.txt pins the exit code and a piece of the report; a success is
#                 idempotent: splicing the same patch into the result changes nothing) and on `patch_span` (tests/fixtures/splice/replies;
#                 spans.txt pins the offsets).
#   semantic      each eval item's reference.cho (13) and each service's reference project.cho (4) is rebuilt from its `edition` line by
#                 splicing ONE ITEM AT A TIME, then again in random batches of 1 to 4 items, each batch re-sending an earlier item changed by one
#                 letter (it must be replaced in place) and the last patch re-sending every changed item as it was: the final text must be
#                 the reference normalised (the edition line, the imports, then each other item after a blank line; free comments dropped),
#                 every step must equal the Python reference's, and the result must pass `cancho check` where the reference does.
#
# SPLICE_SRC=path runs the gate against another copy of splice.cho (the mutation runs use it); SPLICE_ONLY=differential|semantic.
set -u
export PYTHONDONTWRITEBYTECODE=1

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "no python3 on PATH" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
src="${SPLICE_SRC:-$root/src/splice.cho}"
d=$(mktemp -d -t cc-splice-XXXXXX)
"$CANCHO" build "$root/tests/programs/splice_gate.cho" "$src" --std -o "$d/gate" >/dev/null 2>"$d/build.err" \
    || { cat "$d/build.err" >&2; echo "gate did not build" >&2; exit 2; }

python3 - "$d" "$root" "$CANCHO" <<'PY' || { echo "splice gate: FAILED" >&2; exit 1; }
import glob, os, random, subprocess, sys
d, root, cancho = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, os.path.join(root, "tests", "reference"))
import splice_ref as ref

only = os.environ.get("SPLICE_ONLY", "")
gate = os.path.join(d, "gate")
fails = 0
def fail(msg):
    global fails
    fails += 1
    print("FAIL: " + msg, file=sys.stderr)

def gate_splice(existing, patch, tag):
    ep, pp = os.path.join(d, tag + ".e"), os.path.join(d, tag + ".p")
    open(ep, "wb").write(existing)
    open(pp, "wb").write(patch)
    p = subprocess.run([gate, "splice", ep, pp], capture_output=True)
    return p.returncode, p.stdout, [l for l in p.stderr.split(b"\n") if l]

def both(name, existing, patch):
    rc, out, rep = gate_splice(existing, patch, "t")
    new, report, code = ref.splice(existing, patch)
    if rc != code:
        fail("%s: exit code cancho %d, reference %d" % (name, rc, code))
    if rep != report:
        fail("%s: report differs\n  cancho:    %s\n  reference: %s" % (name, rep, report))
    if out != new:
        fail("%s: new file differs\n  cancho:    %r\n  reference: %r" % (name, out[:300], new[:300]))
    return rc, out, rep

def span_of(path):
    p = subprocess.run([gate, "span", path], capture_output=True)
    return p.stdout.decode().strip()

nsplice = nspan = 0
if only != "semantic":
    fx = os.path.join(root, "tests", "fixtures", "splice")
    for l in open(os.path.join(fx, "expected.txt")):
        if not l.strip() or l.startswith("#"):
            continue
        name, rc, sub = l.rstrip("\n").split("\t", 2)
        existing = open(os.path.join(fx, name + ".existing"), "rb").read()
        patch = open(os.path.join(fx, name + ".patch"), "rb").read()
        r, out, rep = both(name, existing, patch)
        nsplice += 1
        if r != int(rc):
            fail("%s: wanted exit %s, got %d" % (name, rc, r))
        if sub and sub.encode() not in b"\n".join(rep):
            fail("%s: the report lacks %r: %r" % (name, sub, rep))
        if r == 0:
            if not out.endswith(b"\n") or out.endswith(b"\n\n"):
                fail("%s: the result must end in exactly one newline" % name)
            again = both(name + " (again)", out, patch)
            if again[1] != out:
                fail("%s: splicing the same patch twice changed the file" % name)
        else:
            if out != existing:
                fail("%s: an error must leave the file as it was" % name)
    pins = dict(l.rstrip("\n").split("\t") for l in open(os.path.join(fx, "spans.txt")) if l.strip() and not l.startswith("#"))
    for path in sorted(glob.glob(os.path.join(fx, "replies", "*.reply"))):
        name = os.path.basename(path)[:-6]
        got = span_of(path)
        a, b = ref.patch_span(open(path, "rb").read())
        if got != "%d %d" % (a, b):
            fail("span %s: cancho %s, reference %d %d" % (name, got, a, b))
        if pins.get(name) != got:
            fail("span %s: pinned %s, got %s" % (name, pins.get(name), got))
        nspan += 1
    for tail in (b"", b"x"):
        pass
    p = subprocess.run([gate, "span"], capture_output=True)
    if p.returncode != 2:
        fail("usage: span with no file should exit 2")
print("differential: %d splices, %d spans" % (nsplice, nspan))
if only == "differential":
    sys.exit(1 if fails else 0)

# ---- semantic -------------------------------------------------------------------------------
stub = os.path.join(root, "tests", "fixtures", "splice", "main_stub.cho")
pk = ""
real = os.path.realpath(subprocess.run(["which", cancho], capture_output=True, text=True).stdout.strip() or cancho)
for up in ("..", os.path.join("..", "..")):
    cand = os.path.normpath(os.path.join(os.path.dirname(real), up, "packages"))
    if os.path.isdir(cand):
        pk = cand
        break

def checks(path, service):
    """cancho check of a project file: a library needs a main beside it; a service the skeleton and the http-server package."""
    if service:
        files = [path, os.path.join(root, "eval", "services", "skeleton", "main.cho"), os.path.join(pk, "http-server", "server.cho")]
        if not pk:
            return None
    else:
        files = [path, stub]
    p = subprocess.run([cancho, "check", "--std"] + files, capture_output=True)
    return p.returncode == 0

def item_texts(text):
    items, st, pos = ref.parse_items(text)
    assert st == 0
    return items

def mutate(text):
    """The item with one letter changed after its first `{`: the same identity, the same shape."""
    k = text.find(b"{")
    if k < 0:
        return None
    for i in range(k + 1, len(text)):
        c = text[i]
        if 97 <= c <= 121 or 65 <= c <= 89:
            return text[:i] + bytes([c + 1]) + text[i + 1:]
    return None

refs = [(p, False) for p in sorted(glob.glob(os.path.join(root, "eval", "*", "reference.cho")))]
refs += [(p, True) for p in sorted(glob.glob(os.path.join(root, "eval", "services", "*", "reference", "project.cho")))]
rng = random.Random(20261015)
nfiles = nsteps = nresend = ncheck = 0
skipped = []
for path, service in refs:
    name = os.path.relpath(path, os.path.join(root, "eval"))
    original = open(path, "rb").read()
    items = item_texts(original)
    want = ref.normalise(original)
    ed = [i for i in items if i["kind"] == ref.EDITION][0]
    first = original[ed["start"]:ed["end"]] + b"\n"
    todo = [i for i in items if i["kind"] != ref.EDITION]
    texts = [original[i["start"]:i["end"]] for i in todo]
    # pass 1: one item at a time
    cur = first
    for k, t in enumerate(texts):
        rc, out, rep = both("%s pass 1 step %d" % (name, k), cur, t)
        if rc != 0:
            fail("%s pass 1 step %d: %r" % (name, k, rep))
            break
        cur = out
        nsteps += 1
    if cur != want:
        fail("%s pass 1: the rebuilt file is not the normalised reference" % name)
    final1 = cur
    # pass 2: random batches with re-sends
    cur = first
    placed = []
    changed = {}
    k = 0
    while k < len(texts):
        m = rng.randint(1, 4)
        batch = list(range(k, min(k + m, len(texts))))
        patch_items = [texts[j] for j in batch]
        idents = {ref.ident(texts[j], ref.parse_items(texts[j])[0][0]) for j in batch}
        cands = [j for j in placed if ref.parse_items(texts[j])[0][0]["kind"] not in (ref.IMPORT,)]
        rng.shuffle(cands)
        for j in cands:
            key = ref.ident(texts[j], ref.parse_items(texts[j])[0][0])
            mt = mutate(texts[j])
            if mt is not None and key not in idents and j not in changed:
                patch_items.insert(rng.randint(0, len(patch_items)), mt)
                changed[j] = mt
                idents.add(key)
                nresend += 1
                break
        rc, out, rep = both("%s pass 2 at %d" % (name, k), cur, b"\n\n".join(patch_items))
        if rc != 0:
            fail("%s pass 2 at %d: %r" % (name, k, rep))
            break
        cur = out
        placed += batch
        k += len(batch)
        nsteps += 1
    if changed:
        fix = b"\n\n".join(texts[j] for j in sorted(changed))
        rc, out, rep = both("%s pass 2 final" % name, cur, fix)
        cur = out
        nsteps += 1
    if cur != want:
        fail("%s pass 2: the rebuilt file is not the normalised reference" % name)
    if final1 != cur:
        fail("%s: the two passes disagree" % name)
    # the compiler
    open(os.path.join(d, "orig.cho"), "wb").write(original)
    open(os.path.join(d, "built.cho"), "wb").write(cur)
    a = checks(os.path.join(d, "orig.cho"), service)
    if a is None or not a:
        skipped.append(name)
    else:
        b = checks(os.path.join(d, "built.cho"), service)
        ncheck += 1
        if not b:
            fail("%s: the original passes `cancho check`, the rebuilt file does not" % name)
    nfiles += 1
print("semantic: %d references rebuilt (%d splices, %d earlier items re-sent changed and replaced in place), %d pass cancho check as the original does%s"
      % (nfiles, nsteps, nresend, ncheck, "; not checked: %s" % ", ".join(skipped) if skipped else ""))
sys.exit(1 if fails else 0)
PY
rc=$?
rm -rf "$d"
[ "$rc" = 0 ] && echo "splice gate: ok" || { echo "splice gate: FAILED" >&2; exit 1; }
