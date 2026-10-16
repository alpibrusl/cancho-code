#!/bin/sh
# The service plans gate (docs/project.md, "Services"): each service's hand plan (eval/services/<s>/plan.json) is valid, and BUILDABLE: the
# project driver builds it unit by unit with a STAND-IN agent that appends, per unit, the pieces of the service's reference application that
# eval/services/<s>/pieces.txt assigns to it (eval/services/standin.sh), so every unit's own tests run against a working implementation. The
# integration unit is accepted by the service's acceptance scenarios (eval/service_run.py accept --bare), and the finished project is graded by
# the hidden attack: every check must hold. No model.
#
# Usage: test-service-plans.sh [service ...]   (default: all five; `users` also carries its libraries, eval/services/users/libs.txt)
set -u
CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
CANCHO=$(command -v "$CANCHO"); export CANCHO
pk="${CANCHO_PACKAGES:-$(dirname "$(dirname "$CANCHO")")/packages}"
[ -d "$pk" ] || pk="$(dirname "$(dirname "$(dirname "$CANCHO")")")/packages"
[ -d "$pk" ] || { echo "no cancho packages found; set CANCHO_PACKAGES" >&2; exit 2; }
export CANCHO_PACKAGES="$pk"
exe=$(mktemp -t cc-svcplan-XXXXXX); pc=$(mktemp -t cc-svcplan-pc-XXXXXX)
"$CANCHO" build "$root/tests/programs/project.cho" "$root/src/project.cho" "$root/src/plan.cho" "$root/src/driver.cho" \
    "$root/src/checker.cho" "$root/src/signature.cho" "$root/src/loop_check.cho" "$root/src/snapshot.cho" "$root/src/trail.cho" \
    "$root/src/acceptance.cho" "$root/src/splice.cho" --std --backend cranelift -o "$exe" || { echo "gate did not build" >&2; exit 2; }
"$CANCHO" build "$root/tests/programs/plancheck.cho" "$root/src/plan.cho" --std --backend cranelift -o "$pc" || { echo "plancheck did not build" >&2; exit 2; }

fail=0
expect() { [ "$2" = "$3" ] || { echo "FAIL: $1: wanted '$3', got '$2'" >&2; fail=1; }; }
services="${*:-webhooks jobs invoices kvstore users}"
for s in $services; do
    d="$root/eval/services/$s"
    libs="$pk/http-server/server.cho"
    [ ! -f "$d/libs.txt" ] || for l in $(cat "$d/libs.txt"); do libs="$libs $root/$l"; done
    out=$("$pc" "$d/plan.json" 2>&1); expect "$s: plancheck" "$out" "$(printf '[PLAN]\tvalid')"
    wd=$(mktemp -d -t cc-svcplan-wd-XXXXXX)
    sh "$d/../bare.sh" --header "$d/reference/project.cho" > "$wd/project.cho"
    acc="CANCHO=$CANCHO CANCHO_PACKAGES=$pk PATH=/usr/local/bin:/usr/bin:/bin python3 $root/eval/service_run.py accept --bare $s"
    out=$("$exe" "$CANCHO" "$d/plan.json" "$wd" "sh $d/../standin.sh $d/reference/project.cho $d/pieces.txt" 3 120 "$acc" "$libs" 2>&1); rc=$?
    printf '%s\n' "$out" > "$wd/driver.log"
    expect "$s: driver exit code" "$rc" 0
    expect "$s: verdict" "$(printf '%s\n' "$out" | grep '^\[PROJECT_VERDICT\]' | cut -f2)" done
    n=$(grep -c . "$wd/state.txt" 2>/dev/null); u=$(grep -c '"id"' "$d/plan.json")
    expect "$s: every unit verified" "$n" "$u"
    at=$(CANCHO_PACKAGES=$pk python3 "$root/eval/service_run.py" attack --bare "$s" "$wd/project.cho" 2>&1 | grep '^\[ATTACK\]' | tail -1)
    a=${at#*] }; a=${a%% hold*}
    expect "$s: the hidden attack on the finished project" "${a%/*}" "${a#*/}"
    [ "$fail" = 0 ] && rm -rf "$wd" || echo "kept $wd" >&2
done
rm -f "$exe" "$pc"
[ "$fail" = 0 ] && echo "service plans gate: ok" || { echo "service plans gate: FAILED" >&2; exit 1; }
