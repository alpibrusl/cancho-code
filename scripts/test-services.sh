#!/bin/sh
# The services gate (docs/parity.md P7): the acceptance and the hidden attack of each service, run by eval/service_run.py, against
#
#   reference   a working application (eval/services/<s>/reference/project.cho): passes its acceptance scenarios AND its attack, every check
#   stub        the stub application (answers 404 to everything): FAILS both, finishes, does not hang or crash the runner
#   broken      a project that does not build: reported as `does not build` with the compiler's first error, exit 1
#   demo        eval/demo.py walks a scripted session against the reference and every step gets an HTTP answer
#
# The attack scripts' own mutation checks (403 for a foreign id, an unknown field accepted, an off-by-one body limit, ...) were run by their authors
# and are listed in each service's report, not repeated here: this gate pins that the references pass and that the stub does not.
set -u
CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "no python3 on PATH" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
export CANCHO
fail=0
expect() { [ "$2" = "$3" ] || { echo "FAIL: $1: wanted '$3', got '$2'" >&2; fail=1; }; }
run() { python3 "$root/eval/service_run.py" "$@" 2>&1; }

for s in jobs invoices webhooks kvstore users; do
    ref="$root/eval/services/$s/reference/project.cho"
    for mode in accept attack; do
        out=$(run $mode $s "$ref"); rc=$?
        label=$(printf '%s' "$mode" | tr a-z A-Z); [ "$mode" = accept ] && label=ACCEPTANCE
        n=$(printf '%s\n' "$out" | grep "^\[$label\]" | tail -1)
        expect "$s $mode: exit code on the reference" "$rc" 0
        case "$n" in *"hold"*) a=${n#*] }; a=${a%% hold*}; expect "$s $mode: every check holds on the reference" "${a%/*}" "${a#*/}" ;; *) echo "FAIL: $s $mode: no result line ($out)" >&2; fail=1 ;; esac
        out=$(run $mode $s "$root/eval/services/skeleton/app_stub.cho"); rc=$?
        [ "$rc" != 0 ] || { echo "FAIL: $s $mode: the stub application passed" >&2; fail=1; }
        case "$out" in *"[$label]"*) ;; *) echo "FAIL: $s $mode: the stub run printed no result line" >&2; fail=1 ;; esac
    done
done

# the skeleton of a decomposed service (docs/project.md, "Services") is main.cho without its import lines, and the reference applications
# build and pass their acceptance scenarios behind it once they carry those imports themselves (bare.sh): the decomposed path's fixed points
[ "$(grep -v '^import ' "$root/eval/services/skeleton/main.cho")" = "$(cat "$root/eval/services/skeleton/main_bare.cho")" ] || { echo "FAIL: skeleton/main_bare.cho is not main.cho without its imports" >&2; fail=1; }
bd=$(mktemp -d -t cc-services-bare-XXXXXX)
sh "$root/eval/services/bare.sh" "$root/eval/services/kvstore/reference/project.cho" > "$bd/project.cho"
out=$(run accept --bare kvstore "$bd/project.cho"); rc=$?
expect "kvstore bare: acceptance exit code" "$rc" 0
case "$out" in *"hold"*) ;; *) echo "FAIL: kvstore bare: no result line ($out)" >&2; fail=1 ;; esac
rm -rf "$bd"

d=$(mktemp -d -t cc-services-XXXXXX)
printf 'edition 7;\nfn app_new() -> [] int { return true; }\n' > "$d/broken.cho"
out=$(run accept jobs "$d/broken.cho"); rc=$?
expect "broken: exit code" "$rc" 1
case "$out" in *"does not build"*) ;; *) echo "FAIL: broken: not reported as a build failure ($out)" >&2; fail=1 ;; esac

out=$(python3 "$root/eval/demo.py" kvstore "$root/eval/services/kvstore/reference/project.cho" --port 18990 2>&1); rc=$?
expect "demo: exit code" "$rc" 0
case "$out" in *"HTTP 201"*"HTTP 404"*) ;; *) echo "FAIL: demo: the session shows no responses ($out)" >&2; fail=1 ;; esac
rm -rf "$d"
[ "$fail" = 0 ] && echo "services gate: ok" || { echo "services gate: FAILED" >&2; exit 1; }
