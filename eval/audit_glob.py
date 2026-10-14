#!/usr/bin/env python3
"""Independent audit of a built `02-glob` against the lex-code backlog oracle (87 cases), glob_match and glob_valid graded separately.

    CANCHO=<compiler> python3 eval/audit_glob.py <project.cho>

The shapes are the ones the plan pins (cancho has no `Str`, so the brief's `Str` becomes bytes):
    glob_valid[&r](pattern: &r [byte]) -> [] bool
    glob_match[&r, &t](pattern: &r [byte], text: &t [byte]) -> [] bool
A file that does not build in those shapes scores 0 for the group that needs them, with the compiler's first error. The helper
functions the plan asks for are not graded here: only the two public functions the brief names are. Exit 0 only if every case holds.
The oracle (eval/glob/oracle.py, vendored unchanged) was written before any run; ORACLE= overrides it. The model under test never
sees this file."""
import json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
C = os.environ.get("CANCHO", "cancho")
ORACLE = os.environ.get("ORACLE", os.path.join(HERE, "glob", "oracle.py"))
src = open(sys.argv[1], encoding="utf-8").read()
cases = [json.loads(l) for l in subprocess.run([sys.executable, ORACLE], capture_output=True, text=True, check=True).stdout.splitlines() if l.strip()]

body = re.sub(r"fn main\(world: World\).*?\n\}\n", "", src, flags=re.S)
body = re.sub(r"^edition \d+;\s*$", "", body, flags=re.M)
body = re.sub(r"^module \w+;\s*$", "", body, flags=re.M)
body = re.sub(r"^import std\.(utf8|test);\s*$", "", body, flags=re.M)   # the harness imports these itself
body = re.sub(r"^fn ", "pub fn ", body, flags=re.M)
body = re.sub(r"^(struct|enum) ", r"pub \1 ", body, flags=re.M)
head = "edition 7;\nimport std.utf8;\nimport std.test;\n"

def lit(s):
    m = {"\n": "\\n", "\r": "\\r", "\t": "\\t", "\\": "\\\\", '"': '\\"', "\0": "\\0"}
    return '"' + "".join(m.get(c, c) for c in s) + '"'

def tests_for(fn):
    out = []
    for i, c in enumerate([c for c in cases if c["fn"] == fn]):
        call = f"{fn}({', '.join(lit(a) for a in c['args'])})"
        call = call if c["expect"] else f"!{call}"
        out.append(f"pub fn test_g{i:02d}() -> [] int {{ test.assert({call}); return 0; }}")
    return "\n".join(out) + "\n"

def run(fn):
    n = len([c for c in cases if c["fn"] == fn])
    f = tempfile.NamedTemporaryFile("w", suffix=".cho", delete=False, encoding="utf-8")
    f.write(head + body + "\n" + tests_for(fn)); f.close()
    r = subprocess.run([C, "test", f.name, "--std"], capture_output=True, text=True)
    os.unlink(f.name)
    m = re.search(r"(\d+) passed; (\d+) failed", r.stdout)
    if m:
        return int(m.group(1)), n, ""
    err = [l for l in (r.stderr + r.stdout).splitlines() if "error" in l]
    return 0, n, "does not build: " + (re.sub(r"^.*?\.cho:", "line ", err[0])[:120] if err else "?")

total = 0
for fn in ("glob_match", "glob_valid"):
    p, n, why = run(fn)
    total += p
    print(f"  {fn}: {p}/{n} {why}")
print(f"  TOTAL {total}/{len(cases)}")
sys.exit(0 if total == len(cases) else 1)
