#!/bin/sh
# The parallel-units gate (docs/parallel.md): the project driver with `--jobs N` against stand-in agents that sleep and then write a recipe's code (tests/parallel/agent.sh).
# No model, no network. The checker is the real compiler. Timing is read from the journal (unit_start / unit_end t_ms), with slack for loaded machines.
#
#   pool        src/pool.cho: seven children at once on one poller, each one's output and exit code, one killed by `close`, the output cap
#   merge       src/splice.cho merge3: a clean merge, a replaced item, the same text twice, a clash
#   overlap     independent units overlap in time (the sum of their durations beats the wall time), a dependent never starts before the units it needs
#               ended, each in-flight unit has a lane of its own
#   jobs        `--jobs 2` never has more than two units in flight
#   jobs 1      `--jobs 1` is the sequential driver: console output, project.cho, state.txt and the journal's events byte-identical to a run with no option
#   cold        no model call yet: ONE unit is dispatched, the others when its first call has returned (meta.json); an agent that never says so gets the rest
#               when the first unit has ended
#   clash       two units that each pass alone and define the same name differently: the second to finish is requeued with the clash as its feedback, rebuilt
#               on the project file as it is then, and verifies; one `shared` is in the file
#   combined    two units whose items merge cleanly but do not compile together (two modules under one alias): the combined check refuses, the unit is requeued
#               with the compiler's words as feedback
#   memory      `--memory <dir>` in the agent command reaches a unit built beside others, and what the memory added is on its attempt event
#   retry/patch `--retry U --hint` and `--patch U file` with --jobs 4: only U and what needs it are worked on, the hint reaches the worker's task, a patch needs no model
#   rewrite     a unit that changes what was there makes the units that had verified run again; one that only added does not
#   order       units that end together are integrated in plan order, whatever the order they ended in (`--settle`); the journal says so
#   isolation   one unit's agent fails (exit 3) while others are running: they finish and are kept, nothing new is started, provider_error; the rerun builds the rest
#   stuck       a unit that is never right fails alone: independent units verify, its dependent is skipped, stuck
#   no leak     while a unit is in flight, the project file has none of its work
#   kill        kill -9 of the driver with units in flight: what verified is kept, the scratch workspaces and their processes are discarded, the rerun finishes
#   usage       `--jobs 0`, `--jobs x`, `--jobs` alone: exit 2, nothing written
#   backoff     the agent waits and retries on HTTP 429 and 529 (bounded, the same delays every time), says so, and a wait is not an attempt
#
# Needs the real cancho as CANCHO and python3 (the journal reader; the HTTP stub). Exit 0 every case held.
set -u

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "no python3 on PATH" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
SRC="${PROJECT_SRC:-$root/src}"   # a directory to take src/ from: how the mutation runs judge a broken copy
d=$(mktemp -d -t cc-parallel-XXXXXX)
exe="$d/project"
"$CANCHO" build "$root/tests/programs/project.cho" "$SRC/project.cho" "$SRC/plan.cho" "$SRC/driver.cho" \
    "$SRC/checker.cho" "$SRC/signature.cho" "$SRC/loop_check.cho" "$SRC/snapshot.cho" "$SRC/trail.cho" \
    "$SRC/acceptance.cho" "$SRC/splice.cho" "$SRC/pool.cho" "$SRC/parallel.cho" --std --backend cranelift -o "$exe" >/dev/null 2>"$d/build.err" \
    || { cat "$d/build.err" >&2; echo "gate did not build" >&2; exit 2; }

fail=0
expect() { [ "$2" = "$3" ] || { echo "FAIL: $1: wanted '$3', got '$2'" >&2; fail=1; }; }
ok() { # name command...
    n=$1; shift
    "$@" || { echo "FAIL: $n" >&2; fail=1; }
}
T="$root/tests/parallel"
J="python3 $T/jlook.py"
units() { printf '%s\n' "$1" | grep '^\[UNIT\]' | cut -f2,3 | tr '\t' ':' | tr '\n' ' ' | sed 's/ $//'; }
verdict() { printf '%s\n' "$1" | grep '^\[PROJECT_VERDICT\]' | cut -f2; }
order() { tr '\n' ' ' < "$1" | sed 's/ $//'; }

# a fresh work directory and recipe directory; "<workdir> <recipes> <log>"
mk() {
    wd=$(mktemp -d -t cc-parallel-wd-XXXXXX); rc=$(mktemp -d -t cc-parallel-rc-XXXXXX); lg="$wd/agent.log"; : > "$lg"
    echo "$wd $rc $lg"
}
# the driver: plan wd recipes log jobs [more options...]
runp() {
    p=$1; w=$2; r=$3; l=$4; j=$5; shift 5
    "$exe" "$CANCHO" "$p" "$w" "sh $T/agent.sh $r $l" 4 60 --jobs "$j" "$@" 2>&1
}
# a recipe: sleep $3, say the first call returned (meta.json), sleep $4, append the code $5
rec() { # file pre post code
    cat > "$1" <<EOF
sleep $2
mkdir -p "\$1.call"; echo '{"samples":1}' > "\$1.call/meta.json"
sleep $3
printf '\n%s\n' '$4' >> "\$1"
EOF
}
# the same, never saying anything about a first call
rec_quiet() { # file post code
    cat > "$1" <<EOF
sleep $2
printf '\n%s\n' '$3' >> "\$1"
EOF
}
F_A='fn double(x: int) -> [] int { return x * 2; }'
F_B='fn is_big(x: int) -> [] bool { return x > 10; }'
F_C='fn triple(x: int) -> [] int { return x * 3; }'
F_D='fn total(x: int) -> [] int { return double(x) + triple(x); }'

