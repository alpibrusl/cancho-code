#!/bin/sh
# The project gate (docs/parity.md P5, docs/project.md): the driver that builds a plan unit by unit, against a stand-in agent that
# runs a shell recipe per unit and per attempt (tests/project/agent.sh). No model. The checker is the real compiler.
#
#   happy       three units in dependency order: done, exit 0, the functions are in project.cho, the state names all three
#   order       the plan lists the dependent first: dependencies are still built first (b, a, c: file order among the ready ones)
#   examples    a unit that type-checks but fails its own examples is not verified: a second attempt, `[ACCEPTANCE] fail` then pass
#   regression  building b breaks a: after b verifies the sweep finds it (`a regressed`), a is rebuilt, the project ends done
#   resume      the agent fails on c: provider_error, exit 4, the state keeps a and b; a second run keeps them (no rebuild) and builds c
#   stuck       a never verifies: it fails, an independent unit (b) is still built, its dependent (c) is skipped; stuck, exit 1
#   agent log   the agent's standard error is kept per unit, per attempt (`agent-<id>.log`, header `=== attempt N: <how>`), bounded to the last 4096
#               bytes of a turn, also for a unit whose agent failed (the provider error's cause is there); run.log-style `[AGENT_LOG]` line for a unit that did not verify
#   option      a unit whose examples are Option results: run as a match; a wrong Some value is refused, the right answer accepted
#   described   a unit's description reaches the agent in the task, decoded, with the instruction not to write tests
#   rawtests    a unit's own `tests` replace the example-derived ones; region parameters in a signature are accepted
#   service     a plan with an `integration` unit (docs/plan.md): the pure unit is tested with the lib files beside it, the integration unit has no
#               examples and is judged by the acceptance command (builds the whole thing with a fixed main), its scenario output reaches the agent
#               as feedback, a failing scenario is retried within the attempt ceiling, never-satisfied is `stuck`, a rerun keeps both units
#   retry       a stuck unit re-opened with `--retry <unit> --hint "..."`: its state is reset, ONLY it and the units that need it are worked on, the hint
#               reaches the agent's task (one `HINT:` line per line, never through a shell), the attempt numbers and the trail go on from the earlier
#               attempts, its budget (attempts, same-signature) starts fresh, and the journal says so (`hint` on its attempts, `retry` on its unit_start)
#   retry verified  a verified unit re-opened: it is rebuilt, the units that need it are checked again after it, one that broke is rebuilt
#   patch       `--patch <unit> <file>`: the person's code is spliced like a model's reply and verified with no agent call; a refused one (compiler or
#               examples) leaves project.cho and the state as they were and shows the refusal; the journal records outcome `human_patch`
#   redo usage  a unit that is not in the plan, an empty hint, --retry with --patch, a hint with no --retry, a patch file that is not there: exit 2, the
#               work directory byte-identical, the agent never asked
#   no plan     an invalid plan: its errors, then no_plan, exit 3, the agent never asked
#   usage       no arguments, and a plan that is not there: exit 2
#
# Needs the real cancho as CANCHO. Exit 0 every case held.
set -u

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
SRC="${PROJECT_SRC:-$root/src}"   # a directory to take src/ from: how the mutation runs judge a broken copy
exe=$(mktemp -t cc-project-XXXXXX)
"$CANCHO" build "$root/tests/programs/project.cho" "$SRC/project.cho" "$SRC/plan.cho" "$SRC/driver.cho" \
    "$SRC/checker.cho" "$SRC/signature.cho" "$SRC/loop_check.cho" "$SRC/snapshot.cho" "$SRC/trail.cho" \
    "$SRC/acceptance.cho" "$SRC/splice.cho" --std --backend cranelift -o "$exe" || { echo "gate did not build" >&2; exit 2; }

fail=0
expect() { [ "$2" = "$3" ] || { echo "FAIL: $1: wanted '$3', got '$2'" >&2; fail=1; }; }
T="$root/tests/project"
units() { printf '%s\n' "$1" | grep '^\[UNIT\]' | cut -f2,3 | tr '\t' ':' | tr '\n' ' ' | sed 's/ $//'; }
verdict() { printf '%s\n' "$1" | grep '^\[PROJECT_VERDICT\]' | cut -f2; }
order() { tr '\n' ' ' < "$1" | sed 's/ $//'; }

