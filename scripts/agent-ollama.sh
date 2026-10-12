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
#   OLLAMA_MODEL    the model                      (default qwen3.8:27b)
#   OLLAMA_URL      the server                     (default http://localhost:11434)
#   OLLAMA_NUM_CTX  the context window in tokens   (default 8192)
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
        feedback = "".join("- line %d, column %d: %s (rule %s)\n" % (r["position"]["line"], r["position"]["column"], r["message"], r["rule"]) for r in refusals[:8])
    except (ValueError, KeyError, AttributeError):
        feedback = raw[:1500]
except OSError:
    pass

prompt = ("The cancho program below is refused by its compiler. Reply with the complete corrected file and nothing else: "
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