# ---- pool: several children at once -------------------------------------------------------------------------------------------------
"$CANCHO" build "$root/tests/programs/pool_gate.cho" "$SRC/pool.cho" --std --backend cranelift -o "$d/pool" >/dev/null 2>"$d/pool.err" || { cat "$d/pool.err" >&2; echo "pool gate did not build" >&2; exit 2; }
out=$("$d/pool" 2>&1); r=$?
expect "pool: exit code" "$r" 0
expect "pool: all seven are live right after the starts" "$(printf '%s\n' "$out" | grep '^live')" "live 7"
expect "pool: the four sleepers each said their line (9 bytes) and exited 0" "$(printf '%s\n' "$out" | grep -c '^ended 1[0-3] code 0 bytes 9 ')" 4
expect "pool: exit 7" "$(printf '%s\n' "$out" | grep -c '^ended 14 code 7 bytes 0 ')" 1
expect "pool: output over the cap is kept up to the cap" "$(printf '%s\n' "$out" | grep -c '^ended 15 code 0 bytes 65536 ')" 1
expect "pool: close killed the sleeper that was still running" "$(printf '%s\n' "$out" | grep -c '^closed 1 in ')" 1
wall=$(printf '%s\n' "$out" | sed -n 's/^wall //p')
[ "$wall" -lt 3000 ] 2>/dev/null || { echo "FAIL: pool: four one-second children took ${wall} ms together (not at once)" >&2; fail=1; }

# ---- merge: what a unit built beside the file, put into the file ---------------------------------------------------------------------
"$CANCHO" build "$root/tests/programs/merge_gate.cho" "$SRC/splice.cho" --std --backend cranelift -o "$d/merge" >/dev/null 2>"$d/merge.err" || { cat "$d/merge.err" >&2; echo "merge gate did not build" >&2; exit 2; }
printf 'edition 7;\nimport std.option;\n\nfn a() -> [] int { return 1; }\n' > "$d/base.cho"
printf 'edition 7;\nimport std.option;\n\nfn a() -> [] int { return 1; }\n\nfn c() -> [] int { return 3; }\n' > "$d/ours.cho"
printf 'edition 7;\nimport std.option;\nimport std.buffer;\n\nfn a() -> [] int { return 1; }\n\nfn b() -> [] int { return 2; }\n' > "$d/theirs.cho"
"$d/merge" "$d/base.cho" "$d/ours.cho" "$d/theirs.cho" > "$d/merged.cho" 2>"$d/merged.err"; r=$?
expect "merge: a clean merge: exit code" "$r" 0
printf 'edition 7;\nimport std.option;\nimport std.buffer;\n\nfn a() -> [] int { return 1; }\n\nfn c() -> [] int { return 3; }\n\nfn b() -> [] int { return 2; }\n' > "$d/want.cho"
expect "merge: the unit's new import and function are added after the others' work" "$(cat "$d/merged.cho")" "$(cat "$d/want.cho")"
printf 'edition 7;\nimport std.option;\n\nfn a() -> [] int { return 1; }\n\nfn b() -> [] int { return 9; }\n' > "$d/ours2.cho"
"$d/merge" "$d/base.cho" "$d/ours2.cho" "$d/theirs.cho" > "$d/merged2.cho" 2>"$d/merged2.err"; r=$?
expect "merge: the same name with another body: exit code" "$r" 1
expect "merge: the clash is named" "$(cut -f1,2 "$d/merged2.err")" "$(printf '[INTEGRATE_CLASH]\tfn b')"
expect "merge: a clash leaves the file as it was" "$(cat "$d/merged2.cho")" "$(cat "$d/ours2.cho")"
printf 'edition 7;\nimport std.option;\n\nfn a() -> [] int { return 1; }\n\nfn b() -> [] int { return 2; }\n' > "$d/ours3.cho"
"$d/merge" "$d/base.cho" "$d/ours3.cho" "$d/theirs.cho" > "$d/merged3.cho" 2>/dev/null; r=$?
expect "merge: the same text twice is not a clash: exit code" "$r" 0
expect "merge: ... and is not added twice" "$(grep -c 'fn b' "$d/merged3.cho")" 1
printf 'edition 7;\nimport std.option;\n\nfn a() -> [] int { return 5; }\n' > "$d/theirs4.cho"
printf 'edition 7;\nimport std.option;\n\nfn z() -> [] int { return 0; }\n\nfn a() -> [] int { return 1; }\n' > "$d/ours4.cho"
"$d/merge" "$d/base.cho" "$d/ours4.cho" "$d/theirs4.cho" > "$d/merged4.cho" 2>/dev/null; r=$?
expect "merge: an item the unit rewrote and nobody else touched is replaced in place: exit code" "$r" 0
expect "merge: ... where it was" "$(cat "$d/merged4.cho")" "$(printf 'edition 7;\nimport std.option;\n\nfn z() -> [] int { return 0; }\n\nfn a() -> [] int { return 5; }')"

