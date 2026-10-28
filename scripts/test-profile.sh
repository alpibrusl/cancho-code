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
    "$SRC/acceptance.cho" "$SRC/splice.cho" "$SRC/pool.cho" "$SRC/parallel.cho" --std --backend cranelift -o "$exe" || { echo "gate did not build" >&2; exit 2; }

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
grep -q '"signature":"type-mismatch:expected `int`, found `bool`"' "$wd/trail-a.jsonl" \
    || { echo "FAIL: key in use: the trail of a has no type-mismatch signature" >&2; fail=1; }
# the mutant: the same profile reading `rule`
sed 's/"key": "code"/"key": "rule"/' "$T/renamed.json" > "$tmp/renamed-rule.json"
set -- $(mk); wd=$1; rc=$2; lg=$3
refused_first "$rc"
out=$(run "$wrap" "$wd" "$rc" "$lg" --profile "$tmp/renamed-rule.json"); r=$?
expect "key mutant: exit code" "$r" 4
expect "key mutant: verdict" "$(verdict "$out")" provider_error

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

rm -rf "$tmp"
[ "$fail" = 0 ] && echo "profile gate: every case held"
exit $fail
