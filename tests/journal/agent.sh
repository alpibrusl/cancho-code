#!/bin/sh
# The stand-in agent of the journal gate (scripts/test-journal.sh): no model, no network, no key. Like tests/buildcmd/agent.sh (a plan call
# copies a plan, a unit call runs the unit's recipe), and, when <recipe-dir>/sidecars exists, it leaves beside the project file what the native
# agent leaves (docs/journal.md "The agent's sidecars"): <file>.call/prompt.txt, reply.txt, meta.json, primer.txt, and it speaks on stderr.
#
#     agent.sh <recipe-dir> <log> [agent options...] <file>
recipes=$1; log=$2; shift 2
for last; do :; done
mode=edit
prev=""
for a; do [ "$prev" = "--mode" ] && mode=$a; prev=$a; done
if [ "$mode" = plan ]; then
    echo PLAN >> "$log"
    sh "$recipes/plan.sh" "$last"
    exit $?
fi
file=$last
unit=$(sed -n 's/^UNIT: //p' "$file.task" | head -1)
echo "$unit" >> "$log"
n=$(grep -c "^$unit\$" "$log")
if [ -f "$recipes/sidecars" ]; then
    d="$file.call"
    printf 'PROMPT %s try %s\n--- task ---\n' "$unit" "$n" > "$d/prompt.txt"; cat "$file.task" >> "$d/prompt.txt"
    if [ -f "$recipes/bigreply" ]; then head -c 300000 /dev/zero | tr '\0' 'x' > "$d/reply.txt"; else printf 'REPLY %s try %s\n' "$unit" "$n" > "$d/reply.txt"; fi
    printf '{"samples":1,"tokens":{"in":%s,"out":20,"thinking":3,"cache_write":0,"cache_read":9000},"stop":"end_turn","outcome":"written","primer":true}\n' "$((100 + n))" > "$d/meta.json"
    printf 'THE-PRIMER-TEXT-ONCE\n' > "$d/primer.txt"
fi
echo "agent says: unit $unit try $n" >&2
if [ -f "$recipes/$unit.$n.sh" ]; then sh "$recipes/$unit.$n.sh" "$file"
elif [ -f "$recipes/$unit.sh" ]; then sh "$recipes/$unit.sh" "$file"
else exit 3
fi
