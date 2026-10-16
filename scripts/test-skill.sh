#!/bin/sh
# The skill (skills/cancho-code/SKILL.md) teaches an agent commands that must exist: its frontmatter is valid, every repository path it names exists, every
# `--option` it tells an agent to type is documented in docs/build.md or is an option the agent command takes (docs/reference.md), and it never asks
# for a key to be read. A skill that teaches something the tool no longer does is worse than no skill.   Exit 0: it holds.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
f="$root/skills/cancho-code/SKILL.md"
fail=0
[ -f "$f" ] || { echo "FAIL: $f is missing" >&2; exit 1; }
[ "$(sed -n 1p "$f")" = "---" ] || { echo "FAIL: no frontmatter" >&2; fail=1; }
name=$(sed -n '2,/^---$/p' "$f" | sed -n 's/^name: *//p'); [ "$name" = "cancho-code" ] || { echo "FAIL: frontmatter name is '$name'" >&2; fail=1; }
desc=$(sed -n '2,/^---$/p' "$f" | sed -n 's/^description: *//p'); [ -n "$desc" ] && [ "${#desc}" -lt 700 ] || { echo "FAIL: description missing or over 700 characters" >&2; fail=1; }
body=$(sed '1,/^---$/{/^---$/!d;}' "$f" | sed '1,/^---$/d')
# repository paths named in the skill exist
for p in $(printf '%s\n' "$body" | grep -o -E '(docs|scripts|build|eval|src|tests)/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*' | sort -u); do
    case "$p" in build/*|work/*) continue ;; esac
    [ -e "$root/$p" ] || { echo "FAIL: the skill names $p and it does not exist" >&2; fail=1; }
done
# options the skill tells an agent to type
docs="$root/docs/build.md $root/docs/reference.md $root/docs/project.md $root/docs/agent-prompt.md $root/docs/plan-guide.md"
for o in $(printf '%s\n' "$body" | grep -o -E -- '--[a-z][a-z-]+' | sort -u); do
    grep -q -- "$o" $docs 2>/dev/null || { echo "FAIL: the skill uses $o and no doc names it" >&2; fail=1; }
done
# the key rule is there, and nothing tells an agent to read a key
printf '%s\n' "$body" | grep -q 'Never read, print, copy or log an API key file' || { echo "FAIL: the key rule is missing" >&2; fail=1; }
printf '%s\n' "$body" | grep -q -i -E 'cat .*\.key|read the key|export .*API_KEY' && { echo "FAIL: the skill tells an agent to read or export a key" >&2; fail=1; }
[ "$fail" = 0 ] && echo "skill gate: ok" || { echo "skill gate: FAILED" >&2; exit 1; }
