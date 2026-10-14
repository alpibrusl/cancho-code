#!/bin/sh
# agent-anthropic.sh — the driver's agent, as Claude through Anthropic's Messages API: read the project file, the unit's task and the
# checker's refusals, ask for the complete file, write the program back. The checker is the oracle (design section 2).
#
#     agent-anthropic.sh <project.cho>
#
# THE KEY IS READ FROM A FILE, never from the environment or the command line. The driver's agent has no environment (nothing exported
# reaches it), and a key written into the agent command would be in the process list for every local user. So:
#
#     install -m 600 /dev/null ~/.config/cancho-code/anthropic.key      # then put the key in it, without echoing it into a shell
#     fix ... "ANTHROPIC_KEY_FILE=$HOME/.config/cancho-code/anthropic.key ANTHROPIC_MODEL=claude-haiku-5-5 $(pwd)/scripts/agent-anthropic.sh"
#
# The script refuses a key file that group or others can read (before any request), a missing or empty one, and prints the key nowhere:
# not in its output, not in an error, not in the saved raw replies. An HTTP error shows the API's own message and the status.
#
#   ANTHROPIC_KEY_FILE   the key file                      (required)
#   ANTHROPIC_MODEL      the model                         (default claude-haiku-5-5, the cheapest to test with)
#   ANTHROPIC_URL        the API host                      (default https://api.anthropic.com)
#   ANTHROPIC_MAX_TOKENS the most tokens one answer may take (default 8192); a reply that stops there is a program cut off: retried, never written
#   ANTHROPIC_WORKSPACE_ID the workspace id, sent as anthropic-workspace-id: needed when the key is not scoped to a workspace (the API answers 400
#                        and says so); not needed for a workspace-scoped key
#   ANTHROPIC_PRIMER     a file whose text goes first, as a cached system block (optional; `cancho agent-guidelines > file`)
#   ANTHROPIC_SAVE_RAW   a file that every raw reply is appended to, whole (default: none)
#
# The primer is sent as a `system` block marked for caching: it is the same on every call of a run, so every call after the first pays the
# cached-input price for it, not the full one.
#
# Exit codes: 0 the file was replaced; 1 anything else (the file is left as it was; the driver names that `unavailable agent`).
set -u

file="${1:?usage: agent-anthropic.sh <project.cho>}"
here=$(cd "$(dirname "$0")" && pwd)

exec python3 - "$here" "$file" <<'PY'
import json, os, stat, sys, urllib.error, urllib.request

here, file = sys.argv[1], sys.argv[2]
sys.path.insert(0, here)
import agent_lib

NAME = "agent-anthropic"

def fail(message):
    sys.stderr.write("%s: %s\n" % (NAME, message))
    sys.exit(1)

# The key: from a file only the owner can read. Checked before anything is sent.
path = os.environ.get("ANTHROPIC_KEY_FILE")
if not path:
    fail("ANTHROPIC_KEY_FILE is not set: name a file that holds the key (the agent has no environment, so ANTHROPIC_API_KEY cannot reach it)")
try:
    mode = os.stat(path).st_mode
except OSError as e:
    fail("cannot read ANTHROPIC_KEY_FILE %s: %s" % (path, e.strerror))
if mode & (stat.S_IRWXG | stat.S_IRWXO):
    fail("%s has permissions %s: group or others can read it. chmod 600 it, and treat the key as exposed if it was ever readable" % (path, oct(mode & 0o777)))
try:
    key = open(path, encoding="utf-8").read().strip()
except OSError as e:
    fail("cannot read ANTHROPIC_KEY_FILE %s: %s" % (path, e.strerror))
if not key:
    fail("ANTHROPIC_KEY_FILE %s is empty" % path)

model = os.environ.get("ANTHROPIC_MODEL", "claude-haiku-5-5")
url = os.environ.get("ANTHROPIC_URL", "https://api.anthropic.com").rstrip("/")
max_tokens = int(os.environ.get("ANTHROPIC_MAX_TOKENS", "8192"))

def ask(primer, rest):
    """(reply, cut_off): cut_off when the model stopped because it hit max_tokens, which leaves a program cut off mid-way."""
    body = {"model": model, "max_tokens": max_tokens, "messages": [{"role": "user", "content": rest}]}
    if primer:
        body["system"] = [{"type": "text", "text": primer, "cache_control": {"type": "ephemeral"}}]
    headers = {"content-type": "application/json", "x-api-key": key, "anthropic-version": "2023-06-01"}
    if os.environ.get("ANTHROPIC_WORKSPACE_ID"):
        headers["anthropic-workspace-id"] = os.environ["ANTHROPIC_WORKSPACE_ID"]
    request = urllib.request.Request(url + "/v1/messages", json.dumps(body).encode(), headers)
    try:
        reply = json.load(urllib.request.urlopen(request, timeout=1800, context=agent_lib.ssl_context()))
    except urllib.error.HTTPError as e:
        # The API's own message, and the status: never the request, which holds the key.
        try:
            detail = json.load(e)["error"]
            detail = "%s: %s" % (detail.get("type"), detail.get("message"))
        except Exception:
            detail = "no message"
        fail("HTTP %d from the API (%s)" % (e.code, detail))
    except urllib.error.URLError as e:
        fail("cannot reach the API: %s" % getattr(e, "reason", e))
    text = "".join(b.get("text", "") for b in reply.get("content", []) if b.get("type") == "text")
    # the usage the API reports (input, output, and the cached-prefix tokens) is kept with the reply: it is what a call cost
    agent_lib.save_raw("ANTHROPIC_SAVE_RAW", text, "%s; usage %s" % (reply.get("stop_reason"), json.dumps(reply.get("usage"))))
    return text, reply.get("stop_reason") == "max_tokens"

agent_lib.run(file, ask, NAME, "ANTHROPIC_PRIMER", "ANTHROPIC_SAVE_RAW", "ANTHROPIC_MAX_TOKENS")
PY