# ---- overlap: independent units overlap, a dependent waits, lanes ------------------------------------------------------------------------
set -- $(mk); wd=$1; rc=$2; lg=$3
rec "$rc/a.sh" 0.3 1.5 "$F_A"; rec "$rc/b.sh" 0.3 1.5 "$F_B"; rec "$rc/c.sh" 0.3 1.5 "$F_C"; rec "$rc/d.sh" 0.1 0.1 "$F_D"
out=$(runp "$T/plan-wide.json" "$wd" "$rc" "$lg" 4); r=$?
expect "overlap: exit code" "$r" 0
expect "overlap: verdict" "$(verdict "$out")" done
expect "overlap: the state names all four in plan order" "$(order "$wd/state.txt")" "verified a verified b verified c verified d"
expect "overlap: every function is in project.cho once" "$(grep -c '^fn ' "$wd/project.cho")" 4
mc=$($J "$wd" maxconc)
[ "$mc" -ge 3 ] || { echo "FAIL: overlap: at most $mc units were in flight together (wanted the three independent ones)" >&2; fail=1; }
set -- $($J "$wd" sumspans); sum=$1; wall=$2
[ $((wall + 1000)) -lt "$sum" ] || { echo "FAIL: overlap: the wall time of the units ($wall ms) is not under the sum of their durations ($sum ms) by a second" >&2; fail=1; }
for u in a b c; do ok "overlap: d started before $u ended" $J "$wd" before "$u" d; done
expect "overlap: d was asked once, last" "$(order "$lg" | tr ' ' '\n' | tail -1)" d
ln=$($J "$wd" lanes)
case "$ln" in *a=0*) ;; *) echo "FAIL: overlap: unit a has no lane 0 ($ln)" >&2; fail=1 ;; esac
expect "overlap: the three that ran together have three different lanes" "$(printf '%s\n' "$ln" | tr ' ' '\n' | grep -E '^(a|b|c)=' | cut -d= -f2 | sort -u | wc -l | tr -d ' ')" 3
ok "overlap: the journal's lines are whole and never go back in time" $J "$wd" whole
expect "overlap: every attempt has its diff (a unit's first one against the file it started from)" "$(grep '"kind":"attempt"' "$wd/journal/events.jsonl" | grep -c '"diff":')" 4
expect "overlap: units that only added to the file did not make the others run again (no sweep)" "$(grep -c '"kind":"sweep"' "$wd/journal/events.jsonl")" 0
expect "overlap: a unit_end carries ms and lane" "$(grep '"kind":"unit_end"' "$wd/journal/events.jsonl" | grep -c '"ms":[0-9]*,"lane":\|"lane":[0-9]*,"ms":\|"lane":' )" 4
rm -rf "$wd" "$rc"

# ---- jobs: the limit --------------------------------------------------------------------------------------------------------------------
set -- $(mk); wd=$1; rc=$2; lg=$3
rec "$rc/a.sh" 0.3 1.5 "$F_A"; rec "$rc/b.sh" 0.3 1.5 "$F_B"; rec "$rc/c.sh" 0.3 1.5 "$F_C"; rec "$rc/d.sh" 0.1 0.1 "$F_D"
out=$(runp "$T/plan-wide.json" "$wd" "$rc" "$lg" 2); r=$?
expect "jobs 2: exit code" "$r" 0
expect "jobs 2: never more than two in flight" "$($J "$wd" maxconc)" 2
rm -rf "$wd" "$rc"

# ---- bare name, empty environment: --jobs finds its own path (cancho-code#92: Forge's adapter starts the tool by name, with no PATH) -------------
if command -v bash >/dev/null 2>&1 && [ -d /proc/self ]; then
    set -- $(mk); wd=$1; rc=$2; lg=$3
    rec "$rc/a.sh" 0.1 0.1 "$F_A"; rec "$rc/b.sh" 0.1 0.1 "$F_B"; rec "$rc/c.sh" 0.1 0.1 "$F_C"; rec "$rc/d.sh" 0.1 0.1 "$F_D"
    out=$(cd "$d" && env -i bash -c 'exec -a project ./project "$@"' x "$CANCHO" "$T/plan-wide.json" "$wd" "sh $T/agent.sh $rc $lg" 4 60 --jobs 2 2>&1); r=$?
    [ "$r" = 0 ] || printf "%s\n" "$out" | tail -8 >&2
    expect "bare name, no PATH: exit code" "$r" 0
    expect "bare name, no PATH: verdict" "$(verdict "$out")" done
    expect "bare name, no PATH: the driver did not say it cannot tell where it is" "$(printf '%s\n' "$out" | grep -c 'cannot tell where it is')" 0
    rm -rf "$wd" "$rc"
fi

# ---- jobs 1 is the sequential driver ----------------------------------------------------------------------------------------------------
set -- $(mk); wd=$1; rc=$2; lg=$3
rec_quiet "$rc/a.sh" 0 "$F_A"; rec_quiet "$rc/b.sh" 0 "$F_B"; rec_quiet "$rc/c.sh" 0 "$F_C"; rec_quiet "$rc/d.sh" 0 "$F_D"
out1=$("$exe" "$CANCHO" "$T/plan-wide.json" "$wd" "sh $T/agent.sh $rc $lg" 4 60 2>&1); r1=$?
wd2=$(mktemp -d -t cc-parallel-wd-XXXXXX); lg2="$wd2/agent.log"; : > "$lg2"
out2=$(runp "$T/plan-wide.json" "$wd2" "$rc" "$lg2" 1); r2=$?
expect "jobs 1: exit code" "$r2" "$r1"
expect "jobs 1: console output byte for byte" "$(printf '%s\n' "$out2" | sed "s|$wd2|WD|g")" "$(printf '%s\n' "$out1" | sed "s|$wd|WD|g")"
expect "jobs 1: project.cho byte for byte" "$(cat "$wd2/project.cho")" "$(cat "$wd/project.cho")"
expect "jobs 1: state.txt byte for byte" "$(cat "$wd2/state.txt")" "$(cat "$wd/state.txt")"
expect "jobs 1: agent order" "$(order "$lg2")" "$(order "$lg")"
expect "jobs 1: the journal's events, in order" "$($J "$wd2" kinds)" "$($J "$wd" kinds)"
expect "jobs 1: no scratch workspace" "$([ -d "$wd2/units" ] && echo yes || echo no)" no
expect "jobs 1: no lane in the journal" "$(grep -c '"lane"' "$wd2/journal/events.jsonl")" 0
rm -rf "$wd" "$wd2" "$rc"

