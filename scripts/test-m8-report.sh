#!/bin/sh
# The M8 report's numbers (eval/m8_report.py), on synthetic run directories whose answers are worked out on paper:
#
#   arm A, two runs of a 2-unit item `x`:   run 1 audit 5/10, units u1 verified at attempt 0, u2 refused then verified at attempt 1;
#                                           run 2 audit 0/10 (did not build), u1 refused twice (type-mismatch), u2 agent gave up (no-program), both stuck
#   arm C, one run, audit 10/10, both units verified at attempt 0
#
#   A: oracle pass mean (0.5 + 0.0)/2 = 0.25; units verified 2/4; tried 4, first-attempt compile (u1 run1, u2 run1: refused -> no) = 1/4 = 0.25;
#      after the loop 2/4 = 0.5; pass@1 1/4 = 0.25; verified within 4 = 2/4 = 0.5; attempts 2+... run1: 1+2 = 3, run2: 2+1 = 3, so 3.0 a run
#      tags: type-mismatch 3 (run 1 u2 attempt 0, run 2 u1 twice), agent:gave-up:no-program 1
#   C: pass 1.0; first-attempt compile 1.0; C beats A iff 1.0 - 0.25 > h(A) (h <= 0.25 for two observations 0.5 and 0)
#
# Needs python3. Exit 0 when every number holds.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
d=$(mktemp -d -t cc-m8-XXXXXX)
fail=0
expect() { [ "$2" = "$3" ] || { echo "FAIL: $1: wanted '$3', got '$2'" >&2; fail=1; }; }
mk() { # dir passed of verdict units_verified events...
    wd="$d/$1"; mkdir -p "$wd/journal"; printf '{"plan":"%s/plan.json"}' "$d" > "$wd/run.json"
    printf '{"audit":{"passed":%s,"of":10},"project_verdict":"%s","units_verified":%s,"units_total":2,"seconds":1,"calls":1}' "$2" "$3" "$4" > "$wd/result.json"
    printf '%s\n' "$5" > "$wd/journal/events.jsonl"
}
printf '{"units":[{"id":"u1"},{"id":"u2"}]}' > "$d/plan.json"
ev() { printf '{"kind":"%s","unit":"%s","n":%s,"outcome":"%s","signature":"%s","state":"%s"}\n' "$1" "$2" "$3" "$4" "$5" "$6"; }
e1="$(ev unit_start u1 0 - '' ''; ev attempt u1 0 verified '' ''; ev unit_end u1 0 - '' verified; ev unit_start u2 0 - '' ''; ev attempt u2 0 refused 'type-mismatch:x' ''; ev attempt u2 1 verified '' ''; ev unit_end u2 0 - '' verified)"
e2="$(ev unit_start u1 0 - '' ''; ev attempt u1 0 refused 'type-mismatch:x' ''; ev attempt u1 1 refused 'type-mismatch:y' ''; ev unit_end u1 0 - '' stuck; ev unit_start u2 0 - '' ''; ev attempt u2 0 agent_failed 'agent:gave-up:no-program' ''; ev unit_end u2 0 - '' stuck)"
e3="$(ev unit_start u1 0 - '' ''; ev attempt u1 0 verified '' ''; ev unit_end u1 0 - '' verified; ev unit_start u2 0 - '' ''; ev attempt u2 0 verified '' ''; ev unit_end u2 0 - '' verified)"
mk A-x-1 5 done 2 "$e1"; mk A-x-2 0 stuck 0 "$e2"; mk C-x-1 10 done 2 "$e3"
python3 "$root/eval/m8_report.py" "$d" --boot 500 --json "$d/out.json" > "$d/out.md" || { echo "FAIL: m8_report did not run" >&2; fail=1; }
j() { python3 -c "import json,sys; d=json.load(open('$d/out.json')); print(eval(sys.argv[1]))" "$1"; }
expect "A pass mean" "$(j "d['arms']['A']['pass_mean']")" 0.25
expect "A units verified" "$(j "d['arms']['A']['units_verified']")" 2
expect "A units total" "$(j "d['arms']['A']['units_total']")" 4
expect "A first-attempt compile" "$(j "d['arms']['A']['first_attempt_compile']")" 0.25
expect "A after the loop" "$(j "d['arms']['A']['after_loop_verified']")" 0.5
expect "A pass@1" "$(j "d['arms']['A']['pass_at_1']")" 0.25
expect "A verified within 4" "$(j "d['arms']['A']['verified_within_4']")" 0.5
expect "A attempts per run" "$(j "d['arms']['A']['attempts_per_run']")" 3.0
expect "A type-mismatch tag" "$(j "d['arms']['A']['tags']['type-mismatch']")" 3
expect "A no-program tag" "$(j "d['arms']['A']['tags']['agent:gave-up:no-program']")" 1
expect "C first-attempt compile" "$(j "d['arms']['C']['first_attempt_compile']")" 1.0
expect "rule C vs A computed" "$(j "'C_vs_A' in d['decision']")" True
expect "rule: C beats A (1.0 - 0.25 > h(A) <= 0.25)" "$(j "d['decision']['C_vs_A']['beats']")" True
expect "rule: D vs B absent without those arms" "$(j "'D_vs_B' in d['decision']")" False
rm -rf "$d"
[ "$fail" = 0 ] && echo "m8 report: ok"
exit $fail
