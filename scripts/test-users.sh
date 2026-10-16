#!/bin/sh
# The library-use gate (eval/services/users): a service built with two libraries the model is not taught (cancho-web and cancho-schema, vendored under
# eval/libs/). What it pins, beyond scripts/test-services.sh (the reference passes the acceptance and the attack, the stub fails both) and
# scripts/test-service-plans.sh users (the plan passes plancheck and builds with a stand-in agent to the full attack):
#
#   libs      every vendored file is the recorded one (sha256 in eval/libs/UPSTREAM.txt), each carries the EUPL-1.2 LICENSE and NOTICE of its
#             upstream, and eval/services/users/libs.txt names only vendored files
#   briefs    the brief names no other language (scripts/test-briefs.sh)
#   docs      the docs primer (eval/primer-libs.md) is small and carries nothing of the hidden attack (no check names, no audit)
#   mutants   each deliberate mutant of the reference (eval/services/users/mutants.json) is caught by the attack check it names (eval/mutate_users.py)
#
# Usage: test-users.sh [libs|briefs|docs|mutants ...]   (default: all)
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
CANCHO="${CANCHO:-cancho}"
fail=0
want="${*:-libs briefs docs mutants}"
has() { case " $want " in *" $1 "*) return 0 ;; esac; return 1; }

if has libs; then
    command -v python3 >/dev/null 2>&1 || { echo "no python3 on PATH" >&2; exit 2; }
    out=$(python3 - "$root" <<'PY'
import hashlib, os, sys
root = sys.argv[1]
bad = []
seen = set()
for line in open(os.path.join(root, "eval/libs/UPSTREAM.txt")):
    if line.startswith("#") or not line.strip(): continue
    h, p = line.split(None, 1); p = p.strip(); seen.add(p)
    f = os.path.join(root, p)
    if not os.path.exists(f): bad.append("missing %s" % p); continue
    if hashlib.sha256(open(f, "rb").read()).hexdigest() != h: bad.append("%s is not the recorded file (sha256 differs)" % p)
for d in ("cancho-web", "cancho-schema"):
    for n in ("LICENSE", "NOTICE"):
        p = "eval/libs/%s/%s" % (d, n)
        if p not in seen: bad.append("%s is not recorded" % p)
    if "European Union Public Licence v. 1.2" not in open(os.path.join(root, "eval/libs", d, "LICENSE"), encoding="utf-8").read(): bad.append("%s/LICENSE is not the EUPL-1.2" % d)
for line in open(os.path.join(root, "eval/services/users/libs.txt")):
    if line.strip() and line.strip() not in seen: bad.append("libs.txt names %s, which is not a recorded file" % line.strip())
for rev in ("5f404a777018cf42b5c713daa4972c938c9229f4", "a7eaad6d5119d6cf517204f16260cd38f03ceba0"):
    if rev not in open(os.path.join(root, "eval/libs/UPSTREAM.txt")).read(): bad.append("UPSTREAM.txt does not record %s" % rev)
print("\n".join(bad))
PY
); rc=$?
    { [ "$rc" = 0 ] && [ -z "$out" ]; } || { echo "FAIL: libs: ${out:-the check did not run (exit $rc)}" >&2; fail=1; }
fi

if has briefs; then
    sh "$root/scripts/test-briefs.sh" >/dev/null 2>&1 || { echo "FAIL: briefs gate" >&2; fail=1; }
fi

if has docs; then
    f="$root/eval/primer-libs.md"
    [ -f "$f" ] || { echo "FAIL: docs: no eval/primer-libs.md" >&2; fail=1; }
    if [ -f "$f" ]; then
        n=$(wc -c < "$f")
        [ "$n" -lt 24000 ] || { echo "FAIL: docs: eval/primer-libs.md is $n bytes (bound: 24000)" >&2; fail=1; }
        # nothing of the hidden attack: none of its check names, its ports, or the capacity number as a trap
        if grep -n -i -E 'attack|audit|8815|mutant|hidden' "$f" >/dev/null 2>&1; then echo "FAIL: docs: the docs primer names the attack, the audit or a mutant" >&2; fail=1; fi
        sh "$root/scripts/test-briefs.sh" "$f" >/dev/null 2>&1 || { echo "FAIL: docs: the docs primer names another language or uses its notation" >&2; fail=1; }
    fi
fi

if has mutants; then
    command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
    CANCHO=$(command -v "$CANCHO"); export CANCHO
    out=$(python3 "$root/eval/mutate_users.py" 2>&1); rc=$?
    n=$(printf '%s\n' "$out" | grep -c '^ok ')
    [ "$rc" = 0 ] || { printf '%s\n' "$out" >&2; echo "FAIL: mutants: a mutant of the reference was not caught by its named check" >&2; fail=1; }
    [ "$n" -ge 12 ] || { echo "FAIL: mutants: only $n mutants were caught (want 12 or more)" >&2; fail=1; }
fi

[ "$fail" = 0 ] && echo "users gate: ok" || { echo "users gate: FAILED" >&2; exit 1; }
