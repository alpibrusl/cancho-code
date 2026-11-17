#!/bin/sh
# A cancho gap found by the multi-file work (docs/multi-file.md): `cancho test` for the tests of a module whose root file imports that module.
#
#   CANCHO=<compiler> sh repro.sh
#
# The run with project.cho is refused: the runner `cancho test` writes (a root program that imports each module that has tests) binds `store`, and
# project.cho binds `store` too. Without project.cho it runs. Expected by anyone who reads docs/modules.md ("a module's imports are the union of what its
# files import"): both runs pass, the second import being the same one.
cd "$(dirname "$0")" || exit 2
echo "--- with the root file that imports store:"
"${CANCHO:-cancho}" test --std project.cho store.cho tests-store.cho 2>&1 | grep -v '^ld:' | head -6
echo "--- without it:"
"${CANCHO:-cancho}" test --std store.cho tests-store.cho 2>&1 | grep -v '^ld:' | head -6