# ---- cold start: one unit first -----------------------------------------------------------------------------------------------------------
set -- $(mk); wd=$1; rc=$2; lg=$3
rec "$rc/a.sh" 1.2 1.5 "$F_A"; rec "$rc/b.sh" 0.1 0.5 "$F_B"; rec "$rc/c.sh" 0.1 0.5 "$F_C"; rec "$rc/d.sh" 0.1 0.1 "$F_D"
out=$(runp "$T/plan-wide.json" "$wd" "$rc" "$lg" 4); r=$?
expect "cold: exit code" "$r" 0
gab=$($J "$wd" gap a b); gac=$($J "$wd" gap a c)
[ "$gab" -ge 1000 ] && [ "$gac" -ge 1000 ] || { echo "FAIL: cold: b and c started $gab / $gac ms after a (a's first call returned after 1200 ms: wanted at least 1000)" >&2; fail=1; }
ok "cold: ... but before a ended: the others fan out when the first call has returned, not when the unit is done" sh -c "! $J $wd before a b"
rm -rf "$wd" "$rc"
set -- $(mk); wd=$1; rc=$2; lg=$3
rec_quiet "$rc/a.sh" 1.0 "$F_A"; rec "$rc/b.sh" 0.1 0.3 "$F_B"; rec "$rc/c.sh" 0.1 0.3 "$F_C"; rec "$rc/d.sh" 0.1 0.1 "$F_D"
out=$(runp "$T/plan-wide.json" "$wd" "$rc" "$lg" 4); r=$?
expect "cold, a silent agent: exit code" "$r" 0
ok "cold, a silent agent: the others wait for the first unit to end" $J "$wd" before a b
rm -rf "$wd" "$rc"

# ---- clash: the same name defined twice -----------------------------------------------------------------------------------------------------
set -- $(mk); wd=$1; rc=$2; lg=$3
rec "$rc/a.sh" 0.3 0.3 'fn shared(x: int) -> [] int { return x * 2; }
fn dbl1(x: int) -> [] int { return shared(x) + 1; }'
rec "$rc/b.1.sh" 0.3 3.5 'fn shared(x: int) -> [] int { return x * 3; }
fn tri1(x: int) -> [] int { return shared(x) + 1; }'
cat > "$rc/b.2.sh" <<'EOF'
grep -q 'INTEGRATE_CLASH' "$1.task" || exit 9
grep -q 'fn shared' "$1.task" || exit 9
printf '\n%s\n' 'fn tri1(x: int) -> [] int { return shared(x) + x + 1; }' >> "$1"
EOF
rec "$rc/c.sh" 0.1 0.1 'fn both(x: int) -> [] int { return dbl1(x) + tri1(x); }'
out=$(runp "$T/plan-clash.json" "$wd" "$rc" "$lg" 4); r=$?
expect "clash: exit code" "$r" 0
expect "clash: verdict" "$(verdict "$out")" done
expect "clash: b was asked twice, the others once" "$(grep -c '^a$' "$lg") $(grep -c '^b$' "$lg") $(grep -c '^c$' "$lg")" "1 2 1"
expect "clash: the second request for b was told about the clash" "$(grep -c 'INTEGRATE_CLASH' "$rc/seen-b.2.task")" 1
expect "clash: the first request had no note" "$(grep -c '^NOTE' "$rc/seen-b.1.task")" 0
expect "clash: one shared in the file" "$(grep -c 'fn shared' "$wd/project.cho")" 1
expect "clash: the journal's integrations" "$($J "$wd" integrate)" "a:fast:ok b:merge:no b:fast:ok c:fast:ok"
case "$out" in *"$(printf '[INTEGRATE]\tb\trequeued')"*) ;; *) echo "FAIL: clash: no [INTEGRATE] b requeued line" >&2; fail=1 ;; esac
expect "clash: b's attempt after the requeue has a diff against the code of the one before" "$(grep '"kind":"attempt","unit":"b"' "$wd/journal/events.jsonl" | grep -c '"diff":')" 2
expect "clash: the state" "$(order "$wd/state.txt")" "verified a verified b verified c"
expect "clash: b's trail has both builds (the numbers go on)" "$(wc -l < "$wd/trail-b.jsonl" | tr -d ' ')" 2
rm -rf "$wd" "$rc"

# ---- combined: items that merge cleanly and do not compile together ------------------------------------------------------------------
set -- $(mk); wd=$1; rc=$2; lg=$3
cat > "$rc/a.sh" <<'EOF'
sleep 0.3; mkdir -p "$1.call"; echo '{}' > "$1.call/meta.json"
{ head -1 "$1"; printf 'import std.option as m;\n'; tail -n +2 "$1"; } > "$1.new" && mv "$1.new" "$1"
printf '\n%s\n' 'fn a_id(x: int) -> [] int { let o = m.Option::Some(x); match o { m.Option::Some(v) => { return v; } m.Option::None => { return 0; } } }' >> "$1"
EOF
cat > "$rc/b.1.sh" <<'EOF'
sleep 0.3; mkdir -p "$1.call"; echo '{}' > "$1.call/meta.json"; sleep 3
{ head -1 "$1"; printf 'import std.bytes as m;\n'; tail -n +2 "$1"; } > "$1.new" && mv "$1.new" "$1"
printf '\n%s\n' 'fn b_n(x: int) -> [] int { if m.equal("ab", "ab") { return x + 1; } return 0; }' >> "$1"
EOF
cat > "$rc/b.2.sh" <<'EOF'
grep -q 'already bound' "$1.task" || exit 9
{ head -1 "$1"; printf 'import std.bytes as bb;\n'; tail -n +2 "$1"; } > "$1.new" && mv "$1.new" "$1"
printf '\n%s\n' 'fn b_n(x: int) -> [] int { if bb.equal("ab", "ab") { return x + 1; } return 0; }' >> "$1"
EOF
out=$(runp "$T/plan-alias.json" "$wd" "$rc" "$lg" 4); r=$?
expect "combined: exit code" "$r" 0
expect "combined: verdict" "$(verdict "$out")" done
expect "combined: b was asked twice" "$(order "$lg" | tr ' ' '\n' | grep -c '^b$')" 2
expect "combined: the journal's integrations (the merge was refused by the compiler on the combined file)" "$($J "$wd" integrate)" "a:fast:ok b:merge:no b:fast:ok"
expect "combined: both aliases are in the file" "$(grep -c '^import std.\(option as m\|bytes as bb\);' "$wd/project.cho")" 2
rm -rf "$wd" "$rc"

