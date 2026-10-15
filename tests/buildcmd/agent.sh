#!/bin/sh
# The stand-in agent of the build gate (scripts/test-build.sh): no model, no network, no key. It is the plan agent (`--mode plan ... <out>`)
# and the unit agent (`... <project.cho>`) in one, as cancho-agent is.
#
#     agent.sh <recipe-dir> <log> [agent options...] <file>
#
# The last argument is the file. Every call logs one word to <log>: `PLAN`, or the unit's name. A plan call saves its arguments to
# <recipe-dir>/plan.args and runs <recipe-dir>/plan.sh with the file as $1 (no plan.sh: exit 1, as an agent that cannot reach the API).
# A unit call saves its arguments to <recipe-dir>/unit.args and runs the unit's recipe exactly as tests/project/agent.sh does.
recipes=$1; log=$2; shift 2
for last; do :; done
mode=edit
prev=""
for a; do [ "$prev" = "--mode" ] && mode=$a; prev=$a; done
if [ "$mode" = plan ]; then
    echo PLAN >> "$log"
    echo "$*" > "$recipes/plan.args"
    if [ -f "$recipes/plan.sh" ]; then sh "$recipes/plan.sh" "$last"; else echo "cancho-agent: cannot reach the API: connect" >&2; exit 1; fi
    exit $?
fi
echo "$*" > "$recipes/unit.args"
file=$last
unit=$(sed -n 's/^UNIT: //p' "$file.task" | head -1)
echo "$unit" >> "$log"
n=$(grep -c "^$unit\$" "$log")
if [ -f "$recipes/$unit.$n.sh" ]; then sh "$recipes/$unit.$n.sh" "$file"
elif [ -f "$recipes/$unit.sh" ]; then sh "$recipes/$unit.sh" "$file"
else exit 3
fi
