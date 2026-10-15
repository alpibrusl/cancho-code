#!/bin/sh
# The build gate (docs/build.md): one command from a brief to a verified build, against a stand-in agent (tests/buildcmd/agent.sh) that plays
# both the plan agent and the unit agent from recipes. No model, no network, no key. The checker is the real compiler.
#
#   happy       the agent writes the plan, the units are built in order: done, exit 0, verdict in stdout AND run.log, build.json complete
#   args        the plan call gets --mode plan, the guide, the brief, the rounds, the usage log, the review flags; both calls get provider and model
#   reuse       a valid plan.json already in the work directory is not asked for again; an invalid one is replaced
#   invalid     the agent "succeeds" with a plan the check refuses: its errors, plan_failed, exit 3, the project step never runs
#   rejected    the agent gives up after its rounds (exit 1, the plan was rejected): plan_failed, exit 3, its stderr kept in plan.log
#   questions   the model needs a decision (agent exit 3): plan_failed
#   unreachable the agent cannot reach the API: provider_error, exit 4, the project step never runs
#   resume      a run killed (SIGKILL) while building the third unit: build.json says stage build; the next run asks for no plan, keeps a and b
#   review      a plan the agent's review could not confirm ("the plan stands unreviewed" in plan.log) is built, and run.log (`[PLAN_REVIEW]`) and build.json (`review`) say unreviewed; a reviewed one says reviewed; with no review, none
#   provider    the unit agent fails: provider_error, exit 4, the state keeps what verified, build.json agrees; run.log names the unit's agent log (`[AGENT_LOG]`), which holds the turn's header and the agent's standard error
#   stuck       a unit never verifies: stuck, exit 1, build.json counts the verified ones
#   names       the brief names its public functions (`- name(...) : ...`): a plan that does not declare one is refused (`brief-name`), plan_failed, exit 3; a plan that does is built; a valid plan.json that lacks one is not reused
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
    "$SRC/acceptance.cho" --std --backend cranelift -o "$exe" || { echo "gate did not build" >&2; exit 2; }

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
    "$exe" "$CANCHO" "$B/brief.txt" "$w" "sh $B/agent.sh $r $l" --provider stand --model m1 --guide "$B/guide.txt" --attempts 4 --agent-seconds 60 "$@" 2>&1
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
"$exe" "$CANCHO" "$B/brief.txt" "$wd" "sh $B/agent.sh $rc $lg" --provider stand --model m1 --guide "$B/guide.txt" --attempts 4 --agent-seconds 60 > "$wd.out" 2>&1 &
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
out=$("$exe" "$CANCHO" "$B/brief-names.txt" "$wd" "sh $B/agent.sh $rc $lg" --provider stand --model m1 --guide "$B/guide.txt" --attempts 4 --agent-seconds 60 2>&1); r=$?
expect "names held: exit code" "$r" 0
expect "names held: verdict" "$(verdict "$out")" done
printf '%s\n' "$out" | grep -q 'brief-name' && { echo "FAIL: names held: a brief-name error" >&2; fail=1; }
rm -rf "$wd" "$rc"
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$("$exe" "$CANCHO" "$B/brief-renamed.txt" "$wd" "sh $B/agent.sh $rc $lg" --provider stand --model m1 --guide "$B/guide.txt" --attempts 4 --agent-seconds 60 2>&1); r=$?
expect "names missing: exit code" "$r" 3
expect "names missing: verdict" "$(verdict "$out")" plan_failed
expect "names missing: the missing name" "$(printf '%s\n' "$out" | grep '^\[PLAN_ERROR\]' | cut -f2,3 | tr '\t' ':')" "brief-name:is_huge"
expect "names missing: only the plan was asked" "$(order "$lg")" PLAN
[ -f "$wd/main.cho" ] && { echo "FAIL: names missing: the project step ran" >&2; fail=1; }
rm -rf "$wd" "$rc"
# a valid plan.json from an earlier run that lacks a required name is asked for again, not reused
set -- $(mk); wd=$1; rc=$2; lg=$3
cp "$P/plan.json" "$wd/plan.json"
out=$("$exe" "$CANCHO" "$B/brief-renamed.txt" "$wd" "sh $B/agent.sh $rc $lg" --provider stand --model m1 --guide "$B/guide.txt" --attempts 4 --agent-seconds 60 2>&1); r=$?
expect "names reuse: the plan was asked for again" "$(order "$lg")" PLAN
rm -rf "$wd" "$rc"

# a name that is only the start of a declared name is not declared (`doub` against `fn double`)
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$("$exe" "$CANCHO" "$B/brief-prefix.txt" "$wd" "sh $B/agent.sh $rc $lg" --provider stand --model m1 --guide "$B/guide.txt" --attempts 4 --agent-seconds 60 2>&1); r=$?
expect "names prefix: exit code" "$r" 3
expect "names prefix: the missing name" "$(printf '%s\n' "$out" | grep '^\[PLAN_ERROR\]' | cut -f2,3 | tr '\t' ':')" "brief-name:doub"
rm -rf "$wd" "$rc"

rm -f "$exe"
[ "$fail" = 0 ] && echo "build gate: ok" || { echo "build gate: FAILED" >&2; exit 1; }
