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
#   OLLAMA_MODEL    the model: REQUIRED, no default. The driver's agent has NO environment, so
#                   an exported variable never arrives: write it in the agent command, as
#                   `fix ... "OLLAMA_MODEL=qwen3.8:27b-mlx scripts/agent-ollama.sh"`. Without it the agent exits 2 before any request; a
#                   model that is not installed is a 404 and `agent_exit` (found on the first end-to-end run).
#   OLLAMA_URL      the server                     (default http://localhost:11434)
#   OLLAMA_NUM_CTX  the context window in tokens   (default 8192; raise it with a primer: `cancho agent-guidelines` is about 5,500 tokens)
#   OLLAMA_NUM_PREDICT  the most tokens one answer may take (default 8192; an unbounded generation held one turn for 900 s). A reply that hits it is a cut-off program, not an answer: it is retried, never written. Keep it well under OLLAMA_NUM_CTX minus the prompt.
#   OLLAMA_SAVE_RAW a file that every raw reply is appended to, whole (default: none), to read what the model really wrote
#   OLLAMA_PRIMER   a file whose text goes first in the prompt (optional)
#
# Exit codes: 0 the file was replaced; 1 the server or the model failed (the file is left as it was — the driver names that
# `unavailable agent` / `agent_exit`, it is not a looping model).
set -u

file="${1:?usage: agent-ollama.sh <project.cho>}"
here=$(cd "$(dirname "$0")" && pwd)

[ -n "${OLLAMA_MODEL:-}" ] || { echo "agent-ollama: OLLAMA_MODEL is not set; name the model (there is no default), e.g. OLLAMA_MODEL=qwen3.8:27b" >&2; exit 2; }

exec python3 - "$here" "$file" "$OLLAMA_MODEL" "${OLLAMA_URL:-http://localhost:11434}" "${OLLAMA_NUM_CTX:-8192}" <<'PY'
import json, os, sys, urllib.request

here, file, model, url, num_ctx = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4].rstrip("/"), int(sys.argv[5])
sys.path.insert(0, here)
import agent_lib

def ask(primer, rest):
    """(reply, cut_off): cut_off when the model stopped because it hit the generation bound, which leaves a program cut off mid-way."""
    body = json.dumps({"model": model, "prompt": primer + rest, "stream": False, "think": False,
                       "options": {"num_ctx": num_ctx, "temperature": 0.2, "num_predict": int(os.environ.get("OLLAMA_NUM_PREDICT", "8192"))}}).encode()
    request = urllib.request.Request(url + "/api/generate", body, {"Content-Type": "application/json"})
    reply = json.load(urllib.request.urlopen(request, timeout=1800))
    agent_lib.save_raw("OLLAMA_SAVE_RAW", reply["response"], reply.get("done_reason"))
    return reply["response"], reply.get("done_reason") == "length"

agent_lib.run(file, ask, "agent-ollama", "OLLAMA_PRIMER", "OLLAMA_SAVE_RAW", "OLLAMA_NUM_PREDICT")
PY
