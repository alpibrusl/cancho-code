#!/bin/sh
# The memory miner: scripts/cancho-lessons.sh --memory <dir> [--legacy] [--min-count N] [--min-runs N] <run dir | directory of run dirs>...
#                   scripts/cancho-lessons.sh --memory <dir> --promote
#
# Reads the journals of past runs (<run dir>/journal/events.jsonl, docs/journal.md) and writes <dir>/lessons.jsonl, the file `--memory <dir>` of the unit agent
# recalls from. With --legacy, a run directory that has no journal but has trails (trail-<unit>.jsonl) is read from those: counts and the success of the
# next attempt, never a fix. See docs/memory.md.
#
# The tool is a cancho program (src/lessons.cho). This wrapper builds it to build/cancho-lessons when that is missing or older than its sources (CANCHO is the
# compiler), turns the paths into absolute ones with no `..` (the tool wants that: the file capability traps on `..`), finds the run directories under the
# paths it is given (up to six levels down), and runs it. The run directories are only read.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
usage() { echo "usage: $0 --memory <dir> [--legacy] [--min-count N] [--min-runs N] <run dir | directory of run dirs>..." >&2; echo "       $0 --memory <dir> --promote" >&2; exit 2; }

memory=""; legacy=0; promote=0; passthru=""; paths=""
while [ $# -gt 0 ]; do
    case "$1" in
        --memory) [ $# -ge 2 ] || usage; memory=$2; shift 2 ;;
        --legacy) legacy=1; shift ;;
        --promote) promote=1; shift ;;
        --min-count|--min-runs) [ $# -ge 2 ] || usage; passthru="$passthru $1 $2"; shift 2 ;;
        --*) usage ;;
        *) [ -d "$1" ] || { echo "cancho-lessons: $1 is not a directory" >&2; exit 2; }
           paths="$paths
$(cd "$1" && pwd -P)"; shift ;;
    esac
done
[ -n "$memory" ] || usage
mkdir -p "$memory"
memory=$(cd "$memory" && pwd -P)

bin=$root/build/cancho-lessons
stale=0
[ -x "$bin" ] || stale=1
for f in "$root/src/lessons.cho" "$root/src/memory.cho" "$root/src/signature.cho" "$root/tests/programs/lessons.cho"; do
    [ "$f" -nt "$bin" ] && stale=1
done
if [ $stale = 1 ]; then
    CANCHO="${CANCHO:-cancho}"
    command -v "$CANCHO" >/dev/null 2>&1 || { echo "cancho-lessons: no cancho on PATH; set CANCHO=" >&2; exit 2; }
    mkdir -p "$root/build"
    "$CANCHO" build "$root/tests/programs/lessons.cho" "$root/src/lessons.cho" "$root/src/memory.cho" "$root/src/signature.cho" --std --backend cranelift -o "$bin" >/dev/null 2>&1 \
        || { echo "cancho-lessons: the tool did not build" >&2; exit 2; }
fi

if [ $promote = 1 ]; then
    exec "$bin" --memory "$memory" --promote
fi

list=$(mktemp)
trap 'rm -f "$list"' EXIT
args=""
for p in $paths; do
    find "$p" -maxdepth 6 -path '*/journal/events.jsonl' -type f | sort | while read -r ev; do
        printf -- '--run\n%s\n' "$(dirname "$(dirname "$ev")")"
    done >> "$list"
    if [ $legacy = 1 ]; then
        find "$p" -maxdepth 5 -name 'trail-*.jsonl' -type f | sort | while read -r t; do
            d=$(dirname "$t")
            [ -f "$d/journal/events.jsonl" ] || printf -- '--trail\n%s\n' "$t"
        done >> "$list"
    fi
done
[ -s "$list" ] || { echo "cancho-lessons: no journal found under the given paths$([ $legacy = 0 ] && echo " (--legacy reads old trails)")" >&2; exit 2; }
# one --run/--trail and its path per pair; no spaces in run names are supported (the arguments are split on lines)
set --
while IFS= read -r kind && IFS= read -r path; do set -- "$@" "$kind" "$path"; done < "$list"
# shellcheck disable=SC2086
exec "$bin" --memory "$memory" $passthru "$@"
