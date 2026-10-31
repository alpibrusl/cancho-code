# The stand-in cancho-ui of the profile gate (scripts/test-profile.sh): no cancho-ui binary, sh builtins only (the build starts its checker
# with no environment). It answers the two commands the cancho-ui profile (tests/profile/cancho-ui.json) names, the way cancho-ui 0.1.0 does:
#
#   check [--output json] <file.cui>   exactly one file (a main beside it is a usage error, exit 2: the profile has none); exit 1 and one finding under `code` when the file holds the word BROKEN; else exit 0 and NOTHING on
#                                      standard output (cancho-ui 0.1.0 prints nothing for a clean file; tests/profile/ui/clean-wrap.sh adds `[]`)
#   test <file.cui> <trace.json>       exactly these two (else exit 2); exit 1 when the file does not check; exit 4 when the trace names no component or one the file does not
#                                      declare (`component NAME {` at the start of a line); else exit 0
#
# It does not replay anything: the gate is about the build's plumbing, and the real replay is the optional CANCHO_UI case of the gate.
cmd=$1
shift
holds_broken() {
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in *BROKEN*) return 0 ;; esac
    done < "$1"
    return 1
}
case $cmd in
check)
    json=0
    if [ "$1" = --output ]; then json=1; shift 2; fi
    [ $# = 1 ] || { printf 'stand-in cancho-ui: check takes one file here, got %s\n' "$#" >&2; exit 2; }
    [ -r "$1" ] || { printf 'stand-in cancho-ui: reading `%s`: no such file\n' "$1" >&2; exit 3; }
    if holds_broken "$1"; then
        if [ $json = 1 ]; then
            printf '[\n  {\n    "code": "standin-broken",\n    "severity": "error",\n    "message": "the file holds the word BROKEN"\n  }\n]\n'
        else
            printf 'error[standin-broken] at %s: the file holds the word BROKEN\n' "$1"
        fi
        exit 1
    fi
    exit 0
    ;;
test)
    [ $# = 2 ] || { printf 'stand-in cancho-ui: test takes a file and a trace, got %s arguments\n' "$#" >&2; exit 2; }
    [ -r "$1" ] && [ -r "$2" ] || { printf 'stand-in cancho-ui: reading the file or the trace: no such file\n' >&2; exit 3; }
    if holds_broken "$1"; then printf 'error[standin-broken] at %s: the file holds the word BROKEN\n' "$1"; exit 1; fi
    name=""
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in
        *'"component"'*) rest=${line#*\"component\"}; rest=${rest#*\"}; name=${rest%%\"*} ;;
        esac
    done < "$2"
    [ -n "$name" ] || { printf 'FAIL  trace-unknown-component (component)\n      the trace names no component\n'; exit 4; }
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in "component $name {"*) printf 'PASS  component %s\n' "$name"; exit 0 ;; esac
    done < "$1"
    printf 'FAIL  trace-unknown-component (component)\n      the file declares no component `%s`\n' "$name"
    exit 4
    ;;
esac
printf 'stand-in cancho-ui: check or test\n' >&2
exit 2
