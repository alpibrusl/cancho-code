#!/bin/sh
# Build the one-command tool (docs/build.md) to build/cancho-build. CANCHO is the compiler (the commit in .cancho-rev).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
CANCHO="${CANCHO:-cancho}"
mkdir -p "$root/build"
"$CANCHO" build "$root/tests/programs/build.cho" "$root/src/build.cho" "$root/src/project.cho" "$root/src/plan.cho" "$root/src/driver.cho" \
    "$root/src/checker.cho" "$root/src/signature.cho" "$root/src/loop_check.cho" "$root/src/snapshot.cho" "$root/src/trail.cho" \
    "$root/src/acceptance.cho" "$root/src/splice.cho" "$root/src/pool.cho" "$root/src/parallel.cho" --std -o "$root/build/cancho-build"
