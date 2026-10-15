#!/bin/sh
# The stand-in agent of the service plans (scripts/test-service-plans.sh): no model. Run as
#     standin.sh <reference project.cho> <pieces file> <project.cho>
# it reads the unit from <project.cho>.task and appends that unit's pieces of the reference application (eval/services/pieces.sh).
ref=$1; pieces=$2; file=$3
unit=$(sed -n 's/^UNIT: //p' "$file.task" | head -1)
d=$(cd "$(dirname "$0")" && pwd)
sh "$d/pieces.sh" "$ref" "$pieces" "$unit" >> "$file"
