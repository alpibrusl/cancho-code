#!/bin/sh
# The build gate (docs/build.md): one command from a brief to a verified build, against a stand-in agent (tests/buildcmd/agent.sh) that plays
# both the plan agent and the unit agent from recipes. No model, no network, no key. The checker is the real compiler.
#
#   happy       the agent writes the plan, the units are built in order: done, exit 0, verdict in stdout AND run.log, build.json complete
#   args        the plan call gets --mode plan, the guide, the brief, the rounds, the usage log, the review flags; both calls get provider and model
#   reuse       a valid plan.json already in the work directory is not asked for again; an invalid one is replaced
#   replan      a valid plan.json whose own test was the dead end of the run before (failed twice on code that compiled, the run stuck) is asked
#               for again, once per work directory, and the right code then verifies; not when the run before ended provider_error, stopped
#               on a refusal or at the ceiling, failed on its test file not compiling, when the person edited the plan, with --retry, --patch
#               or no --guide; units that verified are kept
#   invalid     the agent "succeeds" with a plan the check refuses: its errors, plan_failed, exit 3, the project step never runs
#   rejected    the agent gives up after its rounds (exit 1, the plan was rejected): plan_failed, exit 3, its stderr kept in plan.log
#   questions   the model needs a decision (agent exit 3): plan_failed
#   unreachable the agent cannot reach the API: provider_error, exit 4, the project step never runs
#   resume      a run killed (SIGKILL) while building the third unit: build.json says stage build; the next run asks for no plan, keeps a and b
#   review      a plan the agent's review could not confirm ("the plan stands unreviewed" in plan.log) is built, and run.log (`[PLAN_REVIEW]`) and build.json (`review`) say unreviewed; a reviewed one says reviewed; with no review, none
#   provider    the unit agent fails: provider_error, exit 4, the state keeps what verified, build.json agrees; run.log names the unit's agent log (`[AGENT_LOG]`), which holds the turn's header and the agent's standard error
#   gave up     the unit agent exits with a documented gave-up code (10): stuck, exit 1, not provider_error; run.log has `[UNIT_WHY]` and `[AGENT_LOG]`
#   stuck       a unit never verifies: stuck, exit 1, build.json counts the verified ones
#   names       the brief names its public functions (`- name(...) : ...`): a plan that does not declare one is refused (`brief-name`), plan_failed, exit 3; a plan that does is built; a valid plan.json that lacks one is not reused;
#               a plan that gives one of them a heap while its result owns nothing is refused (`brief-heap`), plan_failed, exit 3
#   retry       `--retry <unit> --hint "..."` on a stuck run: the plan is not asked for again, only that unit and the ones that need it are worked
#               on, the hint is in the unit agent's task, run.log has `[RETRY]`, build.json names the unit (`retry`) and ends `done`
#   patch       `--patch <unit> <file>`: no agent call for the unit, run.log has `[PATCH]`, build.json names it (`patch`)
#   redo usage  a unit that is not in the plan, no valid plan.json, an empty hint, --retry with --patch, a patch file that is not there, --hint with no
#               --retry, `--patch` with a missing file name: exit 2, nothing written in the work directory
#   memory      `--memory <dir>` reaches the unit agent's command line (docs/memory.md) and nothing else changes; `--remember "<text>"` appends one line to
#               <dir>/facts.txt before the run and the run goes on; an empty, blank, multi-line or over-long text, a relative or `..` directory, no
#               `--memory`, an eleventh fact: exit 2, nothing written, nothing run; without `--memory` the agent command has none
#   usage       missing arguments, provider, model or guide, a relative checker, `..`, an unknown option, a brief that is not there: exit 2, nothing run
#
# Needs the real cancho as CANCHO. BUILD_SRC names a directory to take src/ from (the mutation runs of the gate's own review). Exit 0: every case held.
set -u

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
SRC="${BUILD_SRC:-$root/src}"
exe=$(mktemp -t cc-build-XXXXXX)
"$CANCHO" build "$root/tests/programs/build.cho" "$SRC/build.cho" "$SRC/project.cho" "$SRC/plan.cho" "$SRC/driver.cho" \
    "$SRC/checker.cho" "$SRC/signature.cho" "$SRC/loop_check.cho" "$SRC/snapshot.cho" "$SRC/trail.cho" \
    "$SRC/acceptance.cho" "$SRC/splice.cho" "$SRC/pool.cho" "$SRC/parallel.cho" --std -o "$exe" || { echo "gate did not build" >&2; exit 2; }

fail=0
expect() { [ "$2" = "$3" ] || { echo "FAIL: $1: wanted '$3', got '$2'" >&2; fail=1; }; }
B="$root/tests/buildcmd"
P="$root/tests/project"
verdict() { printf '%s\n' "$1" | grep '^\[BUILD_VERDICT\]' | cut -f2; }
units() { printf '%s\n' "$1" | grep '^\[UNIT\]' | cut -f2,3 | tr '\t' ':' | tr '\n' ' ' | sed 's/ $//'; }
order() { tr '\n' ' ' < "$1" | sed 's/ $//'; }
# a field of build.json (the file is one line of flat JSON)
jf() { sed -nE "s/.*\"$2\":(\"[^\"]*\"|[^,}]*).*/\1/p" "$1/build.json" | tr -d '"'; }

