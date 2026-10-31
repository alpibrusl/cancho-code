#!/bin/sh
# The journal gate (docs/journal.md): a run leaves a journal from which the whole story can be told. The build tool runs against a stand-in
# agent (tests/journal/agent.sh) that plays the plan agent and the unit agent from recipes and, with `sidecars`, leaves what the native agent
# leaves beside the project file. No model, no network, no key. The checker is the real compiler. Reading the journal is tests/journal/check.py.
#
#   happy       two units need a second attempt (a fails its examples, b is refused by the compiler): the events in the order they happened,
#               every attempt with its outcome and decision, the units' ends, the sweeps, the run's start and end
#   refusal     the checker blob of a refused attempt is the compiler's WHOLE answer for the code of that attempt (the compiler is run again to compare)
#   diff        an attempt's diff turns the previous attempt's code (the file before the unit for the first) into this attempt's code (patch rebuilds it)
#   sidecars    the prompt, reply, tokens, stop, stderr the agent left reach the attempt; the primer is stored once; the agent's stderr is kept
#   memory      the lessons and facts the agent's memory added (`memory.json`, docs/memory.md) reach the attempt as its `memory` field; a file that is not
#               a JSON array is left out; a turn that leaves none has none (the driver clears the sidecar before each turn)
#   nosidecar   an agent that leaves nothing: the attempt still has code, checker, acceptance, diff, stderr; the missing fields are absent
#   cap         a 300 kB reply is cut to 262144 bytes with a visible marker; no blob is over the cap
#   stuck       a unit that never verifies: its attempts, `stuck`, the run's verdict
#   provider    an agent that fails: the attempt says agent_failed with its exit, the unit says unavailable, the run provider_error
#   gave up     an agent that exits with a documented gave-up code (11): the attempt is agent_failed WITH the signature agent:gave-up:no-program, the same-signature
#               stop ends the unit stuck, the run stuck (exit 1), not provider_error
#   killed      a run killed with SIGKILL leaves a journal whose every line is whole; the next run appends to it
#
# Needs the real cancho as CANCHO. JOURNAL_SRC names a directory to take src/ from (the mutation runs). Exit 0: every case held.
set -u

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
export CANCHO
root=$(cd "$(dirname "$0")/.." && pwd)
SRC="${JOURNAL_SRC:-$root/src}"
exe=$(mktemp -t cc-journal-XXXXXX)
files=""
for f in build project plan driver checker signature loop_check snapshot trail acceptance splice pool parallel library cases change repochange; do
    [ -f "$SRC/$f.cho" ] && files="$files $SRC/$f.cho"
done
"$CANCHO" build "$root/tests/programs/build.cho" $files --std --backend cranelift -o "$exe" || { echo "gate did not build" >&2; exit 2; }

fail=0
expect() { [ "$2" = "$3" ] || { echo "FAIL: $1: wanted '$3', got '$2'" >&2; fail=1; }; }
J="$root/tests/journal"
B="$root/tests/buildcmd"
P="$root/tests/project"
q() { python3 -I "$J/check.py" "$@"; }
verdict() { printf '%s\n' "$1" | grep '^\[BUILD_VERDICT\]' | cut -f2; }

# a fresh work directory with the recipes for the two-attempt units; echoes "<workdir> <recipes> <log>"
mk() {
    wd=$(mktemp -d -t cc-journal-wd-XXXXXX); rc=$(mktemp -d -t cc-journal-rc-XXXXXX); lg="$rc/agent.log"
    : > "$lg"
    printf 'cp "%s" "$1"\n' "${1:-$P/plan.json}" > "$rc/plan.sh"
    # a: the first answer fails its examples, the second is right
    printf 'printf "\\nfn double(x: int) -> [] int { return x * 3; }\\n" >> "$1"\n' > "$rc/a.1.sh"
    printf 'sed -i.bak "/fn double/d" "$1"; printf "\\nfn double(x: int) -> [] int { return x * 2; }\\n" >> "$1"\n' > "$rc/a.2.sh"
    # b: the first answer is refused by the compiler, the second is right
    printf 'printf "\\nfn is_big(x: int) -> [] bool { return x > ; }\\n" >> "$1"\n' > "$rc/b.1.sh"
    printf 'sed -i.bak "/fn is_big/d" "$1"; printf "\\nfn is_big(x: int) -> [] bool { return x > 10; }\\n" >> "$1"\n' > "$rc/b.2.sh"
    cp "$P/recipes-good/c.sh" "$rc/c.sh"
    echo "$wd $rc $lg"
}
run() { # wd recipes log [more options]
    w=$1; r=$2; l=$3; shift 3
    "$exe" "$CANCHO" "$B/brief.txt" "$w" "sh $J/agent.sh $r $l" --provider stand --model m1 --guide "$B/guide.txt" --attempts 4 --agent-seconds 60 --jobs 1 "$@" 2>&1
}

