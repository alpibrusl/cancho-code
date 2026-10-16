#!/bin/sh
# The stand-in agent of the parallel gate (scripts/test-parallel.sh): no model, no network. It reads the task the driver left beside the file, logs the
# unit it was asked to build, keeps a copy of the task it saw, and runs the recipe the case provides for that unit and that request. Recipes sleep (to
# make units overlap in time) and may write `<file>.call/meta.json` when their "first model call has returned" (the cold-start rule).
#
#     agent.sh <recipe-dir> <log> <project.cho>
#
# <recipe-dir>/<unit>.<n>.sh runs on the n-th request for that unit, else <recipe-dir>/<unit>.sh; it gets the project file as $1. The task of that request
# is kept as <recipe-dir>/seen-<unit>.<n>.task. No recipe at all: the agent exits 3 (an agent that fails).
recipes=$1; log=$2; file=$3
unit=$(sed -n 's/^UNIT: //p' "$file.task" | head -1)
echo "$unit" >> "$log"
n=$(grep -c "^$unit\$" "$log")
cp "$file.task" "$recipes/seen-$unit.$n.task" 2>/dev/null
echo "stub-agent: unit $unit request $n" >&2
if [ -f "$recipes/$unit.$n.sh" ]; then sh "$recipes/$unit.$n.sh" "$file"
elif [ -f "$recipes/$unit.sh" ]; then sh "$recipes/$unit.sh" "$file"
else exit 3
fi
