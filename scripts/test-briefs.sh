#!/bin/sh
# The briefs and the prompts are not contaminated with Lex: everything a model reads while planning or building (the eval briefs, the service
# briefs, the plan and review guides, the string literals of the prompt-building sources) names no other language and uses none of its notation
# (`Str`, `Int`, `x :: T`, `List[..]`, "the Lex original"). A brief is what a user would write: plain language, the public names, examples.
# Source comments may name lex-code (they are not sent to a model); string literals may not.
#
#   ROOT=<dir> sh scripts/test-briefs.sh [extra file ...]     extra files (e.g. the primer) are checked too
# Exit 0: clean.
set -u
ROOT="${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
fail=0
pat='(^|[^a-zA-Z])[Ll]ex([^a-zA-Z]|$)|(^|[^a-zA-Z])Str([^a-zA-Z]|$)|(^|[^a-zA-Z])Int([^a-zA-Z]|$)| :: |(^|[^.a-zA-Z])List\[|Option\[Str'
check() {
    out=$(grep -n -E "$pat" "$1" 2>/dev/null)
    [ -z "$out" ] || { echo "FAIL: $1 names Lex or uses its notation:" >&2; echo "$out" | head -3 | cut -c1-160 >&2; fail=1; }
}
for f in "$ROOT"/eval/*/brief.txt "$ROOT"/eval/services/*/brief.txt "$ROOT"/docs/plan-guide.md "$ROOT"/docs/review-guide.md "$ROOT"/docs/agent-prompt.md "$ROOT"/skills/*/SKILL.md "$@"; do
    [ -f "$f" ] && check "$f"
done
# the prompt-building sources: code comments are not sent to a model, string literals are
for f in "$ROOT"/src/planprompt.cho "$ROOT"/src/prompt.cho "$ROOT"/src/review.cho "$ROOT"/src/cases.cho "$ROOT"/src/cancho_agent.cho "$ROOT"/src/anthropic.cho "$ROOT"/src/ollama.cho; do
    [ -f "$f" ] || continue
    out=$(grep -v -E '^[[:space:]]*//' "$f" | sed -E 's://.*$::' | grep -n -E '"([^"]*[^a-zA-Z"])?[Ll]ex([^a-zA-Z"][^"]*)?"|"[^"]*( Str[ ,)]| Int[ ,)]| :: )[^"]*"')
    [ -z "$out" ] || { echo "FAIL: $f has a string literal naming Lex or its notation:" >&2; echo "$out" | head -3 | cut -c1-160 >&2; fail=1; }
done
[ "$fail" = 0 ] && echo "briefs gate: ok" || { echo "briefs gate: FAILED" >&2; exit 1; }
