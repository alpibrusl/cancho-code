# A cancho-ui checker for `build --profile tests/profile/cancho-ui.json`: `clean-wrap.sh <program> [<word>...] <args...>` runs the program with
# the arguments and prints `[]` when it exits 0 and prints nothing. cancho-ui 0.1.0's `check --output json` prints nothing at all for a clean
# file, and the build reads "no finding and no clean text" as the checker being away (docs/profile.md `findings.clean`), so the profile's
# checker is this wrapper around cancho-ui (or around the stand-in, tests/profile/ui/standin.sh). sh builtins only.
out=$("$@" 2>&1)
s=$?
if [ $s = 0 ] && [ -z "$out" ]; then out='[]'; fi
printf '%s\n' "$out"
exit $s
