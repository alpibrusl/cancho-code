#!/bin/sh
# The stand-in for a service's acceptance command: accept.sh <checker> <svc-main.cho> <lib.cho> <project.cho>
# builds the project with the fixed main and the lib, runs it, and wants the exit status 41 (app_run(20)).
checker=$1; main=$2; lib=$3; proj=$4
d=$(mktemp -d "${TMPDIR:-/tmp}/cc-svc-XXXXXX") || exit 2
if ! "$checker" build --std "$proj" "$main" "$lib" -o "$d/svc" > "$d/build.txt" 2>&1; then
    echo "the project does not build: $(grep error "$d/build.txt" | head -1)"
    rm -rf "$d"; exit 1
fi
"$d/svc"; rc=$?
rm -rf "$d"
if [ "$rc" != 41 ]; then echo "SCENARIO app_run(20): expected 41 got $rc"; exit 1; fi
echo "[ACCEPTANCE] 1/1 hold"
