#!/bin/sh
# extract.sh <file.cho> <name>...: the items of a cancho file that start `fn NAME` or `pub fn NAME` (up to the first line that is just `}`), each followed by a
# blank line. The stand-in agent of the multi item's gate uses it to write ONE unit's functions into its file, as a model does.
f=$1; shift
for n in "$@"; do
    awk -v n="$n" '
        !on && ($0 ~ ("^(pub )?fn " n "[[(]")) { on = 1 }
        on { print }
        on && $0 == "}" { on = 0; print "" }
    ' "$f"
done
