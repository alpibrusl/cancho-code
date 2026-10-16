#!/bin/sh
# The stand-in agent of the parallel gate (scripts/test-parallel.sh): no model, no network. It reads the task the driver left beside the file, logs the
# unit it was asked to build, keeps a copy of the task it saw, and runs the recipe the case provides for that unit and that request. Recipes sleep (to
# make units overlap in time) and may write `<file>.call/meta.json` when their "first model call has returned" (the cold-start rule).
#
#     agent.sh <recipe-dir> <log> [--memory <dir>] <project.cho>
#
# With `--memory <dir>` it does what the native agent does with a memory (docs/memory.md): the person's facts (<dir>/facts.txt) are what it "injected", and it
# leaves them in <project.cho>.call/memory.json, which the driver turns into the attempt's `memory` field.
#
# <recipe-dir>/<unit>.<n>.sh runs on the n-th request for that unit, else <recipe-dir>/<unit>.sh; it gets the project file as $1. The task of that request
# is kept as <recipe-dir>/seen-<unit>.<n>.task. No recipe at all: the agent exits 3 (an agent that fails).
recipes=$1; log=$2
for file; do :; done
mem=""; prev=""
for a; do [ "$prev" = "--memory" ] && mem=$a; prev=$a; done
unit=$(sed -n 's/^UNIT: //p' "$file.task" | head -1)
echo "$unit" >> "$log"
n=$(grep -c "^$unit\$" "$log")
cp "$file.task" "$recipes/seen-$unit.$n.task" 2>/dev/null
echo "stub-agent: unit $unit request $n" >&2
if [ -n "$mem" ] && [ -f "$mem/facts.txt" ]; then
    mkdir -p "$file.call"
    printf '[{"id":"fact-1","text":"%s"}]' "$(head -1 "$mem/facts.txt")" > "$file.call/memory.json"
fi
if [ -f "$recipes/$unit.$n.sh" ]; then sh "$recipes/$unit.$n.sh" "$file"
elif [ -f "$recipes/$unit.sh" ]; then sh "$recipes/$unit.sh" "$file"
else exit 3
fi
