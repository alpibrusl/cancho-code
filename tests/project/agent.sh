#!/bin/sh
# The stand-in agent of the project gate (scripts/test-project.sh): no model. It reads the task the driver left beside the file,
# logs which unit it was asked to build, and runs the recipe the case provides for that unit and that attempt.
#
#     agent.sh <recipe-dir> <log> <project.cho>
#
# <recipe-dir>/<unit>.<n>.sh runs on the n-th request for that unit (n = 1, 2, ...), else <recipe-dir>/<unit>.sh; it gets the project
# file as $1. No recipe at all: the agent exits 3 (an agent that fails).
recipes=$1; log=$2; file=$3
unit=$(sed -n 's/^UNIT: //p' "$file.task" | head -1)
echo "$unit" >> "$log"
n=$(grep -c "^$unit\$" "$log")
if [ -f "$recipes/$unit.$n.sh" ]; then sh "$recipes/$unit.$n.sh" "$file"
elif [ -f "$recipes/$unit.sh" ]; then sh "$recipes/$unit.sh" "$file"
else exit 3
fi