# ---- memory: a unit built beside others gets the agent's --memory and journals what the memory added ---------------------------------------------------
set -- $(mk); wd=$1; rc=$2; lg=$3
mm=$(mktemp -d -t cc-parallel-mem-XXXXXX); echo "no network" > "$mm/facts.txt"
rec "$rc/a.sh" 0.3 0.5 "$F_A"; rec "$rc/b.sh" 0.2 0.5 "$F_C"
out=$("$exe" "$CANCHO" "$T/plan-order.json" "$wd" "sh $T/agent.sh $rc $lg --memory $mm" 4 60 --jobs 2 2>&1); r=$?
expect "memory: exit code" "$r" 0
expect "memory: both units' attempts carry what the memory added" "$(grep '"kind":"attempt"' "$wd/journal/events.jsonl" | grep -c '"memory":\[{"id":"fact-1","text":"no network"}\]')" 2
expect "memory: ... and ran beside each other" "$($J "$wd" maxconc)" 2
rm -rf "$wd" "$rc" "$mm"

# ---- retry and patch with --jobs: only the unit and what needs it; a patch needs no model -------------------------------------------------------------
WRONG_A='sed -i.bak "/^fn double/d" "$1"; printf "\n%s\n" "fn double(x: int) -> [] int { return x + 3; }" >> "$1"'
set -- $(mk); wd=$1; rc=$2; lg=$3
printf '%s\n' "$WRONG_A" > "$rc/a.sh"; rec_quiet "$rc/b.sh" 0.1 "$F_B"
rec_quiet "$rc/c.sh" 0.1 'fn big_double(x: int) -> [] bool { return is_big(double(x)); }'
out=$(runp "$root/tests/project/plan.json" "$wd" "$rc" "$lg" 4); r=$?
expect "retry: the first run is stuck" "$(verdict "$out")" stuck
expect "retry: ... and kept b" "$(order "$wd/state.txt")" "verified b"
cat > "$rc/a.sh" <<'EOF'
grep -q '^HINT: multiply, do not add$' "$1.task" || exit 4
sed -i.bak '/^fn double/d' "$1"; printf '\n%s\n' 'fn double(x: int) -> [] int { return x * 2; }' >> "$1"
EOF
: > "$lg"
out=$(runp "$root/tests/project/plan.json" "$wd" "$rc" "$lg" 4 --retry a --hint "multiply, do not add"); r=$?
expect "retry --jobs 4: exit code" "$r" 0
expect "retry --jobs 4: only a and c were asked (b is kept)" "$(order "$lg")" "a c"
expect "retry --jobs 4: unit lines" "$(units "$out")" "b:kept a:building a:verified c:building c:verified"
expect "retry --jobs 4: the unit's trail goes on from its earlier attempts" "$(wc -l < "$wd/trail-a.jsonl" | tr -d ' ')" 3
expect "retry --jobs 4: the journal marks the retry" "$(grep '"kind":"unit_start","unit":"a"' "$wd/journal/events.jsonl" | grep -c '"retry":true')" 1
rm -rf "$wd" "$rc"
set -- $(mk); wd=$1; rc=$2; lg=$3
printf '%s\n' "$WRONG_A" > "$rc/a.sh"; rec_quiet "$rc/b.sh" 0.1 "$F_B"
rec_quiet "$rc/c.sh" 0.1 'fn big_double(x: int) -> [] bool { return is_big(double(x)); }'
out=$(runp "$root/tests/project/plan.json" "$wd" "$rc" "$lg" 4); : > "$lg"
printf '%s\n' "$F_A" > "$wd/a-fix.cho"
out=$(runp "$root/tests/project/plan.json" "$wd" "$rc" "$lg" 4 --patch a "$wd/a-fix.cho"); r=$?
expect "patch --jobs 4: exit code" "$r" 0
expect "patch --jobs 4: no model call for a: only c was asked" "$(order "$lg")" "c"
expect "patch --jobs 4: the state" "$(order "$wd/state.txt")" "verified a verified b verified c"
expect "patch --jobs 4: the journal records the human patch" "$(grep -c '"outcome":"human_patch"' "$wd/journal/events.jsonl")" 1
rm -rf "$wd" "$rc"

# ---- rewrite: a unit that changes what was there makes the units that had verified run again --------------------------------------------------
set -- $(mk); wd=$1; rc=$2; lg=$3
rec_quiet "$rc/a.sh" 0.1 "$F_A"; rec_quiet "$rc/b.sh" 0.1 "$F_B"
cat > "$rc/c.sh" <<'EOF'
sed -i.bak '/^fn double/d' "$1"
printf '\n%s\n' 'fn double(x: int) -> [] int { if x == 0 { return 1; } return x * 2; }' >> "$1"
printf '\n%s\n' 'fn big_double(x: int) -> [] bool { return is_big(double(x)); }' >> "$1"
EOF
cat > "$rc/a.2.sh" <<'EOF'
sed -i.bak '/^fn double/d' "$1"
printf '\n%s\n' 'fn double(x: int) -> [] int { return x * 2; }' >> "$1"
EOF
out=$(runp "$root/tests/project/plan.json" "$wd" "$rc" "$lg" 4); r=$?
expect "rewrite: exit code" "$r" 0
case "$(units "$out")" in *"c:verified a:regressed"*) ;; *) echo "FAIL: rewrite: no 'a:regressed' right after c verified: $(units "$out")" >&2; fail=1 ;; esac
expect "rewrite: a was asked twice (its tests failed on the file c rewrote)" "$(grep -c '^a$' "$lg")" 2
rm -rf "$wd" "$rc"

