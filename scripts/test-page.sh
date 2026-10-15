#!/bin/sh
# The project page gate (docs/index.html and docs/guide.html): what the page tells a reader to run still works. A page that teaches something the code no
# longer does is worse than no page (the walkthrough told readers to `export OLLAMA_MODEL`, which the agent never receives, and showed a
# build command that no longer built).
#
#   build   every <pre data-check="build"> block: its `"$CANCHO" build ...` command is run (output redirected to a temp dir)
#   paths   every repository path the page names (eval/, scripts/, tests/, src/, docs/) exists, placeholders like eval/<item> aside
#   plans   every eval/*/plan.json the page names checks valid with the plancheck the page builds
#
# Needs python3. Exit 0 every check held.
set -u

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "no python3 on PATH" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d -t cc-page-XXXXXX)
fail=0

python3 - "$root/docs/index.html" "$root/docs/guide.html" "$tmp" <<'PY' || exit 1
import html, re, sys
page = "".join(open(f, encoding="utf-8").read() for f in sys.argv[1:-1])
tmp = sys.argv[-1]
blocks = re.findall(r'<pre data-check="build" data-out="([a-z]+)"><code>(.*?)</code></pre>', page, re.S)
if not blocks:
    sys.exit("the page has no data-check build blocks")
for name, code in blocks:
    text = html.unescape(code).replace("\\\n", " ")
    cmds = [l.strip() for l in text.splitlines() if l.strip().startswith('"$CANCHO" build')]
    if not cmds:
        sys.exit("block %s has no build command" % name)
    cmd = re.sub(r"-o \./%s\b" % name, "-o %s/%s" % (tmp, name), " ".join(cmds[0].split()))
    open("%s/build-%s.sh" % (tmp, name), "w").write(cmd + "\n")
# every repository path the page names
paths = set()
for m in re.finditer(r"\b((?:eval|scripts|tests|src|docs)/[A-Za-z0-9_./<>&;-]+)", html.unescape(page)):
    p = m.group(1).rstrip(".,;:)")
    if "<" in p or ">" in p:
        continue
    paths.add(p)
open(tmp + "/paths.txt", "w").write("\n".join(sorted(paths)) + "\n")
PY

for f in "$tmp"/build-*.sh; do
    name=$(basename "$f" .sh | sed 's/^build-//')
    (cd "$root" && CANCHO="$CANCHO" sh "$f") >"$tmp/$name.log" 2>&1 || { echo "FAIL: the page's $name build command did not build:" >&2; grep -v '^ld:' "$tmp/$name.log" | head -3 >&2; fail=1; }
    [ -x "$tmp/$name" ] || { echo "FAIL: the page's $name build command left no executable" >&2; fail=1; }
done

while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -e "$root/$p" ] || { echo "FAIL: the page names $p and it does not exist" >&2; fail=1; }
done < "$tmp/paths.txt"

for plan in $(grep '/plan.json$' "$tmp/paths.txt"); do
    out=$("$tmp/plancheck" "$root/$plan" 2>&1)
    [ "$out" = "$(printf '[PLAN]\tvalid')" ] || { echo "FAIL: the page names $plan and it is not valid: $out" >&2; fail=1; }
done

rm -rf "$tmp"
[ "$fail" = 0 ] && echo "page gate: ok" || { echo "page gate: FAILED" >&2; exit 1; }