# a fresh work directory with a copy of the good recipes; echoes "<workdir> <recipes> <log>"
mk() {
    wd=$(mktemp -d -t cc-project-wd-XXXXXX); rc=$(mktemp -d -t cc-project-rc-XXXXXX); lg="$wd/agent.log"
    cp "$T"/recipes-good/*.sh "$rc"/; : > "$lg"
    echo "$wd $rc $lg"
}
run() { # plan wd recipes log
    "$exe" "$CANCHO" "$1" "$2" "sh $T/agent.sh $3 $4" 4 60 2>&1
}

# happy
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$(run "$T/plan.json" "$wd" "$rc" "$lg"); r=$?
expect "happy: exit code" "$r" 0
expect "happy: verdict" "$(verdict "$out")" done
expect "happy: agent order" "$(order "$lg")" "a b c"
expect "happy: unit lines" "$(units "$out")" "a:building a:verified b:building b:verified c:building c:verified"
for f in double is_big big_double; do grep -q "fn $f" "$wd/project.cho" || { echo "FAIL: happy: project.cho has no $f" >&2; fail=1; }; done
expect "happy: the state" "$(order "$wd/state.txt")" "verified a verified b verified c"
[ -f "$wd/main.cho" ] || { echo "FAIL: happy: no main.cho" >&2; fail=1; }
expect "happy: unit a's trail" "$(wc -l < "$wd/trail-a.jsonl" | tr -d ' ')" 1
rm -rf "$wd" "$rc"

# order
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$(run "$T/plan-reordered.json" "$wd" "$rc" "$lg"); r=$?
expect "order: exit code" "$r" 0
expect "order: agent order" "$(order "$lg")" "b a c"
rm -rf "$wd" "$rc"

# examples
set -- $(mk); wd=$1; rc=$2; lg=$3
printf 'printf "\\nfn double(x: int) -> [] int { return x + 2; }\\n" >> "$1"\n' > "$rc/a.1.sh"
printf 'sed -i.bak "s/x + 2/x * 2/" "$1"\n' > "$rc/a.2.sh"
out=$(run "$T/plan.json" "$wd" "$rc" "$lg"); r=$?
expect "examples: exit code" "$r" 0
expect "examples: agent order" "$(order "$lg")" "a a b c"
expect "examples: acceptance lines for a" "$(printf '%s\n' "$out" | tr '\t' ':' | sed -n '/^\[UNIT\]:a:building/,/^\[UNIT\]:a:verified/p' | grep ACCEPTANCE | cut -d: -f2 | tr '\n' ' ')" "fail pass "
expect "examples: a took two attempts" "$(printf '%s\n' "$out" | grep 'ISSUE_VERDICT.*verified' | head -1 | cut -f3)" "attempts 2"
rm -rf "$wd" "$rc"

# regression: building b breaks a's function
set -- $(mk); wd=$1; rc=$2; lg=$3
printf 'printf "\\nfn is_big(x: int) -> [] bool { return x > 10; }\\n" >> "$1"; sed -i.bak "s/x \\\\* 2/x * 3/" "$1"\n' > "$rc/b.sh"
printf 'sed -i.bak "s/x \\\\* 3/x * 2/" "$1"\n' > "$rc/a.2.sh"
out=$(run "$T/plan.json" "$wd" "$rc" "$lg"); r=$?
expect "regression: exit code" "$r" 0
expect "regression: verdict" "$(verdict "$out")" done
expect "regression: agent order" "$(order "$lg")" "a b a c"
case "$(units "$out")" in *"b:verified a:regressed"*) ;; *) echo "FAIL: regression: no 'a:regressed' right after b verified: $(units "$out")" >&2; fail=1 ;; esac
grep -q 'x \* 2' "$wd/project.cho" || { echo "FAIL: regression: double was not repaired" >&2; fail=1; }
rm -rf "$wd" "$rc"

# resume: c's agent fails the first time, then works
set -- $(mk); wd=$1; rc=$2; lg=$3
mv "$rc/c.sh" "$rc/c.sh.later"
out=$(run "$T/plan.json" "$wd" "$rc" "$lg"); r=$?
expect "resume: first run exit code" "$r" 4
expect "resume: first run verdict" "$(verdict "$out")" provider_error
expect "resume: first run unit lines" "$(units "$out")" "a:building a:verified b:building b:verified c:building c:unavailable"
expect "resume: the state kept a and b" "$(order "$wd/state.txt")" "verified a verified b"
mv "$rc/c.sh.later" "$rc/c.sh"
out=$(run "$T/plan.json" "$wd" "$rc" "$lg"); r=$?
expect "resume: second run exit code" "$r" 0
expect "resume: second run kept a and b" "$(units "$out")" "a:kept b:kept c:building c:verified"
expect "resume: only c was asked again" "$(order "$lg")" "a b c c"
rm -rf "$wd" "$rc"

# stuck: a is always wrong, b is independent, c depends on a
set -- $(mk); wd=$1; rc=$2; lg=$3
printf 'sed -i.bak "/fn double/d" "$1"; printf "\\nfn double(x: int) -> [] int { return x + 3; }\\n" >> "$1"\n' > "$rc/a.sh"
out=$(run "$T/plan-failing.json" "$wd" "$rc" "$lg"); r=$?
expect "stuck: exit code" "$r" 1
expect "stuck: verdict" "$(verdict "$out")" stuck
expect "stuck: unit lines" "$(units "$out")" "a:building a:failed b:building b:verified c:skipped"
expect "stuck: agent order (b was still built)" "$(order "$lg")" "a a b"
expect "stuck: the state has b only" "$(order "$wd/state.txt")" "verified b"
expect "stuck: the failed unit's trail was kept (two records)" "$(wc -l < "$wd/trail-a.jsonl" 2>/dev/null | tr -d ' ')" 2
rm -rf "$wd" "$rc"

# agent log: the agent's standard error is kept, per unit, per attempt, whatever the outcome (a provider error had no recorded cause)
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$(run "$T/plan.json" "$wd" "$rc" "$lg"); r=$?
expect "agent log: happy exit" "$r" 0
expect "agent log: a verified unit's log has its one attempt" "$(grep -c '^=== attempt' "$wd/agent-a.log")" 1
grep -q '^=== attempt 1: exit 0 after [0-9]* ms$' "$wd/agent-a.log" || { echo "FAIL: agent log: no 'attempt 1: exit 0' header in agent-a.log: $(cat "$wd/agent-a.log")" >&2; fail=1; }
grep -q '^stub-agent: unit a request 1$' "$wd/agent-a.log" || { echo "FAIL: agent log: the agent's stderr line is not in agent-a.log" >&2; fail=1; }
case "$out" in *'[AGENT_LOG]'*) echo "FAIL: agent log: an [AGENT_LOG] line for units that all verified" >&2; fail=1 ;; esac
rm -rf "$wd" "$rc"
# two attempts of a unit that never verifies: both are in the log, in order, and the run says where the log is
set -- $(mk); wd=$1; rc=$2; lg=$3
printf 'sed -i.bak "/fn double/d" "$1"; printf "\\nfn double(x: int) -> [] int { return x + 3; }\\n" >> "$1"\n' > "$rc/a.sh"
out=$(run "$T/plan-failing.json" "$wd" "$rc" "$lg"); r=$?
expect "agent log: stuck exit" "$r" 1
expect "agent log: the failed unit's two attempts" "$(grep '^=== attempt' "$wd/agent-a.log" | cut -d: -f1 | tr '\n' ' ')" "=== attempt 1 === attempt 2 "
printf '%s\n' "$out" | grep -q "^\[AGENT_LOG\]	a	agent-a.log$" || { echo "FAIL: agent log: no [AGENT_LOG] line for the failed unit a" >&2; fail=1; }
rm -rf "$wd" "$rc"
# an agent that fails (exit 3, no recipe): the unit is unavailable, and its log says exit 3 and what the agent said
set -- $(mk); wd=$1; rc=$2; lg=$3
mv "$rc/c.sh" "$rc/c.sh.later"
printf 'echo "provider said: overloaded" >&2; exit 7\n' > "$rc/c.sh"
out=$(run "$T/plan.json" "$wd" "$rc" "$lg"); r=$?
expect "agent log: provider error exit" "$r" 4
grep -q '^=== attempt 1: exit 7 after [0-9]* ms$' "$wd/agent-c.log" || { echo "FAIL: agent log: no 'exit 7' header in agent-c.log: $(cat "$wd/agent-c.log" 2>&1)" >&2; fail=1; }
grep -q '^provider said: overloaded$' "$wd/agent-c.log" || { echo "FAIL: agent log: the cause of the failure is not in agent-c.log" >&2; fail=1; }
printf '%s\n' "$out" | grep -q "^\[AGENT_LOG\]	c	agent-c.log$" || { echo "FAIL: agent log: no [AGENT_LOG] line for the unavailable unit c" >&2; fail=1; }
rm -rf "$wd" "$rc"
# bounded: a turn that says 20000 bytes keeps the last 4096 of them, and says it cut
set -- $(mk); wd=$1; rc=$2; lg=$3
printf 'i=0; while [ $i -lt 400 ]; do echo "line $i xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" >&2; i=$((i+1)); done; echo END-OF-STDERR >&2; printf "\\nfn double(x: int) -> [] int { return x * 2; }\\n" >> "$1"\n' > "$rc/a.sh"
out=$(run "$T/plan.json" "$wd" "$rc" "$lg"); r=$?
expect "agent log: bounded run exit" "$r" 0
grep -q 'earlier output cut' "$wd/agent-a.log" || { echo "FAIL: agent log: a long stderr is not marked cut" >&2; fail=1; }
grep -q '^END-OF-STDERR$' "$wd/agent-a.log" || { echo "FAIL: agent log: the end of a long stderr is not kept" >&2; fail=1; }
grep -q '^line 0 ' "$wd/agent-a.log" && { echo "FAIL: agent log: the start of a long stderr was kept (not bounded)" >&2; fail=1; }
[ "$(wc -c < "$wd/agent-a.log")" -le 4400 ] || { echo "FAIL: agent log: agent-a.log is $(wc -c < "$wd/agent-a.log") bytes (bound is the last 4096 of a turn plus its header)" >&2; fail=1; }
rm -rf "$wd" "$rc"

# option: an example whose result is an Option (`f(x) == option.Option::Some(y)` / `option.Option::None`) is run as a match, because the
# compiler has no `==` on enums; a unit with such a result verifies, and one that answers wrongly on the None example does not
set -- $(mk); wd=$1; rc=$2; lg=$3
good='edition 7;\nimport std.option;\n\nfn pick(x: int) -> [] option.Option[int] {\n    if x > 0 {\n        return option.Option::Some(x * 2);\n    }\n    return option.Option::None;\n}\n'
bad='edition 7;\nimport std.option;\n\nfn pick(x: int) -> [] option.Option[int] {\n    if x > 0 {\n        return option.Option::Some(x * 3);\n    }\n    return option.Option::None;\n}\n'
printf 'printf "%s" > "$1"\n' "$bad" > "$rc/p.1.sh"
printf 'printf "%s" > "$1"\n' "$good" > "$rc/p.2.sh"
out=$(run "$T/plan-option.json" "$wd" "$rc" "$lg"); r=$?
expect "option: exit code" "$r" 0
expect "option: verdict" "$(verdict "$out")" done
expect "option: the wrong answer was refused, then the right one accepted" "$(printf '%s\n' "$out" | grep ACCEPTANCE | cut -f2 | tr '\n' ' ')" "fail pass "
expect "option: agent order" "$(order "$lg")" "p p"
rm -rf "$wd" "$rc"

# described: a unit's `description` reaches the agent in the task, decoded (the quote and the newline), and the task tells it not to write
# tests (the first real run of the tokenbucket plan showed a model pasting `fn test_refill_1` from the feedback into its program)
set -- $(mk); wd=$1; rc=$2; lg=$3
printf 'grep -q "SENTINEL-DESC \\"quoted\\" word." "$1.task" || exit 3\ngrep -q "^second line of the description" "$1.task" || exit 3\ngrep -q "Do not write tests" "$1.task" || exit 3\nprintf "\\nfn double(x: int) -> [] int { return x * 2; }\\n" >> "$1"\n' > "$rc/a.sh"
out=$(run "$T/plan-described.json" "$wd" "$rc" "$lg"); r=$?
expect "described: exit code" "$r" 0
expect "described: verdict" "$(verdict "$out")" done
grep -q '^DESCRIPTION:' "$wd/project.cho.task" || { echo "FAIL: described: no DESCRIPTION line in the task" >&2; fail=1; }
rm -rf "$wd" "$rc"

# effort: a unit's `effort` (low|medium|high|xhigh|max) reaches the agent as an `EFFORT:` line of the task; a unit without one has none
set -- $(mk); wd=$1; rc=$2; lg=$3
printf 'case "$(sed -n 1p "$1.task")" in "UNIT: a") grep -q "^EFFORT: low$" "$1.task" || exit 3; printf "\nfn double(x: int) -> [] int { return x * 2; }\n" >> "$1" ;; *) if grep -q "^EFFORT:" "$1.task"; then exit 4; fi; printf "\nfn triple(x: int) -> [] int { return x * 3; }\n" >> "$1" ;; esac\n' > "$rc/a.sh"
cp "$rc/a.sh" "$rc/b.sh"
out=$(run "$T/plan-effort.json" "$wd" "$rc" "$lg"); r=$?
expect "effort: exit code (3 = a unit with effort had no EFFORT line, 4 = a unit without one had it)" "$r" 0
expect "effort: verdict" "$(verdict "$out")" done
rm -rf "$wd" "$rc"

# rawtests: a unit's own `tests` (cancho source) are appended verbatim to its tests file and used in place of the example-derived ones; a
# signature with region parameters is accepted. The stand-in's first answer is wrong for the empty string, which only the raw test 2 knows
set -- $(mk); wd=$1; rc=$2; lg=$3
printf 'printf "\\nfn first[&r](s: &r [byte]) -> [] int { return int_of(s[0]); }\\n" >> "$1"\n' > "$rc/a.1.sh"
printf 'sed -i.bak "/fn first/d" "$1"; printf "\\nfn first[&r](s: &r [byte]) -> [] int {\\n    if len(s) == 0 {\\n        return -1;\\n    }\\n    return int_of(s[0]);\\n}\\n" >> "$1"\n' > "$rc/a.2.sh"
out=$(run "$T/plan-rawtests.json" "$wd" "$rc" "$lg"); r=$?
expect "rawtests: exit code" "$r" 0
expect "rawtests: verdict" "$(verdict "$out")" done
expect "rawtests: the empty-string test refused the first answer" "$(order "$lg")" "a a"
grep -q 'test_a_raw_2' "$wd/tests-a.cho" || { echo "FAIL: rawtests: the unit's own test is not in its tests file" >&2; fail=1; }
rm -rf "$wd" "$rc"

# service: the integration unit. The acceptance command and the lib files are the driver's 7th and 8th arguments (as `fix` takes them)
SV="$T/service"
runs() { # plan wd recipes log
    "$exe" "$CANCHO" "$1" "$2" "sh $T/agent.sh $3 $4" 4 60 "sh $SV/accept.sh $CANCHO $SV/svc-main.cho $SV/lib.cho" "$SV/lib.cho" 2>&1
}
set -- $(mk); wd=$1; rc=$2; lg=$3
cp "$SV"/recipes/*.sh "$rc"/
out=$(runs "$SV/plan.json" "$wd" "$rc" "$lg"); r=$?
expect "service: exit code" "$r" 0
expect "service: verdict" "$(verdict "$out")" done
expect "service: unit lines" "$(units "$out")" "a:building a:verified app:building app:verified"
expect "service: agent order" "$(order "$lg")" "a app"
[ -f "$wd/tests-app.cho" ] && { echo "FAIL: service: the integration unit got a tests file" >&2; fail=1; }
expect "service: the state" "$(order "$wd/state.txt")" "verified a verified app"
# a second run keeps both: the integration unit is re-verified by the acceptance command
out=$(runs "$SV/plan.json" "$wd" "$rc" "$lg"); r=$?
expect "service: rerun exit code" "$r" 0
expect "service: rerun keeps both" "$(units "$out")" "a:kept app:kept"
rm -rf "$wd" "$rc"

# service, scenario feedback: the application's first answer fails the scenario; the scenario's own output is in the feedback the agent reads
# on the next attempt, and the second answer verifies
set -- $(mk); wd=$1; rc=$2; lg=$3
cp "$SV"/recipes/*.sh "$rc"/
printf 'printf "\nfn app_run(x: int) -> [] int { return double(x); }\n" >> "$1"\n' > "$rc/app.1.sh"
printf 'grep -q "SCENARIO app_run(20): expected 41 got 40" "$1.feedback" || exit 3\nsed -i.bak "s/double(x);/double(x) + 1;/" "$1"\n' > "$rc/app.2.sh"
out=$(runs "$SV/plan.json" "$wd" "$rc" "$lg"); r=$?
expect "service feedback: exit code" "$r" 0
expect "service feedback: agent order" "$(order "$lg")" "a app app"
expect "service feedback: the integration unit took two attempts" "$(printf '%s\n' "$out" | grep 'ISSUE_VERDICT.*verified' | tail -1 | cut -f3)" "attempts 2"
rm -rf "$wd" "$rc"

# service, never satisfied: the pure unit stays verified, the integration unit fails, stuck
set -- $(mk); wd=$1; rc=$2; lg=$3
cp "$SV"/recipes/*.sh "$rc"/
printf 'sed -i.bak "/fn app_run/d" "$1"; printf "\nfn app_run(x: int) -> [] int { return double(x) + 2; }\n" >> "$1"\n' > "$rc/app.sh"
out=$(runs "$SV/plan.json" "$wd" "$rc" "$lg"); r=$?
expect "service stuck: exit code" "$r" 1
expect "service stuck: verdict" "$(verdict "$out")" stuck
expect "service stuck: unit lines" "$(units "$out")" "a:building a:verified app:building app:failed"
expect "service stuck: the state has a only" "$(order "$wd/state.txt")" "verified a"
rm -rf "$wd" "$rc"

# an integration unit and no acceptance command: a usage error, the agent is never asked
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$(run "$SV/plan.json" "$wd" "$rc" "$lg"); r=$?
expect "service no command: exit code" "$r" 2
case "$out" in *"no acceptance command"*) ;; *) echo "FAIL: service no command: no message ('$out')" >&2; fail=1 ;; esac
expect "service no command: the agent was never asked" "$(wc -c < "$lg" | tr -d ' ')" 0
rm -rf "$wd" "$rc"


# ---- re-opening a unit: --retry, --hint, --patch ------------------------------------------------------------------------------------------
runx() { # plan wd recipes log attempts [extra args...]
    p=$1; w=$2; r=$3; l=$4; n=$5; shift 5
    "$exe" "$CANCHO" "$p" "$w" "sh $T/agent.sh $r $l" "$n" 60 "$@" 2>&1
}
# the events of the journal as "kind unit n outcome hint?" lines, for a unit
jevents() { python3 - "$1" "$2" <<'PY'
import json, sys
for line in open(sys.argv[1] + "/journal/events.jsonl"):
    e = json.loads(line)
    if e.get("unit") != sys.argv[2]:
        continue
    print(e["kind"], e.get("n", "-"), e.get("outcome", "-"), e.get("decision", "-"), "hint=" + e["hint"] if "hint" in e else "nohint",
          "retry" if e.get("retry") else "", "patch" if e.get("patch") else "", "prompt" if "prompt" in e else "noprompt", "code" if "code" in e else "nocode")
PY
}
WRONG='sed -i.bak "/fn double/d" "$1"; printf "\nfn double(x: int) -> [] int { return x + 3; }\n" >> "$1"'

# retry: a is stuck (always wrong without the hint); the hint makes it right. Only a and its dependent c are worked on again; b is kept as it is.
set -- $(mk); wd=$1; rc=$2; lg=$3
printf '%s\n' "$WRONG" > "$rc/a.sh"
out=$(runx "$T/plan.json" "$wd" "$rc" "$lg" 4)
expect "retry: the first run is stuck" "$(verdict "$out")" stuck
expect "retry: the first run's agent order" "$(order "$lg")" "a a b"
expect "retry: the state of the stuck run" "$(order "$wd/state.txt")" "verified b"
printf 'if grep -q "^HINT: multiply, do not add$" "$1.task"; then printf "\nfn double(x: int) -> [] int { return x * 2; }\n" >> "$1"; else %s; fi\n' "$WRONG" > "$rc/a.sh"
printf 'if grep -q "^HINT" "$1.task"; then exit 4; fi\nprintf "\nfn big_double(x: int) -> [] bool { return is_big(double(x)); }\n" >> "$1"\n' > "$rc/c.sh"
out=$(runx "$T/plan.json" "$wd" "$rc" "$lg" 4 --retry a --hint "multiply, do not add"); r=$?
expect "retry: exit code" "$r" 0
expect "retry: verdict" "$(verdict "$out")" done
expect "retry: only a and c were asked again (b is kept)" "$(order "$lg")" "a a b a c"
expect "retry: unit lines" "$(units "$out")" "b:kept a:building a:verified c:building c:verified"
printf '%s\n' "$out" | grep -q "^\[RETRY\]	a	hint$" || { echo "FAIL: retry: no '[RETRY] a hint' line" >&2; fail=1; }
expect "retry: the state" "$(order "$wd/state.txt")" "verified a verified b verified c"
expect "retry: the unit's trail kept the earlier attempts and went on (0 1 2)" "$(python3 -c 'import json,sys; print(" ".join(str(json.loads(l)["attempt"]) for l in open(sys.argv[1])))' "$wd/trail-a.jsonl")" "0 1 2"
expect "retry: the journal's story of a" "$(jevents "$wd" a | tr '\n' ';')" "unit_start - - - nohint   noprompt nocode;attempt 0 acceptance_failed retry nohint   noprompt code;attempt 1 acceptance_failed signature nohint   noprompt code;unit_end - - - nohint   noprompt nocode;unit_start - - - nohint retry  noprompt nocode;attempt 2 verified verified hint=multiply, do not add   noprompt code;unit_end - - - nohint   noprompt nocode;"
expect "retry: c's attempt has no hint" "$(jevents "$wd" c | grep -c 'hint=')" 0
[ -f "$wd/journal/blobs/a-a0-code.cho" ] && [ -f "$wd/journal/blobs/a-a2-code.cho" ] || { echo "FAIL: retry: the blobs of the earlier attempts and the new one are not both there" >&2; fail=1; }
rm -rf "$wd" "$rc"

# retry: the budget starts fresh. Two attempts are allowed; the unit ended on them; the retry gets two more (the first wrong, the second right)
set -- $(mk); wd=$1; rc=$2; lg=$3
printf '%s\n' "$WRONG" > "$rc/a.sh"
out=$(runx "$T/plan.json" "$wd" "$rc" "$lg" 2)
expect "retry fresh: the first run is stuck on the ceiling" "$(verdict "$out")" stuck
printf '%s\n' "$WRONG" > "$rc/a.3.sh"
printf 'sed -i.bak "/fn double/d" "$1"; printf "\nfn double(x: int) -> [] int { return x * 2; }\n" >> "$1"\n' > "$rc/a.4.sh"
out=$(runx "$T/plan.json" "$wd" "$rc" "$lg" 2 --retry a)
expect "retry fresh: verdict" "$(verdict "$out")" done
expect "retry fresh: it took its own two attempts" "$(printf '%s\n' "$out" | grep 'ISSUE_VERDICT.*verified' | head -1 | cut -f3)" "attempts 2"
printf '%s\n' "$out" | grep -q "^\[RETRY\]	a$" || { echo "FAIL: retry fresh: no '[RETRY] a' line (no hint given)" >&2; fail=1; }
expect "retry fresh: no hint, no HINT line, no hint field" "$(grep -c '^HINT' "$wd/project.cho.task"; jevents "$wd" a | grep -c 'hint=')" "0
0"
rm -rf "$wd" "$rc"

# retry: the hint is data. Quotes, a $( ), backticks and a second line reach the task byte for byte, one HINT line per line, and nothing is run
set -- $(mk); wd=$1; rc=$2; lg=$3
printf '%s\n' "$WRONG" > "$rc/a.sh"
out=$(runx "$T/plan.json" "$wd" "$rc" "$lg" 4)
printf 'grep -qF "HINT: use \\"x\\" \\$(touch %s/pwned) and \\`id\\`" "$1.task" || exit 4\ngrep -qF "HINT: second line" "$1.task" || exit 5\nprintf "\\nfn double(x: int) -> [] int { return x * 2; }\\n" >> "$1"\n' "$wd" > "$rc/a.sh"
out=$(runx "$T/plan.json" "$wd" "$rc" "$lg" 4 --retry a --hint 'use "x" $(touch '"$wd"'/pwned) and `id`
second line'); r=$?
expect "retry hint as data: exit code (4/5: a line of the hint did not reach the task)" "$r" 0
[ -e "$wd/pwned" ] && { echo "FAIL: retry hint as data: the hint was run by a shell" >&2; fail=1; }
rm -rf "$wd" "$rc"

# retry of a VERIFIED unit: its state is reset, it is rebuilt with the hint, and the units that need it are checked again after it: here b's
# new answer breaks c's second example, the sweep finds it, c is rebuilt
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$(run "$T/plan.json" "$wd" "$rc" "$lg")
expect "retry verified: the first run is done" "$(verdict "$out")" done
printf 'grep -q "^HINT: strictly more than nine$" "$1.task" || exit 4\nsed -i.bak "s/x > 10/x > 9/" "$1"\n' > "$rc/b.2.sh"
printf 'sed -i.bak "s/is_big(double(x))/(double(x) > 10)/" "$1"\n' > "$rc/c.2.sh"
out=$(runx "$T/plan.json" "$wd" "$rc" "$lg" 4 --retry b --hint "strictly more than nine"); r=$?
expect "retry verified: exit code" "$r" 0
expect "retry verified: verdict" "$(verdict "$out")" done
expect "retry verified: unit lines (a, c kept at the start; b rebuilt; c found broken by the sweep and rebuilt)" "$(units "$out")" "a:kept c:kept b:building b:verified c:regressed c:building c:verified"
expect "retry verified: only b and c were asked again" "$(order "$lg")" "a b c b c"
expect "retry verified: the state" "$(order "$wd/state.txt")" "verified a verified b verified c"
case "$(jevents "$wd" b | tr '\n' ';')" in *"attempt 1 verified verified hint=strictly more than nine"*) ;; *) echo "FAIL: retry verified: b's attempt 1 does not carry the hint: $(jevents "$wd" b | tr '\n' ';')" >&2; fail=1 ;; esac
python3 - "$wd" <<'PY' || { echo "FAIL: retry verified: the sweep after b did not name c as regressed" >&2; fail=1; }
import json, sys
sw = [json.loads(l) for l in open(sys.argv[1] + "/journal/events.jsonl") if '"sweep"' in l]
assert any(e["after_unit"] == "b" and e["regressed"] == ["c"] and e["held"] == ["a"] for e in sw), sw
PY
rm -rf "$wd" "$rc"

# patch: the person's code, in the shape of a model's reply (fences and talk around it), is verified with no agent call
set -- $(mk); wd=$1; rc=$2; lg=$3
printf '%s\n' "$WRONG" > "$rc/a.sh"
out=$(runx "$T/plan.json" "$wd" "$rc" "$lg" 4)
before=$(cat "$wd/project.cho")
printf 'Here is the function:\n```cancho\nfn double(x: int) -> [] int {\n    return x * 2;\n}\n```\nthat is all.\n' > "$wd.patch-good.txt"
out=$(runx "$T/plan.json" "$wd" "$rc" "$lg" 4 --patch a "$wd.patch-good.txt"); r=$?
expect "patch: exit code" "$r" 0
expect "patch: verdict" "$(verdict "$out")" done
expect "patch: the agent was asked for c only (a patch is not a model call)" "$(order "$lg")" "a a b c"
expect "patch: unit lines" "$(units "$out")" "b:kept a:verified c:building c:verified"
printf '%s\n' "$out" | grep -q "^\[PATCH\]	a	applying$" && printf '%s\n' "$out" | grep -q "^\[PATCH\]	a	verified$" || { echo "FAIL: patch: no [PATCH] applying / verified lines: $out" >&2; fail=1; }
grep -q 'return x \* 2' "$wd/project.cho" || { echo "FAIL: patch: the person's code is not in project.cho" >&2; fail=1; }
expect "patch: the state" "$(order "$wd/state.txt")" "verified a verified b verified c"
expect "patch: the trail went on (0 1 2)" "$(python3 -c 'import json,sys; print(" ".join(str(json.loads(l)["attempt"]) for l in open(sys.argv[1])))' "$wd/trail-a.jsonl")" "0 1 2"
expect "patch: the journal records a human_patch attempt: no prompt, no reply, the code" "$(jevents "$wd" a | grep -E 'attempt 2|patch' | tr '\n' ';')" "unit_start - - - nohint  patch noprompt nocode;attempt 2 human_patch verified nohint   noprompt code;"
python3 - "$wd" <<'PY' || { echo "FAIL: patch: the human_patch attempt has a prompt or reply blob, or tokens" >&2; fail=1; }
import json, sys
e = [json.loads(l) for l in open(sys.argv[1] + "/journal/events.jsonl")]
a = [x for x in e if x.get("outcome") == "human_patch"]
assert len(a) == 1 and not ({"prompt", "reply", "tokens"} & set(a[0])), a
PY
[ -s "$wd/usage.jsonl" ] && { echo "FAIL: patch: a model-call log was written" >&2; fail=1; }
rm -rf "$wd" "$rc" "$wd.patch-good.txt"

# patch refused: by the examples, by the compiler, by the splice. project.cho, the state and the agent log are as they were; the refusal is shown
set -- $(mk); wd=$1; rc=$2; lg=$3
printf '%s\n' "$WRONG" > "$rc/a.sh"
out=$(runx "$T/plan.json" "$wd" "$rc" "$lg" 4)
cp "$wd/project.cho" "$wd.before"; cp "$wd/state.txt" "$wd.state"
printf 'fn double(x: int) -> [] int { return x + 7; }\n' > "$wd.p1.txt"
printf 'fn double(x: int) -> [] int { return true; }\n' > "$wd.p2.txt"
printf 'this is talk, not code\n' > "$wd.p3.txt"
printf 'fn double(x: int) -> [] int { return x * 2; }\nfn double(x: int) -> [] int { return x * 3; }\n' > "$wd.p4.txt"
for k in 1 2 3 4; do
    out=$(runx "$T/plan.json" "$wd" "$rc" "$lg" 4 --patch a "$wd.p$k.txt"); r=$?
    expect "patch refused $k: exit code (stuck)" "$r" 1
    expect "patch refused $k: verdict" "$(verdict "$out")" stuck
    printf '%s\n' "$out" | grep -q "^\[PATCH\]	a	refused$" || { echo "FAIL: patch refused $k: no '[PATCH] a refused': $out" >&2; fail=1; }
    cmp -s "$wd/project.cho" "$wd.before" || { echo "FAIL: patch refused $k: project.cho was not restored" >&2; fail=1; }
    cmp -s "$wd/state.txt" "$wd.state" || { echo "FAIL: patch refused $k: the state changed" >&2; fail=1; }
    expect "patch refused $k: the agent was never asked" "$(order "$lg")" "a a b"
    case "$k" in
        1) case "$out" in *"double(2) == 4"*) ;; *) echo "FAIL: patch refused 1: the examples' refusal is not shown: $out" >&2; fail=1 ;; esac ;;
        2) case "$out" in *'"refused"'*) ;; *) echo "FAIL: patch refused 2: the compiler's refusal is not shown: $out" >&2; fail=1 ;; esac ;;
        3|4) case "$out" in *SPLICE_ERROR*) ;; *) echo "FAIL: patch refused $k: the splice's refusal is not shown: $out" >&2; fail=1 ;; esac ;;
    esac
done
expect "patch refused: each try is an attempt in the journal (outcome human_patch, none verified)" "$(jevents "$wd" a | grep -c 'attempt [0-9]* human_patch')" 4
expect "patch refused: none of them verified" "$(jevents "$wd" a | grep 'human_patch' | grep -c ' verified ')" 0
expect "patch refused: the trail numbers go on" "$(python3 -c 'import json,sys; print(" ".join(str(json.loads(l)["attempt"]) for l in open(sys.argv[1])))' "$wd/trail-a.jsonl")" "0 1 2 3 4 5"
rm -rf "$wd" "$rc" "$wd".before "$wd".state "$wd".p?.txt
# a refused patch of a VERIFIED unit leaves it verified (and the run is stuck: what was asked did not happen)
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$(run "$T/plan.json" "$wd" "$rc" "$lg")
cp "$wd/project.cho" "$wd.before"
printf 'fn is_big(x: int) -> [] bool { return x > 100; }\n' > "$wd.p.txt"
out=$(runx "$T/plan.json" "$wd" "$rc" "$lg" 4 --patch b "$wd.p.txt"); r=$?
expect "patch refused (verified unit): exit code" "$r" 1
cmp -s "$wd/project.cho" "$wd.before" || { echo "FAIL: patch refused (verified unit): project.cho was not restored" >&2; fail=1; }
expect "patch refused (verified unit): b stays verified" "$(order "$wd/state.txt")" "verified a verified b verified c"
expect "patch refused (verified unit): the agent was not asked" "$(order "$lg")" "a b c"
rm -rf "$wd" "$rc" "$wd.before" "$wd.p.txt"

# redo usage: nothing is changed, nothing is asked of the agent
usage_case() { # name expected-message-part args...
    name=$1; part=$2; shift 2
    set -- "$@"
    w=$(mktemp -d -t cc-project-wd-XXXXXX); r=$(mktemp -d -t cc-project-rc-XXXXXX); l="$r/agent.log"; : > "$l"; cp "$T"/recipes-good/*.sh "$r"/
    before=$(cd "$w" && find . -type f | sort | xargs cksum 2>/dev/null)
    o=$(runx "$T/plan.json" "$w" "$r" "$l" 4 "$@"); rr=$?
    expect "redo usage ($name): exit code" "$rr" 2
    case "$o" in *"$part"*) ;; *) echo "FAIL: redo usage ($name): no message with '$part': $o" >&2; fail=1 ;; esac
    expect "redo usage ($name): the work directory is untouched" "$(cd "$w" && find . -type f | sort | xargs cksum 2>/dev/null)" "$before"
    expect "redo usage ($name): the agent was never asked" "$(wc -c < "$l" | tr -d ' ')" 0
    rm -rf "$w" "$r"
}
PATCHOK=$(mktemp -t cc-project-patch-XXXXXX); printf 'fn double(x: int) -> [] int { return x * 2; }\n' > "$PATCHOK"
usage_case "unit not in the plan" "does not have" --retry nosuch --hint x
usage_case "patch unit not in the plan" "does not have" --patch nosuch "$PATCHOK"
usage_case "empty hint" "empty" --retry a --hint ""
usage_case "retry and patch" "together" --retry a --patch b "$PATCHOK"
usage_case "retry and patch for the same unit" "together" --retry a --patch a "$PATCHOK"
usage_case "hint without retry" "goes with --retry" --hint x
usage_case "patch file missing" "cannot be read" --patch a /no/such/patch.txt
usage_case "patch file empty" "cannot be read" --patch a /dev/null
usage_case "retry without a unit" "needs a unit" --retry ""
usage_case "unknown option" "does not know" --frobnicate
rm -f "$PATCHOK"

# no plan
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$(run "$T/plan-invalid.json" "$wd" "$rc" "$lg"); r=$?
expect "no plan: exit code" "$r" 3
expect "no plan: verdict" "$(verdict "$out")" no_plan
printf '%s\n' "$out" | grep -q '^\[PLAN_ERROR\]' || { echo "FAIL: no plan: no [PLAN_ERROR] line" >&2; fail=1; }
expect "no plan: the agent was never asked" "$(wc -c < "$lg" | tr -d ' ')" 0
rm -rf "$wd" "$rc"

# usage
"$exe" >/dev/null 2>&1; expect "usage: no arguments" "$?" 2
# a checker path that is not absolute: the driver spawns it from another directory, so it is a usage error, not a crash
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$("$exe" "cancho" "$T/plan.json" "$wd" "true" 2>&1); r=$?
expect "usage: a relative checker path" "$r" 2
case "$out" in *absolute*) ;; *) echo "FAIL: usage: a relative checker path: no message that says 'absolute' ('$out')" >&2; fail=1 ;; esac
rm -rf "$wd" "$rc"
set -- $(mk); wd=$1; rc=$2; lg=$3
"$exe" "$CANCHO" "$T/does-not-exist.json" "$wd" "true" >/dev/null 2>&1; expect "usage: a plan that is not there" "$?" 2
rm -rf "$wd" "$rc"

# a path with `..` in it: the file capability refuses traversal by trapping (exit 132), so the driver says so and exits 2 instead
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$("$exe" "$CANCHO" "$T/plan.json" "$wd/../$(basename "$wd")" "true" 2>&1); r=$?
expect "usage: a work directory with .. in it" "$r" 2
case "$out" in *".."*) ;; *) echo "FAIL: usage: a work directory with .. : no message that names '..' ('$out')" >&2; fail=1 ;; esac
out=$("$exe" "$CANCHO" "$T/../project/plan.json" "$wd" "true" 2>&1); r=$?
expect "usage: a plan path with .. in it" "$r" 2
rm -rf "$wd" "$rc"

rm -f "$exe"
[ "$fail" = 0 ] && echo "project gate: ok" || { echo "project gate: FAILED" >&2; exit 1; }