# ---- order: units that end together are integrated in plan order ---------------------------------------------------------------------------
set -- $(mk); wd=$1; rc=$2; lg=$3
rec "$rc/a.sh" 0.3 2.5 "$F_A"; rec "$rc/b.sh" 0.3 0.2 "$F_C"
out=$(runp "$T/plan-order.json" "$wd" "$rc" "$lg" 4 --settle 6000); r=$?
expect "order: exit code" "$r" 0
expect "order: b ended first, a was integrated first (plan order)" "$($J "$wd" integrate)" "a:fast:ok b:merge:ok"
expect "order: project.cho has a's function before b's" "$(grep '^fn ' "$wd/project.cho" | cut -d'(' -f1 | tr '\n' ' ')" "fn double fn triple "
rm -rf "$wd" "$rc"

# ---- isolation: one unit's agent fails ---------------------------------------------------------------------------------------------------------
set -- $(mk); wd=$1; rc=$2; lg=$3
rec "$rc/a.sh" 0.3 1.0 "$F_A"; rec "$rc/b.sh" 0.2 2.0 "$F_C"
echo 'exit 3' > "$rc/x.sh"
rec "$rc/c.sh" 0.1 0.1 'fn nine(x: int) -> [] int { return x * 9; }'
out=$(runp "$T/plan-isolate.json" "$wd" "$rc" "$lg" 4); r=$?
expect "isolation: exit code (4: the agent is away)" "$r" 4
expect "isolation: verdict" "$(verdict "$out")" provider_error
expect "isolation: the units that were running finished and are kept" "$(order "$wd/state.txt")" "verified a verified b"
case "$(units "$out")" in *"x:unavailable"*) ;; *) echo "FAIL: isolation: x is not named unavailable: $(units "$out")" >&2; fail=1 ;; esac
expect "isolation: nothing new was started after the failure (c never asked)" "$(grep -c '^c$' "$lg")" 0
rec "$rc/x.sh" 0.1 0.1 "$F_B"
out=$(runp "$T/plan-isolate.json" "$wd" "$rc" "$lg" 4); r=$?
expect "isolation: the rerun: exit code" "$r" 0
expect "isolation: the rerun keeps a and b and builds x, then c" "$(units "$out" | tr ' ' '\n' | grep -c 'building')" 2
expect "isolation: the rerun asked a and b nothing" "$(order "$lg" | tr ' ' '\n' | grep -c '^[ab]$')" 2
rm -rf "$wd" "$rc"

# ---- stuck: a unit that is never right blocks only its dependent -----------------------------------------------------------------------------
set -- $(mk); wd=$1; rc=$2; lg=$3
rec "$rc/a.sh" 0.3 0.5 "$F_A"; rec "$rc/b.sh" 0.2 0.5 "$F_C"
cat > "$rc/x.sh" <<'EOF'
sleep 0.1
sed -i.bak '/fn is_big/d' "$1"
printf '\n%s\n' 'fn is_big(x: int) -> [] bool { return x > 100; }' >> "$1"
EOF
out=$(runp "$T/plan-isolate.json" "$wd" "$rc" "$lg" 4); r=$?
expect "stuck: exit code" "$r" 1
expect "stuck: verdict" "$(verdict "$out")" stuck
expect "stuck: the state has the independent units only" "$(order "$wd/state.txt")" "verified a verified b"
case "$(units "$out")" in *"x:failed"*"c:skipped"*) ;; *) echo "FAIL: stuck: x failed / c skipped not in order: $(units "$out")" >&2; fail=1 ;; esac
expect "stuck: x's two attempts were made" "$(grep -c '^x$' "$lg")" 2
expect "stuck: its trail was kept" "$(wc -l < "$wd/trail-x.jsonl" | tr -d ' ')" 2
rm -rf "$wd" "$rc"

# ---- no leak: the project file has none of an unfinished unit's work ---------------------------------------------------------------------
set -- $(mk); wd=$1; rc=$2; lg=$3
cat > "$rc/a.sh" <<'EOF'
sleep 0.3; mkdir -p "$1.call"; echo '{}' > "$1.call/meta.json"
printf '\n%s\n' 'fn double(x: int) -> [] int { return x * 2; }' >> "$1"
main=$(dirname "$1")/../../project.cho
sleep 0.5
if grep -q 'fn double' "$main"; then echo LEAK >> "$(dirname "$1")/../../leak.txt"; fi
if [ "$(dirname "$1")" = "$(dirname "$main")" ]; then echo SAMEFILE >> "$(dirname "$1")/../../leak.txt"; fi
EOF
rec "$rc/b.sh" 0.1 0.2 "$F_B"
out=$(runp "$T/plan-order.json" "$wd" "$rc" "$lg" 4); r=$?
expect "no leak: a ran in a workspace of its own" "$([ -d "$wd/units" ] && echo yes || echo gone)" "$([ -d "$wd/units" ] && echo yes || echo gone)"
[ -f "$wd/leak.txt" ] && { echo "FAIL: no leak: a unit's work was in the project file while it was in flight ($(cat "$wd/leak.txt"))" >&2; fail=1; }
rm -rf "$wd" "$rc"

