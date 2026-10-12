#!/usr/bin/env python3
"""Independent audit of a built tokenbucket against the lex-code backlog oracle (46 cases), by function group.

    CANCHO=<compiler> python3 eval/audit_tokenbucket.py <project.cho>

Prints one line per group: STRICT is the brief's shapes (a compile error counts as a failure: `Option` from bucket_take, a record from
bucket_allow); the lenient line maps None to -1 for bucket_take only, to separate "the arithmetic is wrong" from "the shape is not the
brief's". Exit 0 only if every case holds in the brief's shapes. The oracle (eval/tokenbucket/oracle.py) is the lex-code backlog's,
written before any run; ORACLE= overrides the path. The model under test never sees this file."""
import json, re, subprocess, sys, tempfile, os
HERE = os.path.dirname(os.path.abspath(__file__))
C = os.environ.get("CANCHO", "cancho")
ORACLE = os.environ.get("ORACLE", os.path.join(HERE, "tokenbucket", "oracle.py"))
src = open(sys.argv[1]).read()
cases = [json.loads(l) for l in subprocess.run([sys.executable, ORACLE], capture_output=True, text=True, check=True).stdout.splitlines() if l.strip()]
# everything except main (and the seed's comments), public, as a module
body = re.sub(r"fn main\(world: World\).*?\n\}\n", "", src, flags=re.S)
body = re.sub(r"^edition \d+;\s*$", "", body, flags=re.M)
body = re.sub(r"^import std\.(option|test);\s*$", "", body, flags=re.M)   # the harness imports these itself
body = re.sub(r"^fn ", "pub fn ", body, flags=re.M)
body = re.sub(r"^(struct|enum) ", r"pub \1 ", body, flags=re.M)
head = "edition 7;\nmodule audit;\nimport std.test;\nimport std.option;\n"
def run(tests, n):
    f = tempfile.NamedTemporaryFile("w", suffix=".cho", delete=False); f.write(head + body + "\n" + tests); f.close()
    r = subprocess.run([C, "test", f.name, "--std"], capture_output=True, text=True); os.unlink(f.name)
    m = re.search(r"(\d+) passed; (\d+) failed", r.stdout)
    if m: return int(m.group(1)), n, ""
    err = (r.stderr + r.stdout).strip().splitlines()
    return 0, n, ("does not build: " + next((l for l in err if "error" in l), err[0] if err else "?")[-110:])
def args(c): return ", ".join(str(a) for a in c["args"])
def t(i, expr): return f"pub fn test_c{i}() -> [] int {{ {expr} return 0; }}\n"
out = {}
by = lambda fn: [c for c in cases if c["fn"] == fn]
out["bucket_refill"] = run("".join(t(i, f"test.assert_eq(bucket_refill({args(c)}), {c['expect']});") for i, c in enumerate(by("bucket_refill"))), len(by("bucket_refill")))
out["retry_after_ms"] = run("".join(t(i, f"test.assert_eq(retry_after_ms({args(c)}), {c['expect']});") for i, c in enumerate(by("retry_after_ms"))), len(by("retry_after_ms")))
def take_strict(i, c):
    e = c["expect"]
    if isinstance(e, dict) and e.get("$variant") == "Some":
        return t(i, f"match bucket_take({args(c)}) {{ option.Option::Some(v) => {{ test.assert_eq(v, {e['args'][0]}); }} option.Option::None => {{ test.assert(false); }} }}")
    return t(i, f"match bucket_take({args(c)}) {{ option.Option::Some(v) => {{ test.assert(false); }} option.Option::None => {{ test.assert(true); }} }}")
out["bucket_take (strict: Option)"] = run("".join(take_strict(i, c) for i, c in enumerate(by("bucket_take"))), len(by("bucket_take")))
def take_len(i, c):
    e = c["expect"]; w = e["args"][0] if e.get("$variant") == "Some" else -1
    return t(i, f"test.assert_eq(bucket_take({args(c)}), {w});")
out["bucket_take (lenient: None=-1)"] = run("".join(take_len(i, c) for i, c in enumerate(by("bucket_take"))), len(by("bucket_take")))
def allow_strict(i, c):
    e = c["expect"]
    return t(i, f"let r = bucket_allow({args(c)}); test.assert(r.allowed == {str(e['allowed']).lower()}); test.assert_eq(r.tokens_milli, {e['tokens_milli']}); test.assert_eq(r.retry_ms, {e['retry_ms']});")
out["bucket_allow (strict: record)"] = run("".join(allow_strict(i, c) for i, c in enumerate(by("bucket_allow"))), len(by("bucket_allow")))
tot = 0; n = 0
for k, (p, total, err) in out.items():
    print(f"  {k}: {p}/{total} {err}")
strict = out["bucket_refill"][0] + out["retry_after_ms"][0] + out["bucket_take (strict: Option)"][0] + out["bucket_allow (strict: record)"][0]
print(f"  STRICT total {strict}/{len(cases)}")
sys.exit(0 if strict == len(cases) else 1)
