#!/bin/sh
# The stand-in agent of the multi-file gate (scripts/test-multi-file.sh): no model, no network. It reads the task the driver left beside the file it is given
# (the unit's own file: tokens.cho, parser.cho, project.cho), logs which unit it was asked to build, keeps the task it saw and the names of the files in the
# directory it works in, and runs the recipe the case provides for that unit and that request.
#
#     agent.sh <recipe-dir> <log> <file>
#
# <recipe-dir>/<unit>.<n>.sh runs on the n-th request for that unit, else <recipe-dir>/<unit>.sh; it gets the file as $1. The task of that request is kept as
# <recipe-dir>/seen-<unit>.<n>.task and the directory's listing as <recipe-dir>/ls-<unit>.<n>.txt. No recipe at all: the agent exits 3 (an agent that fails).
recipes=$1; log=$2
for file; do :; done
unit=$(sed -n 's/^UNIT: //p' "$file.task" | head -1)
echo "$unit" >> "$log"
n=$(grep -c "^$unit\$" "$log")
cp "$file.task" "$recipes/seen-$unit.$n.task" 2>/dev/null
ls "$(dirname "$file")" | grep '\.cho$' | tr '\n' ' ' > "$recipes/ls-$unit.$n.txt"
echo "$(basename "$file")" > "$recipes/file-$unit.$n.txt"
echo "stub-agent: unit $unit request $n" >&2
if [ -f "$recipes/$unit.$n.sh" ]; then sh "$recipes/$unit.$n.sh" "$file"
elif [ -f "$recipes/$unit.sh" ]; then sh "$recipes/$unit.sh" "$file"
else exit 3
fi
