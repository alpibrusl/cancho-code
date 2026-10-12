#!/usr/bin/env python3
"""The acceptance check for 07-tokenbucket: the brief's own worked examples, in the brief's shapes (an Option from bucket_take, a record
from bucket_allow). It is what cancho-code's `fix` runs after the checker verifies a build, and what the agent reads when it fails.

    CANCHO=<compiler> python3 eval/tokenbucket/acceptance.py <project.cho>

Exit 0 when every example holds. On failure it prints which ones did not, or the compiler's first error, to standard output.
It is NOT the audit: the audit (eval/audit_tokenbucket.py, 46 cases) is a superset the builder never sees; these 15 examples are printed
in the brief itself."""
import os, re, subprocess, sys, tempfile

C = os.environ.get("CANCHO", "cancho")
src = open(sys.argv[1], encoding="utf-8").read()
body = re.sub(r"fn main\(world: World\).*?\n\}\n", "", src, flags=re.S)
body = re.sub(r"^edition \d+;\s*$", "", body, flags=re.M)
body = re.sub(r"^import std\.(option|test);\s*$", "", body, flags=re.M)
body = re.sub(r"^fn ", "pub fn ", body, flags=re.M)
body = re.sub(r"^(struct|enum) ", r"pub \1 ", body, flags=re.M)

# (name, test body). Every number is one printed in the brief.
EX = [
 ("bucket_refill(0, 0, 1000, 10, 1) is 1000", "test.assert_eq(bucket_refill(0, 0, 1000, 10, 1), 1000);"),
 ("bucket_refill(9500, 0, 1000, 10, 1) is 10000", "test.assert_eq(bucket_refill(9500, 0, 1000, 10, 1), 10000);"),
 ("bucket_refill(500, 100, 50, 10, 1) is 500", "test.assert_eq(bucket_refill(500, 100, 50, 10, 1), 500);"),
 ("bucket_refill(0, 0, 10000, 10, 1) is 10000", "test.assert_eq(bucket_refill(0, 0, 10000, 10, 1), 10000);"),
 ("bucket_take(5000, 5) is Some(0)", "match bucket_take(5000, 5) { option.Option::Some(v) => { test.assert_eq(v, 0); } option.Option::None => { test.assert(false); } }"),
 ("bucket_take(4999, 5) is None", "match bucket_take(4999, 5) { option.Option::Some(v) => { test.assert(false); } option.Option::None => { test.assert(true); } }"),
 ("bucket_take(5000, 0) is None", "match bucket_take(5000, 0) { option.Option::Some(v) => { test.assert(false); } option.Option::None => { test.assert(true); } }"),
 ("retry_after_ms(0, 1, 1, 10) is 1000", "test.assert_eq(retry_after_ms(0, 1, 1, 10), 1000);"),
 ("retry_after_ms(500, 1, 1, 10) is 500", "test.assert_eq(retry_after_ms(500, 1, 1, 10), 500);"),
 ("retry_after_ms(0, 5, 3, 10) is 1667", "test.assert_eq(retry_after_ms(0, 5, 3, 10), 1667);"),
 ("retry_after_ms(0, 1, 0, 10) is -1", "test.assert_eq(retry_after_ms(0, 1, 0, 10), -1);"),
 ("retry_after_ms(0, 11, 5, 10) is -1", "test.assert_eq(retry_after_ms(0, 11, 5, 10), -1);"),
 ("bucket_allow(0, 0, 429, 3, 7, 3) is {allowed: true, tokens_milli: 0, retry_ms: 0}", "let r = bucket_allow(0, 0, 429, 3, 7, 3); test.assert(r.allowed); test.assert_eq(r.tokens_milli, 0); test.assert_eq(r.retry_ms, 0);"),
 ("bucket_allow(0, 0, 428, 3, 7, 3) is {allowed: false, tokens_milli: 2996, retry_ms: 1}", "let r = bucket_allow(0, 0, 428, 3, 7, 3); test.assert(!r.allowed); test.assert_eq(r.tokens_milli, 2996); test.assert_eq(r.retry_ms, 1);"),
 ("bucket_allow(0, 0, 0, 10, 1, 11) is {allowed: false, tokens_milli: 0, retry_ms: -1}", "let r = bucket_allow(0, 0, 0, 10, 1, 11); test.assert(!r.allowed); test.assert_eq(r.tokens_milli, 0); test.assert_eq(r.retry_ms, -1);"),
]
tests = "".join("pub fn test_e%02d() -> [] int { %s return 0; }\n" % (i, b) for i, (n, b) in enumerate(EX))
head = "edition 7;\nmodule audit;\nimport std.test;\nimport std.option;\n"
f = tempfile.NamedTemporaryFile("w", suffix=".cho", delete=False, encoding="utf-8")
text = head + body + "\n" + tests
f.write(text); f.close()
r = subprocess.run([C, "test", f.name, "--std"], capture_output=True, text=True)
os.unlink(f.name)
out = r.stdout + r.stderr
m = re.search(r"(\d+) passed; (\d+) failed", r.stdout)
if m and int(m.group(2)) == 0:
    sys.exit(0)
if not m:
    err = [l.strip() for l in out.splitlines() if "error" in l]
    # The first line is what the loop compares between attempts (a signature): it must change when the failure does.
    msg, line = out.strip()[:200], ""
    if err:
        m2 = re.search(r"\.cho:(\d+):\d+: error: (.*)", err[0])
        msg = m2.group(2) if m2 else err[0][:200]
        # The example that did not build, in the brief's words. Never the harness's own code: a model shown `test_e04` pastes it into
        # its program and the harness then defines it twice.
        if m2 and 1 <= int(m2.group(1)) <= len(text.split("\n")):
            lines = text.split("\n")
            n = int(m2.group(1)) - 1
            while n >= 0 and not re.match(r"pub fn test_e(\d+)\(", lines[n]):
                n -= 1
            if n >= 0:
                line = EX[int(re.match(r"pub fn test_e(\d+)\(", lines[n]).group(1))][0]
    print("does not build in the brief's shapes: " + msg)
    print("The brief's worked examples could not be run: the functions do not build in the shapes the brief asks for.")
    if line:
        print("while checking: " + line)
    sys.exit(1)
bad = sorted(set(int(x) for x in re.findall(r"test audit\.test_e(\d+) \.\.\. FAILED", out)))
print("failing: " + ", ".join(EX[i][0].split(" is ")[0] for i in bad))
print("The brief's worked examples: %d of %d hold. These do not:" % (len(EX) - len(bad), len(EX)))
for i in bad:
    print("  " + EX[i][0])
sys.exit(1)
