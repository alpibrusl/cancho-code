#!/bin/sh
# agent-ollama.sh — the driver's agent, as a local model: read the project file and the checker's refusals, ask the model for the
# corrected file, write the answer back. The checker is the oracle (design §2): nothing here judges the answer, and the loop's §4
# budgets bound it — a looping model stops at the same-signature rule, a struggling one at the ceiling.
#
#     agent-ollama.sh <project.cho>
#
# What the driver gives its agent (scripts/test-agent.sh pins each): the project file as the one argument, the checker's current
# answer for it in <project.cho>.feedback (before every turn, the first included), and no environment at all.
#
# Through Ollama's HTTP API, not the `ollama` binary: with stdout redirected, `ollama run` wrote a spinner and a "Thinking..." trace
# into the answer (issue #12), and the binary panics without a HOME, which the driver's agent does not have (issue #13). The API
# is asked for the answer only (stream and think off), returns it as one JSON field, and needs no environment.
#
#   OLLAMA_MODEL    the model                      (default qwen3.8:27b). The driver's agent has NO environment, so
#                   an exported variable never arrives: write it in the agent command, as
#                   `fix ... "OLLAMA_MODEL=qwen3.8:27b-mlx scripts/agent-ollama.sh"`. Without it the default is used, and a
#                   model that is not installed is a 404 and `agent_exit` (found on the first end-to-end run).
#   OLLAMA_URL      the server                     (default http://localhost:11434)
#   OLLAMA_NUM_CTX  the context window in tokens   (default 8192; raise it with a primer: `cancho agent-guidelines` is about 5,500 tokens)
#   OLLAMA_PRIMER   a file whose text goes first in the prompt (optional)
#
# Exit codes: 0 the file was replaced; 1 the server or the model failed (the file is left as it was — the driver names that
# `unavailable agent` / `agent_exit`, it is not a looping model).
set -u

file="${1:?usage: agent-ollama.sh <project.cho>}"

exec python3 - "$file" "${OLLAMA_MODEL:-qwen3.8:27b}" "${OLLAMA_URL:-http://localhost:11434}" "${OLLAMA_NUM_CTX:-8192}" <<'PY'
import json, os, re, sys, urllib.request

file, model, url, num_ctx = sys.argv[1], sys.argv[2], sys.argv[3].rstrip("/"), int(sys.argv[4])
source = open(file, encoding="utf-8").read()

# The checker's current refusals, one line each; if the feedback is not the JSON the checker normally prints, the text itself.
feedback = ""
try:
    raw = open(file + ".feedback", encoding="utf-8").read()
    try:
        refusals = json.loads(raw).get("refused", [])
        lines = source.split("\n")
        for r in refusals[:8]:
            line, col = r["position"]["line"], r["position"]["column"]
            feedback += "- line %d, column %d: %s (rule %s)\n" % (line, col, r["message"], r["rule"])
            # The source line itself, with a caret under the column: "line 9, column 39" is hard to find by counting.
            if 1 <= line <= len(lines):
                feedback += "    " + lines[line - 1] + "\n    " + " " * (col - 1) + "^\n"
    except (ValueError, KeyError, AttributeError):
        feedback = raw[:1500]
except OSError:
    pass

# An optional primer, first in the prompt: the language's own page for an agent (`cancho agent-guidelines > file`). A model that
# has never seen cancho repeats the same refusal; an unreadable primer is an error, not a silent skip, so a typo in the path cannot
# pass for a model that "did not use" it.
primer = ""
if os.environ.get("OLLAMA_PRIMER"):
    try:
        primer = open(os.environ["OLLAMA_PRIMER"], encoding="utf-8").read() + "\n\n"
    except OSError as e:
        sys.stderr.write("agent-ollama: cannot read OLLAMA_PRIMER: %s\n" % e)
        sys.exit(1)

prompt = primer + ("The cancho program below is refused by its compiler. Reply with the complete corrected file and nothing else: "
          "no markdown fences, no explanation.\n")
if feedback:
    prompt += "The compiler's current refusals:\n" + feedback
prompt += "---\n" + source + "---\n"

body = json.dumps({"model": model, "prompt": prompt, "stream": False, "think": False,
                   "options": {"num_ctx": num_ctx, "temperature": 0.2}}).encode()
try:
    request = urllib.request.Request(url + "/api/generate", body, {"Content-Type": "application/json"})
    answer = json.load(urllib.request.urlopen(request, timeout=1800))["response"]
except Exception as e:
    sys.stderr.write("agent-ollama: %s\n" % e)
    sys.exit(1)

# A markdown fence is the one shape a model reliably adds and the checker reliably refuses; stripped here, not burned as an attempt.
answer = re.sub(r"^```[a-z]*\n?", "", answer.strip())
answer = re.sub(r"\n?```\s*$", "", answer)
tmp = file + ".agent.tmp"
open(tmp, "w", encoding="utf-8").write(answer + "\n")
os.replace(tmp, file)
PY
