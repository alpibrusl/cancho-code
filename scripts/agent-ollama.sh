#!/bin/sh
# agent-ollama.sh — the driver's agent, as a local model: read the project
# file, ask the model to fix it, write the answer back. The checker is the
# oracle (design §2): nothing here judges the answer, and the loop's §4
# budgets bound it — a looping model stops at the same-signature rule, a
# struggling one at the ceiling.
#
#     agent-ollama.sh <project.cho>
#
# The model comes from the environment (OLLAMA_MODEL, default
# qwen3.8:27b — a local model, no key, no network egress: everything
# happens on the machine).
#
# The prompt asks for the complete file back because the driver overwrites
# the project file with the model's answer; a diff-format answer would be
# written as-is and refused by the checker, which is the oracle catching
# the shape, exactly as designed.
set -u

file="${1:?usage: agent-ollama.sh <project.cho>}"
model="${OLLAMA_MODEL:-qwen3.8:27b}"
tmp=$(mktemp -t cc-ollama-XXXXXX)

{
    printf 'The cancho program below has one or more errors that its compiler refuses.\n'
    printf 'Reply with the complete corrected file and nothing else — no markdown fences, no explanation.\n'
    printf -- '---\n'
    cat "$file"
    printf -- '---\n'
} | ollama run "$model" > "$tmp" || { rm -f "$tmp"; exit 1; }

# A markdown fence is the one shape a model reliably adds and the checker
# reliably refuses; stripped here rather than burned into an attempt.
sed -i -e 's/^```[a-z]*$//' -e 's/^```$//' "$tmp"
mv "$tmp" "$file"