# ---- kill: kill -9 of the driver with units in flight ----------------------------------------------------------------------------------------
set -- $(mk); wd=$1; rc=$2; lg=$3
rec "$rc/a.sh" 0.2 0.3 "$F_A"; rec "$rc/b.sh" 0.2 20 "$F_B"; rec "$rc/c.sh" 0.2 20 "$F_C"; rec "$rc/d.sh" 0.1 0.1 "$F_D"
"$exe" "$CANCHO" "$T/plan-wide.json" "$wd" "sh $T/agent.sh $rc $lg" 4 60 --jobs 4 > "$wd/first.out" 2>&1 &
pid=$!
n=0; while [ $n -lt 150 ]; do grep -q 'verified a' "$wd/state.txt" 2>/dev/null && grep -q '^b$' "$lg" && grep -q '^c$' "$lg" && break; sleep 0.2; n=$((n + 1)); done
kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null
expect "kill: a was kept in the state" "$(order "$wd/state.txt")" "verified a"
expect "kill: the scratch workspace of a unit that was running is there" "$([ -d "$wd/units/b" ] && echo yes || echo no)" yes
ok "kill: the journal is whole lines" $J "$wd" whole
rec "$rc/b.sh" 0.1 0.1 "$F_B"; rec "$rc/c.sh" 0.1 0.1 "$F_C"
out=$(runp "$T/plan-wide.json" "$wd" "$rc" "$lg" 4); r=$?
expect "kill: the rerun: exit code" "$r" 0
expect "kill: the rerun: verdict" "$(verdict "$out")" done
expect "kill: the rerun kept a (it was not asked again)" "$(order "$lg" | tr ' ' '\n' | grep -c '^a$')" 1
expect "kill: the state" "$(order "$wd/state.txt")" "verified a verified b verified c verified d"
expect "kill: nothing of the first run is left running" "$(pgrep -f "$wd/[u]nits/" | wc -l | tr -d ' ')" 0
ok "kill: the journal is whole lines after the rerun" $J "$wd" whole
rm -rf "$wd" "$rc"

# ---- usage -----------------------------------------------------------------------------------------------------------------------------------
set -- $(mk); wd=$1; rc=$2; lg=$3
for bad in "--jobs 0" "--jobs x" "--jobs" "--jobs -1" "--jobs 65"; do
    out=$("$exe" "$CANCHO" "$T/plan-wide.json" "$wd" "sh $T/agent.sh $rc $lg" 4 60 $bad 2>&1); r=$?
    expect "usage: '$bad': exit code" "$r" 2
done
expect "usage: nothing was asked of the agent" "$(wc -c < "$lg" | tr -d ' ')" 0
rm -rf "$wd" "$rc"

# ---- build: the plan stage has warmed the cache, so nothing waits for a first call; --jobs is 4 unless said ----------------------------------------
bexe="$d/build"
"$CANCHO" build "$root/tests/programs/build.cho" "$SRC/build.cho" "$SRC/project.cho" "$SRC/plan.cho" "$SRC/driver.cho" \
    "$SRC/checker.cho" "$SRC/signature.cho" "$SRC/loop_check.cho" "$SRC/snapshot.cho" "$SRC/trail.cho" \
    "$SRC/acceptance.cho" "$SRC/splice.cho" "$SRC/pool.cho" "$SRC/parallel.cho" "$SRC/library.cho" "$SRC/cases.cho" --std --backend cranelift -o "$bexe" >/dev/null 2>"$d/bbuild.err" \
    || { cat "$d/bbuild.err" >&2; echo "build gate did not build" >&2; exit 2; }
B="$root/tests/buildcmd"
runb() { # wd recipes log [more options...]
    w=$1; r=$2; l=$3; shift 3
    "$bexe" "$CANCHO" "$B/brief.txt" "$w" "sh $B/agent.sh $r $l" --provider stand --model m1 --guide "$B/guide.txt" --attempts 4 --agent-seconds 60 "$@" 2>&1
}
mkb() {
    wd=$(mktemp -d -t cc-parallel-bwd-XXXXXX); rc=$(mktemp -d -t cc-parallel-brc-XXXXXX); lg="$rc/agent.log"; : > "$lg"
    printf 'cp "%s" "$1"\n' "$root/tests/project/plan.json" > "$rc/plan.sh"
    rec_quiet "$rc/a.sh" 1.5 "$F_A"; rec_quiet "$rc/b.sh" 1.5 "$F_B"
    rec_quiet "$rc/c.sh" 0.1 'fn big_double(x: int) -> [] bool { return is_big(double(x)); }'
    echo "$wd $rc $lg"
}
set -- $(mkb); wd=$1; rc=$2; lg=$3
out=$(runb "$wd" "$rc" "$lg"); r=$?
expect "build: exit code" "$r" 0
expect "build: verdict" "$(printf '%s\n' "$out" | grep '^\[BUILD_VERDICT\]' | cut -f2)" done
expect "build: a and b started together (the plan call had warmed the cache; neither agent says anything about a first call)" "$([ "$($J "$wd" gap a b)" -lt 900 ] && echo together || echo apart)" together
expect "build: two units in flight" "$($J "$wd" maxconc)" 2
expect "build: run.log is whole lines" "$(grep -vc '^\[' "$wd/run.log")" 0
expect "build: run.log says each unit building once and verified once" "$(grep '^\[UNIT\]' "$wd/run.log" | cut -f2,3 | sort | tr '\t\n' ': ' )" "a:building a:verified b:building b:verified c:building c:verified "
expect "build: the state" "$(order "$wd/state.txt")" "verified a verified b verified c"
rm -rf "$wd" "$rc"
set -- $(mkb); wd=$1; rc=$2; lg=$3
out=$(runb "$wd" "$rc" "$lg" --jobs 1); r=$?
expect "build --jobs 1: exit code" "$r" 0
expect "build --jobs 1: one at a time" "$($J "$wd" maxconc)" 1
rm -rf "$wd" "$rc"
set -- $(mkb); wd=$1; rc=$2; lg=$3
out=$(runb "$wd" "$rc" "$lg" --jobs 0); r=$?
expect "build --jobs 0: exit code" "$r" 2
expect "build --jobs 0: nothing was asked of the agent" "$(wc -c < "$lg" | tr -d ' ')" 0
rm -rf "$wd" "$rc"

