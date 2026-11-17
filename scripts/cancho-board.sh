#!/bin/sh
# The dashboard's data tool: scripts/cancho-board.sh <run dir> [board.json [prices.json]]
#
# Reads a run directory (what `project` and eval/run_item.py leave: plan.json, run.log, state.txt, trail-<unit>.jsonl, usage.jsonl, run.json,
# audit.txt, build.json) and writes ONE file, board.json (default docs/board.json), that docs/board.html draws. The run directory is only
# read; an output path inside it is refused. Prices default to eval/prices.json. See docs/dashboard.md.
#
# The tool is a cancho program (src/board.cho). This wrapper builds it to build/cancho-board when that is missing or older than its
# sources (CANCHO is the compiler, as in scripts/build-agent.sh), turns the paths into absolute ones with no `..` (the tool wants that:
# the file capability traps on `..`), and runs it.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
[ $# -ge 1 ] && [ $# -le 3 ] || { echo "usage: $0 <run dir> [board.json [prices.json]]" >&2; exit 2; }
[ -d "$1" ] || { echo "cancho-board: $1 is not a directory" >&2; exit 2; }
rd=$(cd "$1" && pwd -P)
out=${2:-$root/docs/board.json}
prices=${3:-$root/eval/prices.json}
od=$(dirname "$out"); [ -d "$od" ] || { echo "cancho-board: no directory $od for the output" >&2; exit 2; }
out=$(cd "$od" && pwd -P)/$(basename "$out")
case "$prices" in /*) ;; *) prices=$(cd "$(dirname "$prices")" && pwd -P)/$(basename "$prices") ;; esac

bin=$root/build/cancho-board
stale=0
[ -x "$bin" ] || stale=1
for f in "$root/src/board.cho" "$root/src/plan.cho" "$root/tests/programs/board.cho"; do
    [ "$f" -nt "$bin" ] && stale=1
done
if [ $stale = 1 ]; then
    CANCHO="${CANCHO:-cancho}"
    command -v "$CANCHO" >/dev/null 2>&1 || { echo "cancho-board: no cancho on PATH; set CANCHO=" >&2; exit 2; }
    mkdir -p "$root/build"
    "$CANCHO" build "$root/tests/programs/board.cho" "$root/src/board.cho" "$root/src/plan.cho" --std -o "$bin" >/dev/null 2>&1 \
        || { echo "cancho-board: the tool did not build" >&2; exit 2; }
fi
exec "$bin" "$rd" "$out" "$prices"
