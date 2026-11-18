#!/bin/sh
# Build the MCP server (docs/mcp.md) to build/cancho-mcp, with the two tools it calls: build/cancho-build (the one-command build) and
# build/cancho-board (the dashboard's data tool). CANCHO is the compiler (the commit in .cancho-rev).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
CANCHO="${CANCHO:-cancho}"
mkdir -p "$root/build"
"$CANCHO" build "$root/tests/programs/mcp.cho" "$root/src/mcp.cho" --std -o "$root/build/cancho-mcp"
sh "$root/scripts/build-cancho-build.sh"
"$CANCHO" build "$root/tests/programs/board.cho" "$root/src/board.cho" "$root/src/plan.cho" --std -o "$root/build/cancho-board"