# happy, refusal, diff, sidecars
set -- $(mk); wd=$1; rc=$2; lg=$3
: > "$rc/sidecars"
out=$(run "$wd" "$rc" "$lg"); r=$?
expect "happy: exit code" "$r" 0
expect "happy: verdict" "$(verdict "$out")" done
expect "happy: the events, in the order things happened" "$(q "$wd" kinds)" "run_start plan_final unit_start attempt attempt unit_end unit_start attempt attempt unit_end sweep unit_start attempt unit_end sweep run_end"
expect "happy: the attempts" "$(q "$wd" attempts)" "a/0:acceptance_failed:retry a/1:verified:verified b/0:refused:retry b/1:verified:verified c/0:verified:verified"
expect "happy: the units' ends" "$(q "$wd" units)" "a:verified:2 b:verified:2 c:verified:1"
expect "happy: the sweeps" "$(q "$wd" sweeps)" "b>a| c>a,b|"
expect "happy: every blob named is there and within the cap" "$(q "$wd" blobs)" ok
expect "happy: run_start" "$(q "$wd" first run_start)" "{\"brief\": \"$B/brief.txt\", \"kind\": \"run_start\", \"model\": \"m1\", \"options\": {\"agent_seconds\": 60, \"attempts\": 4, \"plan_seconds\": 900, \"review\": false, \"rounds\": 3}, \"provider\": \"stand\"}"
expect "happy: plan_final" "$(q "$wd" first plan_final | sed 's/"plan": "[^"]*"/"plan": "P"/')" '{"kind": "plan_final", "plan": "P", "units": 3, "valid": true}'
expect "happy: the plan blob is the plan" "$(cmp "$wd/plan.json" "$wd/journal/blobs/$(q "$wd" first plan_final | sed -n 's/.*"plan": "\([^"]*\)".*/\1/p')" && echo same)" same
expect "happy: run_end verdict" "$(q "$wd" first run_end | sed 's/"seconds": [0-9]*/"seconds": N/')" '{"exit": 0, "kind": "run_end", "seconds": N, "verdict": "done"}'
expect "refusal: the compiler's whole answer (b, first attempt)" "$(q "$wd" refusal b 0 | tr '\n' ' ')" "same refused "
expect "refusal: and a clean one (b, second attempt)" "$(q "$wd" refusal b 1 | tr '\n' ' ')" "same clean "
expect "refusal: the short signature is in the event" "$([ -n "$(q "$wd" field b 0 signature)" ] && echo yes)" yes
expect "refusal: a failing example is in the acceptance blob" "$(q "$wd" blobtext a 0 acceptance | grep -c 'FAILED')" 1
expect "diff: b, second attempt, from the first" "$(q "$wd" diff b 1)" rebuilds
expect "diff: c, first attempt, from the file before the unit" "$(q "$wd" diff c 0 "$wd/project.cho.before")" rebuilds
expect "sidecars: the prompt" "$(q "$wd" blobtext a 1 prompt | cut -c1-29)" "PROMPT a try 2 | --- task ---"
expect "sidecars: the reply" "$(q "$wd" blobtext a 1 reply)" "REPLY a try 2"
expect "sidecars: the tokens" "$(q "$wd" field a 1 tokens)" '{"cache_read": 9000, "cache_write": 0, "in": 102, "out": 20, "thinking": 3}'
expect "sidecars: the stop reason" "$(q "$wd" field a 1 stop)" end_turn
expect "sidecars: the primer flag" "$(q "$wd" field a 1 primer)" true
expect "sidecars: the agent's stderr" "$(q "$wd" blobtext a 1 stderr)" "agent says: unit a try 2"
expect "sidecars: the stderr blob is exactly what the agent printed in that attempt, not the attempts before" "$(q "$wd" blobraw a 1 stderr)" "'agent says: unit a try 2\\n'"
expect "sidecars: the project driver's own agent log is as it was" "$(grep -c '^=== attempt' "$wd/agent-a.log")" 2
expect "sidecars: the agent's exit" "$(q "$wd" field a 1 exit)" 0
expect "sidecars: the feedback the agent was shown (the acceptance failure)" "$(q "$wd" blobtext a 1 feedback | grep -c 'acceptance check failed')" 1
expect "sidecars: the primer is stored once" "$(q "$wd" primer)" primer.txt
expect "sidecars: one attempt event per attempt" "$(q "$wd" count attempt)" 5
expect "sidecars: the project files are as they were (state)" "$(tr '\n' ' ' < "$wd/state.txt" | sed 's/ $//')" "verified a verified b verified c"
expect "sidecars: the trail is as it was" "$(wc -l < "$wd/trail-a.jsonl" | tr -d ' ')" 2
rm -rf "$wd" "$rc"

# memory
set -- $(mk); wd=$1; rc=$2; lg=$3
: > "$rc/sidecars"; : > "$rc/memory"
out=$(run "$wd" "$rc" "$lg"); r=$?
expect "memory: exit code" "$r" 0
expect "memory: the field on the attempt that had it" "$(q "$wd" field a 0 memory)" '[{"id": "L864bef6c", "text": "a lesson text"}, {"id": "F1", "text": "no network"}]'
expect "memory: not on the next attempt of the unit (the sidecar is cleared)" "$(q "$wd" field a 1 memory)" "<absent>"
expect "memory: a file that is not an array is left out" "$(q "$wd" field b 0 memory)" "<absent>"
expect "memory: every other event is as it was" "$(q "$wd" kinds)" "run_start plan_final unit_start attempt attempt unit_end unit_start attempt attempt unit_end sweep unit_start attempt unit_end sweep run_end"
rm -rf "$wd" "$rc"

# nosidecar
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$(run "$wd" "$rc" "$lg"); r=$?
expect "nosidecar: exit code" "$r" 0
expect "nosidecar: the attempts" "$(q "$wd" attempts)" "a/0:acceptance_failed:retry a/1:verified:verified b/0:refused:retry b/1:verified:verified c/0:verified:verified"
expect "nosidecar: no prompt" "$(q "$wd" field a 1 prompt)" "<absent>"
expect "nosidecar: no reply" "$(q "$wd" field a 1 reply)" "<absent>"
expect "nosidecar: no tokens" "$(q "$wd" field a 1 tokens)" "<absent>"
expect "nosidecar: the code is there" "$(q "$wd" blobtext a 1 code | grep -c 'x \* 2')" 1
expect "nosidecar: the stderr is the driver's own capture" "$(q "$wd" blobtext a 1 stderr)" "agent says: unit a try 2"
expect "nosidecar: every blob named is there" "$(q "$wd" blobs)" ok
expect "nosidecar: the refusal is whole" "$(q "$wd" refusal b 0 | tr '\n' ' ')" "same refused "
expect "nosidecar: the diff rebuilds" "$(q "$wd" diff b 1)" rebuilds
rm -rf "$wd" "$rc"

# cap
set -- $(mk); wd=$1; rc=$2; lg=$3
: > "$rc/sidecars"; : > "$rc/bigreply"
out=$(run "$wd" "$rc" "$lg"); r=$?
expect "cap: exit code" "$r" 0
expect "cap: the 300 kB reply is cut, with a marker" "$(q "$wd" blobsize a 0 reply)" "within marker long"
expect "cap: no blob is over the cap" "$(q "$wd" blobs)" ok
rm -rf "$wd" "$rc"

# stuck: a is always wrong
set -- $(mk "$P/plan-failing.json"); wd=$1; rc=$2; lg=$3
rm -f "$rc/a.1.sh" "$rc/a.2.sh"
printf 'sed -i.bak "/fn double/d" "$1"; printf "\\nfn double(x: int) -> [] int { return x + 3; }\\n" >> "$1"\n' > "$rc/a.sh"
out=$(run "$wd" "$rc" "$lg"); r=$?
expect "stuck: exit code" "$r" 1
expect "stuck: the units' ends" "$(q "$wd" units)" "a:stuck:2 b:verified:2"
expect "stuck: a's attempts end with the same-signature stop" "$(q "$wd" attempts | tr ' ' '\n' | grep '^a/' | tr '\n' ' ')" "a/0:acceptance_failed:retry a/1:acceptance_failed:signature "
expect "stuck: the run's end" "$(q "$wd" first run_end | sed 's/"seconds": [0-9]*/"seconds": N/')" '{"exit": 1, "kind": "run_end", "seconds": N, "verdict": "stuck"}'
rm -rf "$wd" "$rc"

# provider: the agent for c fails
set -- $(mk); wd=$1; rc=$2; lg=$3
rm -f "$rc/c.sh"
out=$(run "$wd" "$rc" "$lg"); r=$?
expect "provider: exit code" "$r" 4
expect "provider: c's attempt" "$(q "$wd" attempts | tr ' ' '\n' | grep '^c/')" "c/0:agent_failed:agent_exit"
expect "provider: the agent's exit" "$(q "$wd" field c 0 exit)" 3
expect "provider: the unit's end" "$(q "$wd" units)" "a:verified:2 b:verified:2 c:unavailable:1"
expect "provider: the run's end" "$(q "$wd" first run_end | sed 's/"seconds": [0-9]*/"seconds": N/')" '{"exit": 4, "kind": "run_end", "seconds": N, "verdict": "provider_error"}'
rm -rf "$wd" "$rc"

# gave up: c's agent reaches its model and finds no program (exit 11): the unit fails, it is not the provider; the attempt keeps the name agent_failed
# and gets the signature, the same-signature stop ends the unit stuck, the run ends stuck (exit 1)
set -- $(mk); wd=$1; rc=$2; lg=$3
printf 'echo "cancho-agent: a sample has no program in it (reasoning, not a file)" >&2; exit 11\n' > "$rc/c.sh"
out=$(run "$wd" "$rc" "$lg"); r=$?
expect "gave up: exit code" "$r" 1
expect "gave up: c's attempts" "$(q "$wd" attempts | tr ' ' '\n' | grep '^c/' | tr '\n' ' ')" "c/0:agent_failed:retry c/1:agent_failed:signature "
expect "gave up: the signature is named" "$(q "$wd" field c 1 signature)" "agent:gave-up:no-program"
expect "gave up: the agent's exit" "$(q "$wd" field c 1 exit)" 11
expect "gave up: the unit's end" "$(q "$wd" units)" "a:verified:2 b:verified:2 c:stuck:2"
expect "gave up: every blob named is there" "$(q "$wd" blobs)" ok
expect "gave up: the run's end" "$(q "$wd" first run_end | sed 's/"seconds": [0-9]*/"seconds": N/')" '{"exit": 1, "kind": "run_end", "seconds": N, "verdict": "stuck"}'
rm -rf "$wd" "$rc"

# killed: SIGKILL the build while the agent is building c
set -- $(mk); wd=$1; rc=$2; lg=$3
printf 'echo $$ > "%s/c.pid"\nexec sleep 300\n' "$rc" > "$rc/c.sh"
"$exe" "$CANCHO" "$B/brief.txt" "$wd" "sh $J/agent.sh $rc $lg" --provider stand --model m1 --guide "$B/guide.txt" --attempts 4 --agent-seconds 60 --jobs 1 > "$wd.out" 2>&1 &
bp=$!
i=0
while [ $i -lt 600 ] && [ ! -f "$rc/c.pid" ]; do sleep 0.1; i=$((i + 1)); done
kill -9 "$bp" 2>/dev/null
[ -f "$rc/c.pid" ] && kill "$(cat "$rc/c.pid")" 2>/dev/null
{ wait "$bp"; } 2>/dev/null
expect "killed: the journal is whole lines, ending where the run was" "$(q "$wd" kinds)" "run_start plan_final unit_start attempt attempt unit_end unit_start attempt attempt unit_end sweep unit_start"
cp "$P/recipes-good/c.sh" "$rc/c.sh"
out=$(run "$wd" "$rc" "$lg"); r=$?
expect "killed: second run exit code" "$r" 0
expect "killed: the second run appended; the journal is whole" "$(q "$wd" count run_start)/$(q "$wd" count run_end)" "2/1"
expect "killed: the second run's units" "$(q "$wd" units)" "a:verified:2 b:verified:2 c:verified:1"
rm -rf "$wd" "$rc" "$wd.out"

rm -f "$exe"
[ "$fail" = 0 ] && echo "journal gate: ok" || { echo "journal gate: FAILED" >&2; exit 1; }
