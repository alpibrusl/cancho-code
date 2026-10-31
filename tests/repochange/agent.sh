#!/bin/sh
# The stand-in agent of the repo.patch gate (scripts/test-repo-patch.sh): no model, no network, no key.
#
#     agent.sh <recipe-dir> <log> [agent options...] <bundle>
#
# The last argument is the bundle the driver wrote (`=== FILE <path>` and the file's text); the agent answers by replacing it with the envelope. Call N
# (counted in <log>) saves what it was given (`args.N`, `task.N`, `feedback.N`, `bundle.N` in the recipe directory), exits with the number in
# <recipe-dir>/exit.N when there is one, and otherwise copies <recipe-dir>/reply.N over the bundle (no such file: exit 3).
recipes=$1; log=$2; shift 2
for last; do :; done
echo call >> "$log"
n=$(wc -l < "$log" | tr -d ' ')
echo "$*" > "$recipes/args.$n"
cp "$last.task" "$recipes/task.$n" 2>/dev/null
cp "$last.feedback" "$recipes/feedback.$n" 2>/dev/null
cp "$last" "$recipes/bundle.$n"
if [ -f "$recipes/exit.$n" ]; then exit "$(cat "$recipes/exit.$n")"; fi
[ -f "$recipes/reply.$n" ] || exit 3
cp "$recipes/reply.$n" "$last"
