#!/bin/sh
# The profile gate (docs/profile.md): `build --profile <file>` against the stand-in agent of the build gate (tests/buildcmd/agent.sh). No model, no
# network, no key. The checker is the real compiler.
#
#   key         `signature.of_key` reads a finding's rule under the key it is given; `of` is `of_key` with "rule" (tests/signature_key_test.cho)
#   refusals    every malformed profile in tests/profile/bad-<tag>*.json: exit 2, a `[PROFILE_ERROR]<TAB><tag>` line, nothing run, nothing written
#   default     tests/profile/cancho.json states the default: the run is the run without --profile (the same files, the same lines, the same
#               agent arguments), and --jobs above 1 is allowed (it IS the default)
#   renamed     tests/profile/renamed.json: the same compiler behind a wrapper that reports findings under `code`, files app.cn, entry.cn,
#               t-<id>.cn: done, and no project.cho, main.cho or tests-*.cho in the work directory
#   key in use  under `renamed`, a unit whose first attempt is refused is fed the refusal, retried on its `code` signature, and verifies;
#               the same profile with `findings.key: "rule"` cannot read the wrapper's refusals: provider_error, exit 4 (the mutant)
#   primer      a profile's primer reaches the plan agent and the unit agent as --primer <file>; with "" neither gets one
#   combos      a profile other than the default with --jobs 2 (`profile-jobs`) or --patch (`profile-patch`): exit 2; a plan with `files`
#               under it is refused by the plan judgement (`profile-files`): plan_failed, exit 3
#   cancho-ui   tests/profile/cancho-ui.json (units "components", unit_tests "trace", no main file) with the checker a stand-in cancho-ui
#               (tests/profile/ui/standin.sh behind tests/profile/ui/clean-wrap.sh): a 2-component plan (tests/profile/ui/plan.json) is done; the
#               entry starts empty, no main is written or compiled (the stand-in refuses a second file), each unit's tests file is its trace; the task names the component, the
#               entry and the profile, never project.cho; a refused first attempt is retried on its `code`, a trace that fails is retried;
#               the component plan check's refusals (tests/profile/ui/bad-*.json, unit-field.json), a function plan under the profile and a
#               component plan under the default are plan_failed, exit 3. With CANCHO_UI=<cancho-ui binary> the same plan is built once more
#               against the real cancho-ui (behind the same clean-wrap.sh); without it that case is skipped and says so.
#   language    the native agent's prompt names the profile's language from the task's LANGUAGE line (tests/prompt_language_test.cho)
#
# Needs the real cancho as CANCHO. Exit 0: every case held.
set -u

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
SRC="${BUILD_SRC:-$root/src}"
tmp=$(mktemp -d -t cc-profile-XXXXXX)
exe="$tmp/cancho-build"
"$CANCHO" build "$root/tests/programs/build.cho" "$SRC/build.cho" "$SRC/project.cho" "$SRC/plan.cho" "$SRC/driver.cho" \
    "$SRC/checker.cho" "$SRC/signature.cho" "$SRC/loop_check.cho" "$SRC/snapshot.cho" "$SRC/trail.cho" \
    "$SRC/acceptance.cho" "$SRC/splice.cho" "$SRC/pool.cho" "$SRC/parallel.cho" "$SRC/library.cho" "$SRC/cases.cho" --std --backend cranelift -o "$exe" || { echo "gate did not build" >&2; exit 2; }

