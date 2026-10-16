#!/bin/sh
# Start the MCP server (docs/mcp.md) with a person's choices. The model never sees these: they are this command line.
#
#   scripts/cancho-mcp.sh --root DIR --provider P --model M --key-file FILE [options]
#
#   --root DIR          the one directory the server works in: briefs are read from it, every run is a directory in it (absolute, letters, digits and . _ / + : = @ % , - only)
#   --provider, --model the provider and model every build uses (there is no default for either)
#   --key-file FILE     the API key's file; it is read by the agent only, never by the server, never returned
#   --primer FILE       the language page the agent is given (cached by the provider)
#   --workspace ID      a workspace id, for a key not scoped to one
#   --max-tokens N      the bound on one answer (16000)
#   --guide FILE        how to write a plan (docs/plan-guide.md);  --review-guide FILE turns the blind review of the plan's cases on
#   --attempts N, --agent-seconds N   per unit (6, 300);  --max-runs N   runs alive at once (2)
#   --jobs N            units built at once within a run (1 to 64; not given: build's own default, 4; docs/parallel.md)
#
# CANCHO is the compiler; the agent, the build tool, the board tool and the server are built to build/ when missing.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
CANCHO=$(command -v "${CANCHO:-cancho}") || { echo "cancho-mcp: no cancho on PATH; set CANCHO=" >&2; exit 2; }
export CANCHO
root="" provider="" model="" key="" primer="" workspace="" maxtok=16000 guide="$here/docs/plan-guide.md" rguide="" attempts=6 secs=300 maxruns=2 jobs=
while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || { echo "cancho-mcp: $1 needs a value" >&2; exit 2; }
    case "$1" in
        --root) root=$2 ;; --provider) provider=$2 ;; --model) model=$2 ;; --key-file) key=$2 ;; --primer) primer=$2 ;;
        --workspace) workspace=$2 ;; --max-tokens) maxtok=$2 ;; --guide) guide=$2 ;; --review-guide) rguide=$2 ;;
        --attempts) attempts=$2 ;; --agent-seconds) secs=$2 ;; --max-runs) maxruns=$2 ;; --jobs) jobs=$2 ;;
        *) echo "cancho-mcp: unknown option $1" >&2; exit 2 ;;
    esac
    shift 2
done
[ -n "$root" ] && [ -n "$provider" ] && [ -n "$model" ] && [ -n "$key" ] || { echo "cancho-mcp: --root, --provider, --model and --key-file are required" >&2; exit 2; }
[ -d "$root" ] || { echo "cancho-mcp: $root is not a directory" >&2; exit 2; }
root=$(cd "$root" && pwd -P)
[ -x "$here/build/cancho-agent" ] || sh "$here/scripts/build-agent.sh" >&2
{ [ -x "$here/build/cancho-mcp" ] && [ -x "$here/build/cancho-build" ] && [ -x "$here/build/cancho-board" ]; } || sh "$here/scripts/build-cancho-mcp.sh" >&2
agent="$here/scripts/cancho-agent.sh --key-file $key"
[ -n "$primer" ] && agent="$agent --primer $primer"
[ -n "$workspace" ] && agent="$agent --workspace $workspace"
agent="$agent --max-tokens $maxtok"
set -- --root "$root" --build-bin "$here/build/cancho-build" --board-bin "$here/build/cancho-board" --prices "$here/eval/prices.json" \
    --checker "$CANCHO" --agent-command "$agent" --provider "$provider" --model "$model" --guide "$guide" --attempts "$attempts" --agent-seconds "$secs" --max-runs "$maxruns"
[ -n "$rguide" ] && set -- "$@" --review-guide "$rguide"
[ -n "$jobs" ] && set -- "$@" --jobs "$jobs"
exec "$here/build/cancho-mcp" "$@"