# ---- backoff: 429 and 529 are waited out ------------------------------------------------------------------------------------------------------
C="${CANCHO_PACKAGES:-}"
[ -d "$C" ] || C="$(dirname "$(dirname "$(dirname "$(command -v "$CANCHO")")")")/packages"
[ -d "$C" ] || { echo "no cancho packages found; set CANCHO_PACKAGES" >&2; exit 2; }
aexe="$d/agent"
"$CANCHO" build "$root/src/cancho_agent.cho" "$SRC/anthropic.cho" "$SRC/ollama.cho" "$SRC/prompt.cho" "$SRC/planprompt.cho" "$SRC/plan.cho" "$SRC/cases.cho" "$SRC/review.cho" "$SRC/splice.cho" "$SRC/provider.cho" "$SRC/reply.cho" "$SRC/calls.cho" "$SRC/memory.cho" "$SRC/signature.cho" \
    "$root/vendor/fetch_io.cho" "$C"/http-client/*.cho "$C"/tls/*.cho "$C"/x509/*.cho --std --backend cranelift -o "$aexe" >/dev/null 2>"$d/abuild.err" \
    || { cat "$d/abuild.err" >&2; echo "agent did not build" >&2; exit 2; }
cat > "$d/stub.py" <<'PY'
import http.server, json, sys
out = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        try:
            n = int(open(out + "/requests").read()) + 1       # a case removes the file to start counting again
        except (OSError, ValueError):
            n = 1
        open(out + "/requests", "w").write(str(n))
        try:
            status = int(open(out + "/status.%d" % n).read())     # a case says what the n-th request is answered with
        except OSError:
            try:
                status = int(open(out + "/status").read())        # or what every request is answered with
            except OSError:
                status = 200
        if status == 200:
            data = json.dumps({"response": "```cancho\nedition 7;\nfn fixed() -> [] int { return 1; }\n```\n", "eval_count": 7, "done_reason": "stop"}).encode()
        else:
            data = json.dumps({"error": "stub says %d" % status}).encode()
        self.send_response(status); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(out + "/port", "w").write(str(s.server_address[1]))
s.serve_forever()
PY
bk() { # case-dir backoff-ms: the agent against the stub, no environment
    env -i CANCHO_AGENT_BIN="$aexe" /bin/sh "$root/scripts/cancho-agent.sh" --provider ollama --model stub-model:1b --port "$port" --backoff-ms "$2" --usage-log "$1/usage.jsonl" "$1/project.cho" 2>"$1/err" >/dev/null
}
fresh_case() {
    c=$(mktemp -d -t cc-parallel-bk-XXXXXX); printf 'edition 7;\nfn broken() -> [] int { return true; }\n' > "$c/project.cho"; echo "$c"
}
sd="$d/stub"; mkdir -p "$sd"
python3 "$d/stub.py" "$sd" & stub=$!
n=0; while [ ! -s "$sd/port" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
port=$(cat "$sd/port")
# two 429s, then the answer: the file is the answer, two waits (10 then 20 ms), each said and logged, three requests
c=$(fresh_case); rm -f "$sd"/status* "$sd/requests"; echo 429 > "$sd/status.1"; echo 429 > "$sd/status.2"
bk "$c" 10; r=$?
expect "backoff: exit code after two 429s" "$r" 0
expect "backoff: the file is the model's answer" "$(grep -c 'fn fixed' "$c/project.cho")" 1
expect "backoff: three requests (two refused, one answered)" "$(cat "$sd/requests")" 3
expect "backoff: the waits are said, with the same pauses every time" "$(sed -n 's/.*answered \([0-9]*\) (busy); waiting \([0-9]*\) ms before try \([0-9]*\)$/\1:\2:\3/p' "$c/err" | tr '\n' ' ')" "429:10:2 429:20:3 "
expect "backoff: the usage log has one rate_limited row per wait" "$(grep -c '"outcome":"rate_limited"' "$c/usage.jsonl")" 2
expect "backoff: ... with the pause in ms and the status" "$(sed -n 's/.*"status":\([0-9]*\).*"ms":\([0-9]*\)}.*/\1:\2/p' "$c/usage.jsonl" | head -2 | tr '\n' ' ')" "429:10 429:20 "
rm -rf "$c"
# 529 (overloaded) is waited out too
c=$(fresh_case); rm -f "$sd"/status* "$sd/requests"; echo 529 > "$sd/status.1"
bk "$c" 10; r=$?
expect "backoff: exit code after a 529" "$r" 0
expect "backoff: two requests" "$(cat "$sd/requests")" 2
rm -rf "$c"
# always 429: six waits (10 20 40 80 160 320), then the agent gives up as it always has: exit 1, the file as it was, seven requests
c=$(fresh_case); rm -f "$sd"/status* "$sd/requests"; echo 429 > "$sd/status"
bk "$c" 10; r=$?
expect "backoff: exit code when the API never stops saying 429" "$r" 1
expect "backoff: the file is as it was" "$(grep -c 'fn broken' "$c/project.cho")" 1
expect "backoff: seven requests: the first and six retries" "$(cat "$sd/requests")" 7
expect "backoff: the pauses double, up to six" "$(sed -n 's/.*waiting \([0-9]*\) ms.*/\1/p' "$c/err" | tr '\n' ' ')" "10 20 40 80 160 320 "
expect "backoff: ... and then it says the error" "$(grep -c 'HTTP error from the API' "$c/err")" 1
rm -rf "$c"
# any other error is not waited out
c=$(fresh_case); rm -f "$sd"/status* "$sd/requests"; echo 400 > "$sd/status"
bk "$c" 10; r=$?
expect "backoff: a 400 is not retried: exit code" "$r" 1
expect "backoff: ... one request" "$(cat "$sd/requests")" 1
expect "backoff: ... no wait" "$(grep -c 'waiting' "$c/err")" 0
rm -rf "$c"
kill $stub 2>/dev/null; wait $stub 2>/dev/null

rm -rf "$d"
[ "$fail" = 0 ] && echo "parallel gate: ok"
exit $fail