fail=0
expect() { [ "$2" = "$3" ] || { echo "FAIL: $1: wanted '$3', got '$2'" >&2; fail=1; }; }
B="$root/tests/buildcmd"
P="$root/tests/project"
T="$root/tests/profile"
verdict() { printf '%s\n' "$1" | grep '^\[BUILD_VERDICT\]' | cut -f2; }
units() { printf '%s\n' "$1" | grep '^\[UNIT\]' | cut -f2,3 | tr '\t' ':' | tr '\n' ' ' | sed 's/ $//'; }
mk() {
    wd=$(mktemp -d "$tmp/wd-XXXXXX"); rc=$(mktemp -d "$tmp/rc-XXXXXX"); lg="$rc/agent.log"
    cp "$P"/recipes-good/*.sh "$rc"/; : > "$lg"
    printf 'cp "%s" "$1"\n' "${1:-$P/plan.json}" > "$rc/plan.sh"
    echo "$wd $rc $lg"
}
# run <checker> <workdir> <recipes> <log> [more options]
run() {
    k=$1; w=$2; r=$3; l=$4; shift 4
    "$exe" "$k" "$B/brief.txt" "$w" "sh $B/agent.sh $r $l" --provider stand --model m1 --guide "$B/guide.txt" --attempts 4 --agent-seconds 60 "$@" 2>&1
}

# key: the signature's own unit test
"$CANCHO" test "$root/tests/signature_key_test.cho" "$SRC/signature.cho" --std --backend cranelift > "$tmp/key.out" 2>&1 \
    || { echo "FAIL: key: tests/signature_key_test.cho" >&2; cat "$tmp/key.out" >&2; fail=1; }

# refusals: the tag is the file's name (bad-<tag>[-more].json); nothing is run and the work directory stays empty
for f in "$T"/bad-*.json; do
    base=$(basename "$f" .json)
    tag=$(printf '%s\n' "${base#bad-}" | sed -E 's/^(profile-(unknown-key|missing-key|not-implemented|[a-z]+)).*/\1/')
    set -- $(mk); wd=$1; rc=$2; lg=$3
    out=$(run "$CANCHO" "$wd" "$rc" "$lg" --jobs 1 --profile "$f"); r=$?
    expect "refusal $base: exit code" "$r" 2
    expect "refusal $base: the tag" "$(printf '%s\n' "$out" | grep '^\[PROFILE_ERROR\]' | cut -f2 | sort -u | tr '\n' ' ')" "$tag "
    expect "refusal $base: nothing run" "$(cat "$lg")" ""
    expect "refusal $base: nothing written" "$(ls -A "$wd")" ""
done
# a profile that is not there
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$(run "$CANCHO" "$wd" "$rc" "$lg" --profile "$tmp/no-such-profile.json"); r=$?
expect "refusal missing file: exit code" "$r" 2
expect "refusal missing file: the tag" "$(printf '%s\n' "$out" | grep '^\[PROFILE_ERROR\]' | cut -f2)" profile-unreadable
expect "refusal missing file: nothing written" "$(ls -A "$wd")" ""
# --profile without its value
out=$("$exe" "$CANCHO" "$B/brief.txt" "$wd" "sh $B/agent.sh $rc $lg" --provider stand --model m1 --guide "$B/guide.txt" --profile 2>&1); r=$?
expect "refusal no value: exit code" "$r" 2

# default: the profile that states the default is the default
set -- $(mk); wd0=$1; rc0=$2; lg0=$3
out0=$(run "$CANCHO" "$wd0" "$rc0" "$lg0" --jobs 1); r0=$?
set -- $(mk); wd1=$1; rc1=$2; lg1=$3
out1=$(run "$CANCHO" "$wd1" "$rc1" "$lg1" --jobs 1 --profile "$T/cancho.json"); r1=$?
expect "default: exit code" "$r1" "$r0"
expect "default: verdict" "$(verdict "$out1")" done
expect "default: the same lines" "$(printf '%s\n' "$out1" | grep '^\[')" "$(printf '%s\n' "$out0" | grep '^\[')"
for f in project.cho main.cho tests-a.cho tests-b.cho tests-c.cho legend-a.txt state.txt run.log; do
    cmp -s "$wd0/$f" "$wd1/$f" || { echo "FAIL: default: $f differs from the run without --profile" >&2; fail=1; }
done
expect "default: the unit agent's arguments" "$(sed "s#$wd1#WD#g; s#$rc1#RC#g" "$rc1/unit.args")" "$(sed "s#$wd0#WD#g; s#$rc0#RC#g" "$rc0/unit.args")"
expect "default: the plan agent's arguments" "$(sed "s#$wd1#WD#g; s#$rc1#RC#g" "$rc1/plan.args")" "$(sed "s#$wd0#WD#g; s#$rc0#RC#g" "$rc0/plan.args")"
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$(run "$CANCHO" "$wd" "$rc" "$lg" --jobs 2 --profile "$T/cancho.json"); r=$?
expect "default: --jobs 2 is allowed" "$r" 0

# the wrapper: the same compiler, findings under `code`. Started with no environment, so every program is named absolutely.
sedp=$(command -v sed); cc=$(command -v "$CANCHO")
case "$cc" in /*) ;; *) cc="$(pwd)/$cc" ;; esac
wrap="$tmp/bin/checker-code"
mkdir -p "$tmp/bin"
printf '#!/bin/sh\nout=$("%s" "$@" 2>&1); s=$?\nprintf "%%s\\n" "$out" | %s "s/\\"rule\\": \\"/\\"code\\": \\"/"\nexit $s\n' "$cc" "$sedp" > "$wrap"
chmod +x "$wrap"

# renamed
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$(run "$wrap" "$wd" "$rc" "$lg" --profile "$T/renamed.json"); r=$?
expect "renamed: exit code" "$r" 0
expect "renamed: verdict" "$(verdict "$out")" done
expect "renamed: unit lines" "$(units "$out")" "a:building a:verified b:building b:verified c:building c:verified"
for f in app.cn entry.cn t-a.cn t-b.cn t-c.cn app.cn.task; do [ -f "$wd/$f" ] || { echo "FAIL: renamed: no $f" >&2; fail=1; }; done
for f in project.cho main.cho tests-a.cho; do [ -e "$wd/$f" ] && { echo "FAIL: renamed: $f was written" >&2; fail=1; }; done
for f in double is_big big_double; do grep -q "fn $f" "$wd/app.cn" || { echo "FAIL: renamed: app.cn has no $f" >&2; fail=1; }; done
grep -q 'fn main(world: World)' "$wd/entry.cn" || { echo "FAIL: renamed: entry.cn is not the fixed main" >&2; fail=1; }
grep -q '^pub fn test_a_1' "$wd/t-a.cn" || { echo "FAIL: renamed: t-a.cn holds no test of a" >&2; fail=1; }
expect "renamed: the unit agent's file" "$(awk '{print $NF}' "$rc/unit.args")" "$wd/app.cn"
expect "renamed: no primer" "$(grep -c -- '--primer' "$rc/unit.args" "$rc/plan.args" | cut -d: -f2 | tr '\n' ' ')" "0 0 "
expect "renamed: state" "$(tr '\n' ' ' < "$wd/state.txt")" "verified a verified b verified c "
[ -f "$wd/trail-a.jsonl" ] || { echo "FAIL: renamed: no trail-a.jsonl" >&2; fail=1; }

# key in use: the first attempt at a is refused (type-mismatch, reported under `code`), the second reads it from the feedback and fixes it
refused_first() {
    printf 'printf "\\nfn double(x: int) -> [] int { return x * true; }\\n" >> "$1"\n' > "$1/a.1.sh"
    printf 'grep -q "\\"code\\": \\"type-mismatch\\"" "$1.feedback" || exit 3\nsed -i.bak "s/x \\\\* true/x * 2/" "$1"\n' > "$1/a.2.sh"
}
set -- $(mk); wd=$1; rc=$2; lg=$3
refused_first "$rc"
out=$(run "$wrap" "$wd" "$rc" "$lg" --profile "$T/renamed.json"); r=$?
expect "key in use: exit code" "$r" 0
expect "key in use: verdict" "$(verdict "$out")" done
expect "key in use: a took two attempts" "$(grep -c '^a$' "$lg")" 2
expect "key in use: the trail of a" "$(grep -o '"outcome":"[a-z]*","sig":"[^"]*"' "$wd/trail-a.jsonl" | tr '\n' ' ')" '"outcome":"refused","sig":"type-mismatch:expected `int`, found `bool`" "outcome":"verified","sig":"" '
# the mutant: the same profile reading `rule`
sed 's/"key": "code"/"key": "rule"/' "$T/renamed.json" > "$tmp/renamed-rule.json"
set -- $(mk); wd=$1; rc=$2; lg=$3
refused_first "$rc"
out=$(run "$wrap" "$wd" "$rc" "$lg" --profile "$tmp/renamed-rule.json"); r=$?
expect "key mutant: exit code" "$r" 4
expect "key mutant: verdict" "$(verdict "$out")" provider_error
expect "key mutant: the trail of a" "$(grep -o '"outcome":"[a-z]*"' "$wd/trail-a.jsonl" | head -1)" '"outcome":"outage"'

# primer
printf 'a primer\n' > "$tmp/primer.md"
sed "s#\"primer\": \"\"#\"primer\": \"$tmp/primer.md\"#" "$T/renamed.json" > "$tmp/renamed-primer.json"
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$(run "$wrap" "$wd" "$rc" "$lg" --profile "$tmp/renamed-primer.json"); r=$?
expect "primer: exit code" "$r" 0
expect "primer: the plan agent gets it" "$(grep -c -- "--primer $tmp/primer.md" "$rc/plan.args")" 1
expect "primer: the unit agent gets it" "$(grep -c -- "--primer $tmp/primer.md" "$rc/unit.args")" 1

# combos
set -- $(mk); wd=$1; rc=$2; lg=$3
out=$(run "$wrap" "$wd" "$rc" "$lg" --profile "$T/renamed.json" --jobs 2); r=$?
expect "combo jobs: exit code" "$r" 2
expect "combo jobs: the tag" "$(printf '%s\n' "$out" | grep '^\[PROFILE_ERROR\]' | cut -f2)" profile-jobs
expect "combo jobs: nothing written" "$(ls -A "$wd")" ""
printf 'fn double(x: int) -> [] int { return x * 2; }\n' > "$tmp/patch.cho"
out=$(run "$wrap" "$wd" "$rc" "$lg" --profile "$T/renamed.json" --patch a "$tmp/patch.cho"); r=$?
expect "combo patch: exit code" "$r" 2
expect "combo patch: the tag" "$(printf '%s\n' "$out" | grep '^\[PROFILE_ERROR\]' | cut -f2)" profile-patch
set -- $(mk "$root/tests/multifile/plan.json"); wd=$1; rc=$2; lg=$3
out=$(run "$wrap" "$wd" "$rc" "$lg" --profile "$T/renamed.json"); r=$?
expect "combo files: exit code" "$r" 3
expect "combo files: verdict" "$(verdict "$out")" plan_failed
expect "combo files: the refusal" "$(printf '%s\n' "$out" | grep '^\[PLAN_ERROR\]' | cut -f2 | sort -u)" profile-files
expect "combo files: no unit agent" "$(cat "$lg")" PLAN

# language: the prompt's words come from the task's LANGUAGE line, and a task without one is the old prompt
"$CANCHO" test "$root/tests/prompt_language_test.cho" "$SRC/prompt.cho" --std --backend cranelift > "$tmp/lang.out" 2>&1 \
    || { echo "FAIL: language: tests/prompt_language_test.cho" >&2; cat "$tmp/lang.out" >&2; fail=1; }

# cancho-ui: the profile with a stand-in cancho-ui behind the clean wrapper (both sh builtins only: the checker runs with no environment)
U="$T/ui"
uichk="$tmp/bin/ui-checker"
printf '#!/bin/sh\nexec /bin/sh "%s" /bin/sh "%s" "$@"\n' "$U/clean-wrap.sh" "$U/standin.sh" > "$uichk"
chmod +x "$uichk"
sed "s#\"primer\": \"\"#\"primer\": \"$T/cancho-ui-primer.md\"#" "$T/cancho-ui.json" > "$tmp/cancho-ui.json"
mkui() {
    set -- $(mk "${1:-$U/plan.json}")
    rm -f "$2"/a.sh "$2"/b.sh "$2"/c.sh
    cp "$U"/recipes/*.sh "$2"/
    echo "$1 $2 $3"
}
set -- $(mkui); wd=$1; rc=$2; lg=$3
out=$(run "$uichk" "$wd" "$rc" "$lg" --profile "$tmp/cancho-ui.json"); r=$?
expect "cancho-ui: exit code" "$r" 0
expect "cancho-ui: verdict" "$(verdict "$out")" done
expect "cancho-ui: unit lines" "$(units "$out")" "a:building a:verified b:building b:verified"
expect "cancho-ui: state" "$(tr '\n' ' ' < "$wd/state.txt")" "verified a verified b "
for f in app.cui trace-a.json trace-b.json app.cui.task legend-a.txt; do [ -f "$wd/$f" ] || { echo "FAIL: cancho-ui: no $f" >&2; fail=1; }; done
for f in project.cho main.cho main.cui tests-a.cho tests-a.cui trace-a.cui; do [ -e "$wd/$f" ] && { echo "FAIL: cancho-ui: $f was written" >&2; fail=1; }; done
expect "cancho-ui: the entry is the components alone" "$(grep -c '' "$wd/app.cui") $(grep -c '^component ' "$wd/app.cui") $(grep -c 'edition' "$wd/app.cui")" "26 2 0"
expect "cancho-ui: trace-a.json is the plan's trace (an object)" "$(cat "$wd/trace-a.json")" '{"schema":"cancho-ui-trace","version":"0.1.0","component":"Counter","steps":[{"event":"Increment","state":{"count":1}},{"event":"Increment","state":{"count":2}}]}'
expect "cancho-ui: trace-b.json is the plan's trace (a string)" "$(cat "$wd/trace-b.json")" '{"schema": "cancho-ui-trace", "version": "0.1.0", "component": "Toggle", "steps": [{"event": "Flip", "state": {"lit": true}}]}'
expect "cancho-ui: the unit agent's file" "$(awk '{print $NF}' "$rc/unit.args")" "$wd/app.cui"
expect "cancho-ui: the primer reaches both agents" "$(grep -c -- "--primer $T/cancho-ui-primer.md" "$rc/plan.args" "$rc/unit.args" | cut -d: -f2 | tr '\n' ' ')" "1 1 "
task="$wd/app.cui.task"
expect "cancho-ui: the task's heads" "$(grep -o '^[A-Z]*:' "$task" | tr '\n' ' ')" "UNIT: LANGUAGE: COMPONENT: DESCRIPTION: TRACE: INSTRUCTIONS: "
expect "cancho-ui: the task's language" "$(sed -n 's/^LANGUAGE: //p' "$task")" cancho-ui
expect "cancho-ui: the task's component" "$(sed -n 's/^COMPONENT: //p' "$task")" Toggle
grep -q '^INSTRUCTIONS: Add the component `Toggle` to app.cui' "$task" || { echo "FAIL: cancho-ui: the task's instructions do not name the component and the entry" >&2; fail=1; }
grep -q 'project\.cho\|cancho program\|EXAMPLES\|SIGNATURE' "$task" && { echo "FAIL: cancho-ui: the task names cancho's files or fields" >&2; fail=1; }

# cancho-ui, the findings key: the first attempt at a is refused (reported under `code`), the second reads it from the feedback and fixes it
set -- $(mkui); wd=$1; rc=$2; lg=$3
printf 'sh "%s/a.sh" "$1"\nprintf "BROKEN\\n" >> "$1"\n' "$rc" > "$rc/a.1.sh"
printf 'grep -q "\\"code\\": \\"standin-broken\\"" "$1.feedback" || exit 3\nsed -i.bak "/^BROKEN$/d" "$1"\n' > "$rc/a.2.sh"
out=$(run "$uichk" "$wd" "$rc" "$lg" --profile "$tmp/cancho-ui.json"); r=$?
expect "cancho-ui refused first: exit code" "$r" 0
expect "cancho-ui refused first: a took two attempts" "$(grep -c '^a$' "$lg")" 2
expect "cancho-ui refused first: the trail of a" "$(grep -o '"outcome":"[a-z_]*","sig":"[^"]*"' "$wd/trail-a.jsonl" | tr '\n' ' ')" '"outcome":"refused","sig":"standin-broken:the file holds the word BROKEN" "outcome":"verified","sig":"" '

# cancho-ui, the verify: the first attempt at a checks clean but declares another component, so its trace fails; the second fixes the name
set -- $(mkui); wd=$1; rc=$2; lg=$3
printf 'sh "%s/a.sh" "$1"\nsed -i.bak "s/^component Counter {/component Countr {/" "$1"\n' "$rc" > "$rc/a.1.sh"
printf 'sed -i.bak "s/^component Countr {/component Counter {/" "$1"\n' > "$rc/a.2.sh"
out=$(run "$uichk" "$wd" "$rc" "$lg" --profile "$tmp/cancho-ui.json"); r=$?
expect "cancho-ui trace fails first: exit code" "$r" 0
expect "cancho-ui trace fails first: a took two attempts" "$(grep -c '^a$' "$lg")" 2
expect "cancho-ui trace fails first: the trail of a" "$(grep -o '"outcome":"[a-z_]*","sig":"[^"]*"' "$wd/trail-a.jsonl" | tr '\n' ' ')" '"outcome":"refused","sig":"acceptance:FAIL  trace-unknown-component (component)" "outcome":"verified","sig":"" '

# the component plan check, through the build: each refusal is plan_failed, exit 3, with exactly its rules, and no unit agent
for spec in "bad-component bad-component:a" "bad-component-twice bad-component:b" "bad-trace bad-trace:b" "bad-trace-name bad-trace:a" \
    "bad-trace-unnamed bad-trace:a" "bad-trace-type bad-trace:a" "unit-field unit-field:a unknown-dep:b"; do
    name=${spec%% *}; want=${spec#* }
    set -- $(mkui "$U/$name.json"); wd=$1; rc=$2; lg=$3
    out=$(run "$uichk" "$wd" "$rc" "$lg" --profile "$tmp/cancho-ui.json"); r=$?
    expect "cancho-ui plan $name: exit code" "$r" 3
    expect "cancho-ui plan $name: verdict" "$(verdict "$out")" plan_failed
    expect "cancho-ui plan $name: the refusals" "$(printf '%s\n' "$out" | grep '^\[PLAN_ERROR\]' | awk -F'\t' '{print $2 ":" $3}' | tr '\n' ' ' | sed 's/ $//')" "$want"
    expect "cancho-ui plan $name: no unit agent" "$(cat "$lg")" PLAN
done
# a function plan under the components profile, and the component plan under the default: neither unit reads as the other
set -- $(mkui "$P/plan.json"); wd=$1; rc=$2; lg=$3
out=$(run "$uichk" "$wd" "$rc" "$lg" --profile "$tmp/cancho-ui.json"); r=$?
expect "cancho-ui: a function plan: exit code" "$r" 3
expect "cancho-ui: a function plan: the refusals" "$(printf '%s\n' "$out" | grep '^\[PLAN_ERROR\]' | cut -f2 | sort -u)" unit-field
set -- $(mkui); wd=$1; rc=$2; lg=$3
out=$(run "$CANCHO" "$wd" "$rc" "$lg" --jobs 1); r=$?
expect "default: a component plan: exit code" "$r" 3
expect "default: a component plan: the refusals" "$(printf '%s\n' "$out" | grep '^\[PLAN_ERROR\]' | cut -f2 | sort -u)" unit-field

# cancho-ui, the real one (optional): CANCHO_UI is the cancho-ui binary, behind the same clean wrapper
if [ -n "${CANCHO_UI:-}" ]; then
    realchk="$tmp/bin/ui-real"
    case "$CANCHO_UI" in /*) ;; *) echo "FAIL: CANCHO_UI must be an absolute path" >&2; fail=1 ;; esac
    printf '#!/bin/sh\nexec /bin/sh "%s" "%s" "$@"\n' "$U/clean-wrap.sh" "$CANCHO_UI" > "$realchk"
    chmod +x "$realchk"
    set -- $(mkui); wd=$1; rc=$2; lg=$3
    out=$(run "$realchk" "$wd" "$rc" "$lg" --profile "$tmp/cancho-ui.json"); r=$?
    expect "real cancho-ui: exit code" "$r" 0
    expect "real cancho-ui: verdict" "$(verdict "$out")" done
    expect "real cancho-ui: state" "$(tr '\n' ' ' < "$wd/state.txt")" "verified a verified b "
    "$CANCHO_UI" test "$wd/app.cui" "$wd/trace-a.json" > /dev/null 2>&1 || { echo "FAIL: real cancho-ui: trace-a.json does not replay on app.cui" >&2; fail=1; }
    set -- $(mkui); wd=$1; rc=$2; lg=$3
    printf 'sh "%s/a.sh" "$1"\nsed -i.bak "s/^component Counter {/component Countr {/" "$1"\n' "$rc" > "$rc/a.1.sh"
    printf 'sed -i.bak "s/^component Countr {/component Counter {/" "$1"\n' > "$rc/a.2.sh"
    out=$(run "$realchk" "$wd" "$rc" "$lg" --profile "$tmp/cancho-ui.json"); r=$?
    expect "real cancho-ui trace fails first: exit code" "$r" 0
    expect "real cancho-ui trace fails first: the trail of a" "$(grep -o '"outcome":"[a-z_]*","sig":"[a-z]*:' "$wd/trail-a.jsonl" | tr '\n' ' ')" '"outcome":"refused","sig":"acceptance: '
else
    echo "profile gate: CANCHO_UI is not set: the real cancho-ui case is skipped"
fi

[ -n "${KEEP:-}" ] || rm -rf "$tmp"
[ "$fail" = 0 ] && echo "profile gate: every case held"
exit $fail
