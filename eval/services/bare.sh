#!/bin/sh
# bare.sh [--header] REFERENCE: the project file of a DECOMPOSED service (docs/project.md, "Services"): `edition 7;`, the imports the fixed
# skeleton would have made (skeleton/main.cho's own import lines: one source of truth), the imports REFERENCE itself has (std.hmac, std.utf8),
# then (without --header) REFERENCE's body. Unit tests compile `project.cho` alone, so it must import what it uses; the whole service is then
# built with skeleton/main_bare.cho, which is main.cho without its import lines (files compiled together share their imports, and an import
# twice is an error). `--header` is the scaffold a builder starts from.
d=$(cd "$(dirname "$0")" && pwd)
head=0; [ "$1" = "--header" ] && { head=1; shift; }
echo 'edition 7;'
grep '^import ' "$d/skeleton/main.cho"
grep '^import ' "$1"
[ "$head" = 1 ] || { echo; tail -n +2 "$1" | grep -v '^import '; }