# a fresh work directory with the good recipes and a plan.sh that writes the plan given; echoes "<workdir> <recipes> <log>"
mk() {
    wd=$(mktemp -d -t cc-build-wd-XXXXXX); rc=$(mktemp -d -t cc-build-rc-XXXXXX); lg="$rc/agent.log"
    cp "$P"/recipes-good/*.sh "$rc"/; : > "$lg"
    printf 'cp "%s" "$1"\n' "${1:-$P/plan.json}" > "$rc/plan.sh"
    echo "$wd $rc $lg"
}
# run <workdir> <recipes> <log> [more options]
run() {
    w=$1; r=$2; l=$3; shift 3
    "$exe" "$CANCHO" "$B/brief.txt" "$w" "sh $B/agent.sh $r $l" --provider stand --model m1 --guide "$B/guide.txt" --attempts 4 --agent-seconds 60 --jobs 1 "$@" 2>&1
}

# happy
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$(run "$wd" "$rc" "$lg"); r=$?
expect "happy: exit code" "$r" 0
expect "happy: verdict on stdout" "$(verdict "$out")" done
expect "happy: agent order (the plan first)" "$(order "$lg")" "PLAN a b c"
expect "happy: unit lines" "$(units "$out")" "a:building a:verified b:building b:verified c:building c:verified"
expect "happy: run.log has the verdict" "$(grep '^\[BUILD_VERDICT\]' "$wd/run.log" | cut -f2)" done
expect "happy: run.log has the project verdict" "$(grep '^\[PROJECT_VERDICT\]' "$wd/run.log" | cut -f2)" done
expect "happy: run.log has the units" "$(units "$(cat "$wd/run.log")")" "a:building a:verified b:building b:verified c:building c:verified"
expect "happy: run.log is what stdout said (but for the loop's own per-attempt lines)" "$(printf '%s\n' "$out" | grep '^\[' | grep -Ev '^\[(ACCEPTANCE|ISSUE_VERDICT)\]')" "$(grep '^\[' "$wd/run.log")"
[ -f "$wd/plan.json" ] || { echo "FAIL: happy: no plan.json" >&2; fail=1; }
expect "happy: the state" "$(order "$wd/state.txt")" "verified a verified b verified c"
[ -f "$wd/trail-a.jsonl" ] || { echo "FAIL: happy: no trail-a.jsonl" >&2; fail=1; }
for f in double is_big big_double; do grep -q "fn $f" "$wd/project.cho" || { echo "FAIL: happy: project.cho has no $f" >&2; fail=1; }; done
expect "happy: build.json brief" "$(jf "$wd" brief)" "$B/brief.txt"
expect "happy: build.json stage" "$(jf "$wd" stage)" done
expect "happy: build.json plan_valid" "$(jf "$wd" plan_valid)" true
expect "happy: build.json units_total" "$(jf "$wd" units_total)" 3
expect "happy: build.json units_verified" "$(jf "$wd" units_verified)" 3
expect "happy: build.json verdict" "$(jf "$wd" verdict)" done
expect "happy: build.json provider" "$(jf "$wd" provider)" stand
expect "happy: build.json model" "$(jf "$wd" model)" m1
now=$(date +%s)
st=$(jf "$wd" started_unix); sec=$(jf "$wd" seconds)
case "$st" in ''|*[!0-9]*) echo "FAIL: happy: started_unix '$st' is not a number" >&2; fail=1 ;; *) { [ "$st" -gt 1700000000 ] && [ "$st" -le "$now" ]; } || { echo "FAIL: happy: started_unix $st is not a time in the past" >&2; fail=1; } ;; esac
case "$sec" in ''|*[!0-9]*) echo "FAIL: happy: seconds '$sec' is not a number" >&2; fail=1 ;; *) [ "$sec" -lt 600 ] || { echo "FAIL: happy: seconds $sec" >&2; fail=1; } ;; esac
case "$(cat "$wd/build.json")" in "{"*"}") ;; *) echo "FAIL: happy: build.json is not an object" >&2; fail=1 ;; esac
rm -rf "$wd" "$rc"

# args
set -- $(mk); wd=$1; rc=$2; lg=$3
mkdir -p "$wd.keys"; : > "$wd.keys/contract.txt"
out=$(run "$wd" "$rc" "$lg" --rounds 5 --review on --review-guide "$B/review-guide.txt" --contract "$wd.keys/contract.txt"); r=$?
expect "args: exit code" "$r" 0
pa=$(cat "$rc/plan.args")
for want in "--provider stand" "--model m1" "--mode plan" "--guide $B/guide.txt" "--brief $B/brief.txt" "--rounds 5" "--review on" "--review-guide $B/review-guide.txt" "--contract $wd.keys/contract.txt" "--usage-log $wd/usage.jsonl"; do
    case "$pa" in *"$want"*) ;; *) echo "FAIL: args: the plan call lacks '$want': $pa" >&2; fail=1 ;; esac
done
case "$pa" in *"$wd/plan.json") ;; *) echo "FAIL: args: the plan call does not end with the plan path: $pa" >&2; fail=1 ;; esac
ua=$(cat "$rc/unit.args")
for want in "--provider stand" "--model m1" "--usage-log $wd/usage.jsonl"; do
    case "$ua" in *"$want"*) ;; *) echo "FAIL: args: the unit call lacks '$want': $ua" >&2; fail=1 ;; esac
done
case "$ua" in *"--mode plan"*) echo "FAIL: args: the unit call has --mode plan: $ua" >&2; fail=1 ;; esac
rm -rf "$wd" "$rc" "$wd.keys"
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$(run "$wd" "$rc" "$lg"); r=$?
case "$(cat "$rc/plan.args")" in *"--review"*|*"--contract"*) echo "FAIL: args: --review/--contract given without being asked: $(cat "$rc/plan.args")" >&2; fail=1 ;; esac
expect "args: defaults exit code" "$r" 0
rm -rf "$wd" "$rc"

# reuse: a valid plan in the work directory is kept; an invalid one is replaced
set -- $(mk); wd=$1; rc=$2; lg=$3
cp "$P/plan.json" "$wd/plan.json"
out=$(run "$wd" "$rc" "$lg"); r=$?
expect "reuse: exit code" "$r" 0
expect "reuse: the plan agent was not asked" "$(order "$lg")" "a b c"
expect "reuse: verdict" "$(verdict "$out")" done
expect "reuse: build.json plan_valid" "$(jf "$wd" plan_valid)" true
rm -rf "$wd" "$rc"
set -- $(mk); wd=$1; rc=$2; lg=$3
printf '{"name":"broken","units":[' > "$wd/plan.json"
out=$(run "$wd" "$rc" "$lg"); r=$?
expect "reuse: an invalid plan.json is replaced: exit code" "$r" 0
expect "reuse: an invalid plan.json is replaced: the agent was asked" "$(order "$lg")" "PLAN a b c"
rm -rf "$wd" "$rc"

# replan: a valid plan whose own test was the dead end of the run before (that test failed twice on code that compiled, the run ended stuck)
# is asked for again, once per work directory; every other ending, and a run the person steers, reuses it as before
GOODA='sed -i.bak "/fn double/d" "$1"; printf "\nfn double(x: int) -> [] int { return x * 2; }\n" >> "$1"'
BROKENA='sed -i.bak "/fn double/d" "$1"; printf "\nfn double(x: int) -> [] int { return x * ; }\n" >> "$1"'
# a work directory, its recipes and a plan.sh that writes <plan>, after <sed> made a test of it one the right code cannot pass; a's recipe is
# the right code, written over the one before. echoes "<workdir> <recipes> <log>"
mkdead() { # sed-expression [plan]
    set -- "$1" "${2:-$P/plan.json}" $(mk)
    sed "$1" "$2" > "$4/bad.json"
    printf 'cp "%s" "$1"\n' "$4/bad.json" > "$4/plan.sh"
    printf '%s\n' "$GOODA" > "$4/a.sh"
    echo "$3 $4 $5"
}
DEADA='s/"double(2) == 4"/"double(2) == 5"/'
plans() { grep -c '^PLAN$' "$1"; }
stage() { grep '^\[BUILD_STAGE\]	plan' "$1/run.log" | tail -1 | tr '\t' ':'; }
replaced() { grep -c '"kind":"plan_replaced"' "$1/journal/events.jsonl"; }
# dead plan replaced: the next plan is right, and the same right code verifies
set -- $(mkdead "$DEADA"); wd=$1; rc=$2; lg=$3
out=$(run "$wd" "$rc" "$lg"); r=$?
expect "replan: the first run is stuck" "$(verdict "$out")" stuck
expect "replan: the first run: a failed its test twice, c needs a" "$(order "$lg")" "PLAN a a b"
printf 'cp "%s" "$1"\n' "$P/plan.json" > "$rc/plan.sh"
out=$(run "$wd" "$rc" "$lg"); r=$?
expect "replan: exit code" "$r" 0
expect "replan: verdict" "$(verdict "$out")" done
expect "replan: run.log names the unit and the test" "$(grep '^\[BUILD_STAGE\]	plan	replaced' "$wd/run.log" | tr '\t' ':')" "[BUILD_STAGE]:plan:replaced:a:test_a_1"
expect "replan: the plan was asked for again, then a and c (b verified and is kept)" "$(order "$lg")" "PLAN a a b PLAN a c"
expect "replan: the units" "$(units "$out")" "b:kept a:building a:verified c:building c:verified"
expect "replan: one plan_replaced in the journal" "$(replaced "$wd")" 1
grep '"kind":"plan_replaced"' "$wd/journal/events.jsonl" | grep -q '"unit":"a","test":"test_a_1"' || { echo "FAIL: replan: the event lacks the unit and the test" >&2; fail=1; }
cmp -s "$wd/plan.json" "$P/plan.json" || { echo "FAIL: replan: plan.json is not the new plan" >&2; fail=1; }
rm -rf "$wd" "$rc"
# the dead end is one of the unit's own tests (`tests`, the B1 shape), not an example's
set -- $(mkdead 's/"examples":\["double(2) == 4"/"tests":["pub fn test_a_dead() -> [] int { test.assert(double(2) == 5); return 0; }"],"examples":["double(2) == 4"/'); wd=$1; rc=$2; lg=$3
out=$(run "$wd" "$rc" "$lg")
expect "replan own test: the first run is stuck" "$(verdict "$out")" stuck
printf 'cp "%s" "$1"\n' "$P/plan.json" > "$rc/plan.sh"
out=$(run "$wd" "$rc" "$lg"); r=$?
expect "replan own test: exit code" "$r" 0
expect "replan own test: run.log names the unit and the test" "$(grep '^\[BUILD_STAGE\]	plan	replaced' "$wd/run.log" | cut -f4,5 | tr '\t' ':')" "a:test_a_dead"
rm -rf "$wd" "$rc"
# once only: the planner writes the same wrong test again; the run after that reuses it
set -- $(mkdead "$DEADA"); wd=$1; rc=$2; lg=$3
run "$wd" "$rc" "$lg" > /dev/null
out=$(run "$wd" "$rc" "$lg"); r=$?
expect "replan once: the second run re-plans" "$(stage "$wd")" "[BUILD_STAGE]:plan"
expect "replan once: ... and is stuck again" "$(verdict "$out")" stuck
out=$(run "$wd" "$rc" "$lg"); r=$?
expect "replan once: the third run reuses the plan" "$(stage "$wd")" "[BUILD_STAGE]:plan:reused"
expect "replan once: two plan calls in three runs" "$(plans "$lg")" 2
expect "replan once: one plan_replaced in the journal" "$(replaced "$wd")" 1
rm -rf "$wd" "$rc"
# not replaced: the run before ended otherwise, the plan is the person's, or the person steers this run. Each second run reuses the plan.
reused() { # name workdir recipes log [run options...]: the second run, which must reuse the plan
    name=$1; w2=$2; r2=$3; l2=$4; shift 4
    o=$(run "$w2" "$r2" "$l2" "$@")
    expect "not replaced ($name): run.log says reused" "$(stage "$w2")" "[BUILD_STAGE]:plan:reused"
    expect "not replaced ($name): one plan call" "$(plans "$l2")" 1
    expect "not replaced ($name): no plan_replaced" "$(replaced "$w2")" 0
    rm -rf "$w2" "$r2"
}
# the run before ended provider_error (b's agent away after a's dead end)
set -- $(mkdead "$DEADA"); wd=$1; rc=$2; lg=$3
mv "$rc/b.sh" "$rc/b.sh.later"
out=$(run "$wd" "$rc" "$lg")
expect "not replaced (provider_error): the first run" "$(verdict "$out")" provider_error
mv "$rc/b.sh.later" "$rc/b.sh"
reused provider_error "$wd" "$rc" "$lg"
# the stop was `refused`: the same compile error twice
set -- $(mkdead "$DEADA"); wd=$1; rc=$2; lg=$3
printf '%s\n' "$BROKENA" > "$rc/a.sh"
out=$(run "$wd" "$rc" "$lg")
expect "not replaced (refused): the first run" "$(verdict "$out")" stuck
grep '"kind":"attempt"' "$wd/journal/events.jsonl" | grep '"unit":"a"' | tail -1 | grep -q '"outcome":"refused","decision":"signature"' || { echo "FAIL: not replaced (refused): a's last attempt is not a refusal stop" >&2; fail=1; }
reused refused "$wd" "$rc" "$lg"
# the stop was the ceiling, the plan's test and a compile error taking turns (the last attempt failed the test)
set -- $(mkdead "$DEADA"); wd=$1; rc=$2; lg=$3
rm -f "$rc/a.sh"; printf '%s\n' "$BROKENA" > "$rc/a.1.sh"; printf '%s\n' "$GOODA" > "$rc/a.2.sh"; printf '%s\n' "$BROKENA" > "$rc/a.3.sh"; printf '%s\n' "$GOODA" > "$rc/a.4.sh"
out=$(run "$wd" "$rc" "$lg")
expect "not replaced (ceiling): the first run" "$(verdict "$out")" stuck
grep '"kind":"attempt"' "$wd/journal/events.jsonl" | grep '"unit":"a"' | tail -1 | grep -q '"outcome":"acceptance_failed","decision":"ceiling","signature":"acceptance:test test_a_1' || { echo "FAIL: not replaced (ceiling): a's last attempt is not a test failure at the ceiling" >&2; fail=1; }
printf '%s\n' "$GOODA" > "$rc/a.sh"
reused ceiling "$wd" "$rc" "$lg"
# the failing signature is the unit's test file that did not compile, not a test of the plan
set -- $(mkdead 's/"double(2) == 4"/"double(2) == true"/'); wd=$1; rc=$2; lg=$3
out=$(run "$wd" "$rc" "$lg")
expect "not replaced (test file): the first run" "$(verdict "$out")" stuck
grep '"kind":"attempt"' "$wd/journal/events.jsonl" | grep '"unit":"a"' | tail -1 | grep -q '"outcome":"acceptance_failed","decision":"signature","signature":"acceptance:/' || { echo "FAIL: not replaced (test file): a's last attempt is not the test file's compile error" >&2; fail=1; }
reused "test file" "$wd" "$rc" "$lg"
# the person edited plan.json between the runs
set -- $(mkdead "$DEADA"); wd=$1; rc=$2; lg=$3
run "$wd" "$rc" "$lg" > /dev/null
sed -i.bak 's/"is_big(3) == false"/"is_big(4) == false"/' "$wd/plan.json"; rm -f "$wd/plan.json.bak"
reused edited "$wd" "$rc" "$lg"
# the person continues the unit: --retry, --patch
set -- $(mkdead "$DEADA"); wd=$1; rc=$2; lg=$3
run "$wd" "$rc" "$lg" > /dev/null
reused retry "$wd" "$rc" "$lg" --retry a --hint "multiply"
set -- $(mkdead "$DEADA"); wd=$1; rc=$2; lg=$3
run "$wd" "$rc" "$lg" > /dev/null
printf 'fn double(x: int) -> [] int { return x * 2; }\n' > "$rc/patch.txt"
reused patch "$wd" "$rc" "$lg" --patch a "$rc/patch.txt"
# no --guide: nothing to ask, the plan is reused as before (not a usage error)
set -- $(mkdead "$DEADA"); wd=$1; rc=$2; lg=$3
run "$wd" "$rc" "$lg" > /dev/null
out=$("$exe" "$CANCHO" "$B/brief.txt" "$wd" "sh $B/agent.sh $rc $lg" --provider stand --model m1 --attempts 4 --agent-seconds 60 --jobs 1 2>&1); r=$?
expect "not replaced (no --guide): exit code" "$r" 1
expect "not replaced (no --guide): run.log says reused" "$(stage "$wd")" "[BUILD_STAGE]:plan:reused"
expect "not replaced (no --guide): one plan call" "$(plans "$lg")" 1
rm -rf "$wd" "$rc"
# verified work kept: a and b verify, c's test is the dead end; after the re-plan a and b are re-checked and kept, only c is built
set -- $(mkdead 's/"big_double(6) == true"/"big_double(6) == false"/'); wd=$1; rc=$2; lg=$3
printf '%s\n' "$GOODA" > "$rc/a.sh"
printf 'sed -i.bak "/fn big_double/d" "$1"; printf "\\nfn big_double(x: int) -> [] bool { return is_big(double(x)); }\\n" >> "$1"\n' > "$rc/c.sh"
out=$(run "$wd" "$rc" "$lg")
expect "replan kept: the first run is stuck on c" "$(units "$out")" "a:building a:verified b:building b:verified c:building c:failed"
printf 'cp "%s" "$1"\n' "$P/plan.json" > "$rc/plan.sh"
out=$(run "$wd" "$rc" "$lg"); r=$?
expect "replan kept: exit code" "$r" 0
expect "replan kept: run.log names the unit and the test" "$(grep '^\[BUILD_STAGE\]	plan	replaced' "$wd/run.log" | cut -f4,5 | tr '\t' ':')" "c:test_c_1"
expect "replan kept: a and b kept, c built" "$(units "$out")" "a:kept b:kept c:building c:verified"
expect "replan kept: the agent calls" "$(order "$lg")" "PLAN a b c c PLAN c"
rm -rf "$wd" "$rc"

# invalid: the agent exits 0 with a plan the check refuses
set -- $(mk "$P/plan-invalid.json"); wd=$1; rc=$2; lg=$3
out=$(run "$wd" "$rc" "$lg"); r=$?
expect "invalid: exit code" "$r" 3
expect "invalid: verdict" "$(verdict "$out")" plan_failed
printf '%s\n' "$out" | grep -q '^\[PLAN_ERROR\]' || { echo "FAIL: invalid: no [PLAN_ERROR] line" >&2; fail=1; }
expect "invalid: only the plan was asked" "$(order "$lg")" PLAN
[ -f "$wd/main.cho" ] && { echo "FAIL: invalid: the project step ran (main.cho exists)" >&2; fail=1; }
printf '%s\n' "$out" | grep -q '^\[PROJECT_VERDICT\]' && { echo "FAIL: invalid: a [PROJECT_VERDICT] was printed" >&2; fail=1; }
expect "invalid: run.log verdict" "$(grep '^\[BUILD_VERDICT\]' "$wd/run.log" | cut -f2)" plan_failed
expect "invalid: build.json plan_valid" "$(jf "$wd" plan_valid)" false
expect "invalid: build.json verdict" "$(jf "$wd" verdict)" plan_failed
expect "invalid: build.json stage" "$(jf "$wd" stage)" done
expect "invalid: build.json units_total" "$(jf "$wd" units_total)" 0
rm -rf "$wd" "$rc"

# rejected: the agent used its rounds up
set -- $(mk); wd=$1; rc=$2; lg=$3
printf 'echo "cancho-agent: the plan was rejected:" >&2; echo "unit a: no examples" >&2; exit 1\n' > "$rc/plan.sh"
out=$(run "$wd" "$rc" "$lg"); r=$?
expect "rejected: exit code" "$r" 3
expect "rejected: verdict" "$(verdict "$out")" plan_failed
expect "rejected: only the plan was asked" "$(order "$lg")" PLAN
grep -q 'was rejected' "$wd/plan.log" 2>/dev/null || { echo "FAIL: rejected: plan.log lacks the agent's stderr" >&2; fail=1; }
[ -f "$wd/main.cho" ] && { echo "FAIL: rejected: the project step ran" >&2; fail=1; }
rm -rf "$wd" "$rc"

# questions
set -- $(mk); wd=$1; rc=$2; lg=$3
printf 'echo "cancho-agent: the model needs a decision, not a plan" >&2; exit 3\n' > "$rc/plan.sh"
out=$(run "$wd" "$rc" "$lg"); r=$?
expect "questions: exit code" "$r" 3
expect "questions: verdict" "$(verdict "$out")" plan_failed
rm -rf "$wd" "$rc"

# unreachable
set -- $(mk); wd=$1; rc=$2; lg=$3
rm -f "$rc/plan.sh"
out=$(run "$wd" "$rc" "$lg"); r=$?
expect "unreachable: exit code" "$r" 4
expect "unreachable: verdict" "$(verdict "$out")" provider_error
expect "unreachable: only the plan was asked" "$(order "$lg")" PLAN
[ -f "$wd/main.cho" ] && { echo "FAIL: unreachable: the project step ran" >&2; fail=1; }
expect "unreachable: build.json verdict" "$(jf "$wd" verdict)" provider_error
expect "unreachable: build.json stage" "$(jf "$wd" stage)" done
rm -rf "$wd" "$rc"

# resume: SIGKILL the build while the agent is building c
set -- $(mk); wd=$1; rc=$2; lg=$3
printf 'echo $$ > "%s/c.pid"\nexec sleep 300\n' "$rc" > "$rc/c.sh"
"$exe" "$CANCHO" "$B/brief.txt" "$wd" "sh $B/agent.sh $rc $lg" --provider stand --model m1 --guide "$B/guide.txt" --attempts 4 --agent-seconds 60 --jobs 1 > "$wd.out" 2>&1 &
bp=$!
i=0
while [ $i -lt 600 ] && [ ! -f "$rc/c.pid" ]; do sleep 0.1; i=$((i + 1)); done
[ -f "$rc/c.pid" ] || { echo "FAIL: resume: the build never reached c" >&2; fail=1; }
kill -9 "$bp" 2>/dev/null
[ -f "$rc/c.pid" ] && kill "$(cat "$rc/c.pid")" 2>/dev/null
{ wait "$bp"; } 2>/dev/null
expect "resume: the state kept a and b" "$(order "$wd/state.txt")" "verified a verified b"
expect "resume: build.json of the killed run: stage" "$(jf "$wd" stage)" build
expect "resume: build.json of the killed run: plan_valid" "$(jf "$wd" plan_valid)" true
expect "resume: build.json of the killed run: units_total" "$(jf "$wd" units_total)" 3
expect "resume: build.json of the killed run: no verdict" "$(jf "$wd" verdict)" ""
cp "$P/recipes-good/c.sh" "$rc/c.sh"
out=$(run "$wd" "$rc" "$lg"); r=$?
expect "resume: second run exit code" "$r" 0
expect "resume: second run verdict" "$(verdict "$out")" done
expect "resume: second run kept a and b" "$(units "$out")" "a:kept b:kept c:building c:verified"
expect "resume: the plan was not asked again, only c" "$(order "$lg")" "PLAN a b c c"
expect "resume: build.json units_verified" "$(jf "$wd" units_verified)" 3
expect "resume: build.json stage" "$(jf "$wd" stage)" done
rm -rf "$wd" "$rc" "$wd.out"

# review: a plan the review could not confirm is kept, and the run says so (run.log, build.json); a reviewed one says that; no review says nothing
set -- $(mk); wd=$1; rc=$2; lg=$3
printf 'cp "%s" "$1"\necho "cancho-agent: the review answer was unusable:" >&2\necho "cancho-agent: the review gave no usable answer; the plan stands unreviewed" >&2\n' "$P/plan.json" > "$rc/plan.sh"
out=$(run "$wd" "$rc" "$lg" --review on --review-guide "$B/review-guide.txt"); r=$?
expect "unreviewed: exit code (the build goes on)" "$r" 0
expect "unreviewed: verdict" "$(verdict "$out")" done
expect "unreviewed: stdout says so" "$(printf '%s\n' "$out" | grep '^\[PLAN_REVIEW\]' | cut -f2)" unreviewed
expect "unreviewed: run.log says so" "$(grep '^\[PLAN_REVIEW\]' "$wd/run.log" | cut -f2)" unreviewed
expect "unreviewed: build.json review" "$(jf "$wd" review)" unreviewed
grep -q 'stands unreviewed' "$wd/plan.log" || { echo "FAIL: unreviewed: plan.log lacks the agent's words" >&2; fail=1; }
rm -rf "$wd" "$rc"
set -- $(mk); wd=$1; rc=$2; lg=$3
printf 'cp "%s" "$1"\nprintf "cancho-agent: review:\\n[REVIEW_DROPPED]\\ta\\t2\\tplanner 1 reviewer 2\\n[REVIEW]\\tkept 5 of 6 cases\\n" >&2\n' "$P/plan.json" > "$rc/plan.sh"
out=$(run "$wd" "$rc" "$lg" --review on --review-guide "$B/review-guide.txt"); r=$?
expect "reviewed: exit code" "$r" 0
expect "reviewed: run.log says so" "$(grep '^\[PLAN_REVIEW\]' "$wd/run.log" | cut -f2)" reviewed
expect "reviewed: build.json review" "$(jf "$wd" review)" reviewed
rm -rf "$wd" "$rc"
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$(run "$wd" "$rc" "$lg"); r=$?
expect "no review: no [PLAN_REVIEW] line" "$(grep -c '^\[PLAN_REVIEW\]' "$wd/run.log")" 0
expect "no review: build.json review" "$(jf "$wd" review)" none
rm -rf "$wd" "$rc"

# provider: the unit agent for c fails
set -- $(mk); wd=$1; rc=$2; lg=$3
mv "$rc/c.sh" "$rc/c.sh.later"
out=$(run "$wd" "$rc" "$lg"); r=$?
expect "provider: exit code" "$r" 4
expect "provider: verdict" "$(verdict "$out")" provider_error
expect "provider: the state" "$(order "$wd/state.txt")" "verified a verified b"
expect "provider: build.json verdict" "$(jf "$wd" verdict)" provider_error
expect "provider: build.json units_verified" "$(jf "$wd" units_verified)" 2
expect "provider: build.json stage" "$(jf "$wd" stage)" done
expect "provider: run.log verdict" "$(grep '^\[BUILD_VERDICT\]' "$wd/run.log" | cut -f2)" provider_error
expect "provider: run.log says where the failed unit's agent log is" "$(grep '^\[AGENT_LOG\]' "$wd/run.log" | tr '\t' ':')" "[AGENT_LOG]:c:agent-c.log"
grep -q '^=== attempt 1: exit 3 after [0-9]* ms$' "$wd/agent-c.log" 2>/dev/null || { echo "FAIL: provider: agent-c.log lacks the failed turn's header" >&2; fail=1; }
grep -q 'stub-agent: unit c' "$wd/agent-c.log" 2>/dev/null || { echo "FAIL: provider: agent-c.log lacks the agent's stderr" >&2; fail=1; }
rm -rf "$wd" "$rc"

# gave up: c's agent reaches its model and has no usable answer (exit 10): the unit fails and the run is stuck (exit 1), not provider_error; run.log says why
set -- $(mk); wd=$1; rc=$2; lg=$3
printf 'echo "cancho-agent: a sample was cut off by the bound" >&2; exit 10\n' > "$rc/c.sh"
out=$(run "$wd" "$rc" "$lg"); r=$?
expect "gave up: exit code" "$r" 1
expect "gave up: verdict" "$(verdict "$out")" stuck
expect "gave up: the state keeps a and b" "$(order "$wd/state.txt")" "verified a verified b"
expect "gave up: build.json verdict" "$(jf "$wd" verdict)" stuck
expect "gave up: run.log verdict" "$(grep '^\[BUILD_VERDICT\]' "$wd/run.log" | cut -f2)" stuck
expect "gave up: run.log says why" "$(grep '^\[UNIT_WHY\]' "$wd/run.log" | tr '\t' ':')" "[UNIT_WHY]:c:agent:gave-up:cut-off"
expect "gave up: run.log names the agent log" "$(grep '^\[AGENT_LOG\]' "$wd/run.log" | tr '\t' ':')" "[AGENT_LOG]:c:agent-c.log"
grep -q 'cut off by the bound' "$wd/agent-c.log" 2>/dev/null || { echo "FAIL: gave up: agent-c.log lacks the agent's words" >&2; fail=1; }
rm -rf "$wd" "$rc"

# stuck: a is always wrong, b is independent, c depends on a
set -- $(mk "$P/plan-failing.json"); wd=$1; rc=$2; lg=$3
printf 'sed -i.bak "/fn double/d" "$1"; printf "\\nfn double(x: int) -> [] int { return x + 3; }\\n" >> "$1"\n' > "$rc/a.sh"
out=$(run "$wd" "$rc" "$lg"); r=$?
expect "stuck: exit code" "$r" 1
expect "stuck: verdict" "$(verdict "$out")" stuck
expect "stuck: unit lines" "$(units "$out")" "a:building a:failed b:building b:verified c:skipped"
expect "stuck: build.json verdict" "$(jf "$wd" verdict)" stuck
expect "stuck: build.json units_total" "$(jf "$wd" units_total)" 3
expect "stuck: build.json units_verified" "$(jf "$wd" units_verified)" 1
expect "stuck: build.json stage" "$(jf "$wd" stage)" done
rm -rf "$wd" "$rc"

# retry and patch through the one command: a is stuck, the plan stands in the work directory, the person continues
WRONGA='sed -i.bak "/fn double/d" "$1"; printf "\nfn double(x: int) -> [] int { return x + 3; }\n" >> "$1"'
set -- $(mk); wd=$1; rc=$2; lg=$3
printf '%s\n' "$WRONGA" > "$rc/a.sh"
out=$(run "$wd" "$rc" "$lg"); r=$?
expect "retry: the first run is stuck" "$(verdict "$out")" stuck
expect "retry: ... and has no retry in build.json" "$(jf "$wd" retry)" ""
printf 'if grep -q "^HINT: multiply$" "$1.task"; then printf "\nfn double(x: int) -> [] int { return x * 2; }\n" >> "$1"; else exit 4; fi\n' > "$rc/a.sh"
out=$(run "$wd" "$rc" "$lg" --retry a --hint "multiply"); r=$?
expect "retry: exit code" "$r" 0
expect "retry: verdict" "$(verdict "$out")" done
expect "retry: the plan was not asked for again; a and c were" "$(order "$lg")" "PLAN a a b a c"
expect "retry: run.log has the [RETRY] line" "$(grep '^\[RETRY\]' "$wd/run.log" | tr '\t' ':')" "[RETRY]:a:hint"
expect "retry: build.json names the unit" "$(jf "$wd" retry)" a
expect "retry: build.json verdict" "$(jf "$wd" verdict)" done
expect "retry: build.json units_verified" "$(jf "$wd" units_verified)" 3
case "$(cat "$rc/unit.args")" in *"--provider stand"*"--model m1"*) ;; *) echo "FAIL: retry: the unit agent lacks provider and model: $(cat "$rc/unit.args")" >&2; fail=1 ;; esac
case "$(cat "$rc/unit.args")" in *multiply*|*--hint*) echo "FAIL: retry: the hint went into the agent's command line: $(cat "$rc/unit.args")" >&2; fail=1 ;; esac
rm -rf "$wd" "$rc"
# patch
set -- $(mk); wd=$1; rc=$2; lg=$3
printf '%s\n' "$WRONGA" > "$rc/a.sh"
out=$(run "$wd" "$rc" "$lg")
printf '```\nfn double(x: int) -> [] int { return x * 2; }\n```\n' > "$wd.patch.txt"
out=$(run "$wd" "$rc" "$lg" --patch a "$wd.patch.txt"); r=$?
expect "patch: exit code" "$r" 0
expect "patch: verdict" "$(verdict "$out")" done
expect "patch: no model call for a: only c was asked" "$(order "$lg")" "PLAN a a b c"
expect "patch: run.log has the [PATCH] lines" "$(grep '^\[PATCH\]' "$wd/run.log" | cut -f2,3 | tr '\t' ':' | tr '\n' ' ')" "a:applying a:verified "
expect "patch: build.json names the unit" "$(jf "$wd" patch)" a
rm -rf "$wd" "$rc" "$wd.patch.txt"
# the person's own code that does not verify: refused, the stuck run stays as it was, exit 1
set -- $(mk); wd=$1; rc=$2; lg=$3
printf '%s\n' "$WRONGA" > "$rc/a.sh"
out=$(run "$wd" "$rc" "$lg")
cp "$wd/project.cho" "$wd.before"
printf 'fn double(x: int) -> [] int { return x + 9; }\n' > "$wd.patch.txt"
out=$(run "$wd" "$rc" "$lg" --patch a "$wd.patch.txt"); r=$?
expect "patch refused: exit code" "$r" 1
expect "patch refused: verdict" "$(verdict "$out")" stuck
cmp -s "$wd/project.cho" "$wd.before" || { echo "FAIL: patch refused: project.cho was not restored" >&2; fail=1; }
expect "patch refused: run.log says so" "$(grep '^\[PATCH\]' "$wd/run.log" | cut -f2,3 | tr '\t' ':' | tr '\n' ' ')" "a:applying a:refused "
rm -rf "$wd" "$rc" "$wd.before" "$wd.patch.txt"
# redo usage: nothing is written in the work directory
redo_usage() { # name part args...
    name=$1; part=$2; shift 2
    set -- "$@"
    w=$(mktemp -d -t cc-build-wd-XXXXXX); r=$(mktemp -d -t cc-build-rc-XXXXXX); l="$r/agent.log"; : > "$l"; cp "$P"/recipes-good/*.sh "$r"/
    printf 'cp "%s" "$1"\n' "$P/plan.json" > "$r/plan.sh"
    if [ "$name" != "no plan" ]; then cp "$P/plan.json" "$w/plan.json"; fi
    before=$(cd "$w" && find . -type f | sort | xargs cksum 2>/dev/null)
    o=$(run "$w" "$r" "$l" "$@"); rr=$?
    expect "redo usage ($name): exit code" "$rr" 2
    case "$o" in *"$part"*) ;; *) echo "FAIL: redo usage ($name): no message with '$part': $o" >&2; fail=1 ;; esac
    expect "redo usage ($name): nothing was written" "$(cd "$w" && find . -type f | sort | xargs cksum 2>/dev/null)" "$before"
    expect "redo usage ($name): the agent was never asked" "$(wc -c < "$l" | tr -d ' ')" 0
    rm -rf "$w" "$r"
}
POK=$(mktemp -t cc-build-patch-XXXXXX); printf 'fn double(x: int) -> [] int { return x * 2; }\n' > "$POK"
redo_usage "unit not in the plan" "does not have" --retry nosuch --hint x
redo_usage "patch unit not in the plan" "does not have" --patch nosuch "$POK"
redo_usage "no plan" "no valid plan.json" --retry a --hint x
redo_usage "empty hint" "empty" --retry a --hint ""
redo_usage "retry and patch" "together" --retry a --patch b "$POK"
redo_usage "patch file missing" "cannot be read" --patch a /no/such/file.txt
redo_usage "hint without retry" "goes with --retry" --hint x
redo_usage "patch without its file" "option it does not know, or without its value" --patch a
redo_usage "retry without a unit" "needs a unit" --retry ""
rm -f "$POK"

# memory: --memory goes to the unit agent; --remember adds a line of the person's own
set -- $(mk); wd=$1; rc=$2; lg=$3
mm=$(mktemp -d -t cc-build-mem-XXXXXX)
out=$(run "$wd" "$rc" "$lg"); expect "memory: without --memory: exit code" "$?" 0
case "$(cat "$rc/unit.args")" in *--memory*) echo "FAIL: memory: the unit agent got --memory though none was named" >&2; fail=1 ;; esac
rm -rf "$wd" "$rc"
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$(run "$wd" "$rc" "$lg" --memory "$mm" --remember "no network"); expect "memory: exit code" "$?" 0
expect "memory: the unit agent got --memory <dir>" "$(grep -c -- "--memory $mm" "$rc/unit.args")" 1
expect "memory: the fact was added" "$(cat "$mm/facts.txt")" "no network"
rm -rf "$wd" "$rc"
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$(run "$wd" "$rc" "$lg" --memory "$mm" --remember "public names are lowercase_with_underscores"); expect "memory: a second fact: exit code" "$?" 0
expect "memory: the facts are kept in order" "$(cat "$mm/facts.txt" | tr '\n' '|')" "no network|public names are lowercase_with_underscores|"
rm -rf "$wd" "$rc"
mem_usage() { # name part args...
    name=$1; part=$2; shift 2
    set -- "$@"
    w=$(mktemp -d -t cc-build-wd-XXXXXX); r=$(mktemp -d -t cc-build-rc-XXXXXX); l="$r/agent.log"; : > "$l"; cp "$P"/recipes-good/*.sh "$r"/
    printf 'cp "%s" "$1"\n' "$P/plan.json" > "$r/plan.sh"
    bf=$(cat "$mm/facts.txt")
    o=$(run "$w" "$r" "$l" "$@"); rr=$?
    expect "memory usage ($name): exit code" "$rr" 2
    case "$o" in *"$part"*) ;; *) echo "FAIL: memory usage ($name): no message with '$part': $o" >&2; fail=1 ;; esac
    expect "memory usage ($name): the facts are as they were" "$(cat "$mm/facts.txt")" "$bf"
    expect "memory usage ($name): the agent was never asked" "$(wc -c < "$l" | tr -d ' ')" 0
    rm -rf "$w" "$r"
}
mem_usage "empty text" "non-empty line" --memory "$mm" --remember ""
mem_usage "blank text" "non-empty line" --memory "$mm" --remember "   "
mem_usage "two lines" "non-empty line" --memory "$mm" --remember "$(printf 'one\ntwo')"
mem_usage "over 160 bytes" "at most 160" --memory "$mm" --remember "$(printf 'x%.0s' $(seq 1 170))"
mem_usage "no --memory" "needs --memory" --remember "no network"
mem_usage "relative dir" "absolute directory" --memory relative/dir
mem_usage "dotdot dir" "absolute directory" --memory "$mm/../x"
mem_usage "memory without a directory" "absolute directory" --memory ""
i=0; while [ $i -lt 8 ]; do printf 'fact %s\n' "$i" >> "$mm/facts.txt"; i=$((i + 1)); done
mem_usage "an eleventh fact" "ten facts" --memory "$mm" --remember "one too many"
rm -rf "$mm"

# usage
set -- $(mk); wd=$1; rc=$2; lg=$3
"$exe" >/dev/null 2>&1; expect "usage: no arguments" "$?" 2
agent="sh $B/agent.sh $rc $lg"
"$exe" "$CANCHO" "$B/brief.txt" "$wd" "$agent" --model m1 --guide "$B/guide.txt" >/dev/null 2>&1; expect "usage: no --provider" "$?" 2
"$exe" "$CANCHO" "$B/brief.txt" "$wd" "$agent" --provider stand --guide "$B/guide.txt" >/dev/null 2>&1; expect "usage: no --model" "$?" 2
"$exe" "$CANCHO" "$B/brief.txt" "$wd" "$agent" --provider stand --model m1 >/dev/null 2>&1; expect "usage: no plan and no --guide" "$?" 2
out=$("$exe" cancho "$B/brief.txt" "$wd" "$agent" --provider stand --model m1 --guide "$B/guide.txt" 2>&1); r=$?
expect "usage: a relative checker" "$r" 2
case "$out" in *absolute*) ;; *) echo "FAIL: usage: a relative checker: no message that says 'absolute' ('$out')" >&2; fail=1 ;; esac
out=$("$exe" "$CANCHO" "$B/brief.txt" "$wd/../$(basename "$wd")" "$agent" --provider stand --model m1 --guide "$B/guide.txt" 2>&1); r=$?
expect "usage: a work directory with .." "$r" 2
case "$out" in *".."*) ;; *) echo "FAIL: usage: a work directory with .. : no message that names '..' ('$out')" >&2; fail=1 ;; esac
"$exe" "$CANCHO" "$B/../build/brief.txt" "$wd" "$agent" --provider stand --model m1 --guide "$B/guide.txt" >/dev/null 2>&1; expect "usage: a brief with .." "$?" 2
"$exe" "$CANCHO" "$B/brief.txt" "$wd" "$agent" --provider stand --model m1 --guide "$B/guide.txt" --bogus 1 >/dev/null 2>&1; expect "usage: an unknown option" "$?" 2
"$exe" "$CANCHO" "$B/brief.txt" "$wd" "$agent" --provider stand --model m1 --guide "$B/guide.txt" --review on >/dev/null 2>&1; expect "usage: --review on without --review-guide" "$?" 2
"$exe" "$CANCHO" "$B/brief.txt" "$wd" "$agent" --provider stand --model m1 --guide "$B/guide.txt" --rounds x >/dev/null 2>&1; expect "usage: --rounds that is not a number" "$?" 2
"$exe" "$CANCHO" "$B/does-not-exist.txt" "$wd" "$agent" --provider stand --model m1 --guide "$B/guide.txt" >/dev/null 2>&1; expect "usage: a brief that is not there" "$?" 2
"$exe" "$CANCHO" "$B/brief.txt" "$wd.nope" "$agent" --provider stand --model m1 --guide "$B/guide.txt" >/dev/null 2>&1; expect "usage: a work directory that is not there" "$?" 2
expect "usage: the agent was never asked" "$(wc -c < "$lg" | tr -d ' ')" 0
[ -f "$wd/build.json" ] && { echo "FAIL: usage: a usage error wrote build.json" >&2; fail=1; }
rm -rf "$wd" "$rc"

# names: what the brief calls its functions are the plan's names
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$("$exe" "$CANCHO" "$B/brief-names.txt" "$wd" "sh $B/agent.sh $rc $lg" --provider stand --model m1 --guide "$B/guide.txt" --attempts 4 --agent-seconds 60 --jobs 1 2>&1); r=$?
expect "names held: exit code" "$r" 0
expect "names held: verdict" "$(verdict "$out")" done
printf '%s\n' "$out" | grep -q 'brief-name' && { echo "FAIL: names held: a brief-name error" >&2; fail=1; }
rm -rf "$wd" "$rc"
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$("$exe" "$CANCHO" "$B/brief-renamed.txt" "$wd" "sh $B/agent.sh $rc $lg" --provider stand --model m1 --guide "$B/guide.txt" --attempts 4 --agent-seconds 60 --jobs 1 2>&1); r=$?
expect "names missing: exit code" "$r" 3
expect "names missing: verdict" "$(verdict "$out")" plan_failed
expect "names missing: the missing name" "$(printf '%s\n' "$out" | grep '^\[PLAN_ERROR\]' | cut -f2,3 | tr '\t' ':')" "brief-name:is_huge"
expect "names missing: only the plan was asked" "$(order "$lg")" PLAN
[ -f "$wd/main.cho" ] && { echo "FAIL: names missing: the project step ran" >&2; fail=1; }
rm -rf "$wd" "$rc"
# a valid plan.json from an earlier run that lacks a required name is asked for again, not reused
set -- $(mk); wd=$1; rc=$2; lg=$3
cp "$P/plan.json" "$wd/plan.json"
out=$("$exe" "$CANCHO" "$B/brief-renamed.txt" "$wd" "sh $B/agent.sh $rc $lg" --provider stand --model m1 --guide "$B/guide.txt" --attempts 4 --agent-seconds 60 --jobs 1 2>&1); r=$?
expect "names reuse: the plan was asked for again" "$(order "$lg")" PLAN
rm -rf "$wd" "$rc"

# a function the brief names whose result owns nothing, planned with a heap (`brief-heap`, docs/plan.md "The call shape"): refused before any unit
set -- $(mk "$B/plan-heap.json"); wd=$1; rc=$2; lg=$3
out=$("$exe" "$CANCHO" "$B/brief-names.txt" "$wd" "sh $B/agent.sh $rc $lg" --provider stand --model m1 --guide "$B/guide.txt" --attempts 4 --agent-seconds 60 --jobs 1 2>&1); r=$?
expect "brief heap: exit code" "$r" 3
expect "brief heap: verdict" "$(verdict "$out")" plan_failed
expect "brief heap: the unit" "$(printf '%s\n' "$out" | grep '^\[PLAN_ERROR\]' | cut -f2,3 | tr '\t' ':')" "brief-heap:a"
expect "brief heap: only the plan was asked" "$(order "$lg")" PLAN
[ -f "$wd/main.cho" ] && { echo "FAIL: brief heap: the project step ran" >&2; fail=1; }
rm -rf "$wd" "$rc"

# a name that is only the start of a declared name is not declared (`doub` against `fn double`)
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$("$exe" "$CANCHO" "$B/brief-prefix.txt" "$wd" "sh $B/agent.sh $rc $lg" --provider stand --model m1 --guide "$B/guide.txt" --attempts 4 --agent-seconds 60 --jobs 1 2>&1); r=$?
expect "names prefix: exit code" "$r" 3
expect "names prefix: the missing name" "$(printf '%s\n' "$out" | grep '^\[PLAN_ERROR\]' | cut -f2,3 | tr '\t' ':')" "brief-name:doub"
rm -rf "$wd" "$rc"

rm -f "$exe"
[ "$fail" = 0 ] && echo "build gate: ok" || { echo "build gate: FAILED" >&2; exit 1; }
