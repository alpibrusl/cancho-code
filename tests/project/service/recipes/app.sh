grep -q "^INSTRUCTIONS: Add the application" "$1.task" || exit 3
grep -q "SENTINEL-APP" "$1.task" || exit 3
if grep -q "^EXAMPLES" "$1.task"; then exit 4; fi
printf "\nfn app_run(x: int) -> [] int { return double(x) + 1; }\n" >> "$1"
