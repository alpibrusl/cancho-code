#!/bin/sh
# The MCP server's gate (docs/mcp.md): the server is driven over pipes with canned JSON-RPC and a STAND-IN agent (tests/buildcmd/agent.sh):
# no model, no network, no key. The compiler is the real one, the build tool and the board tool are the real ones.
#
#   scripts/test-mcp.sh             run the gate
#   scripts/test-mcp.sh --mutants   prove the gate can fail: broken copies of src/mcp.cho (a `// MUTANT:<name>` marker on each edited line) must each be RED
#
#   CANCHO     the compiler (default: cancho on PATH)
#   MCP_SRC    the server's source to judge (default: src/mcp.cho); how --mutants judges a broken copy
#   MCP_TOOLS  a directory holding cancho-build and cancho-board already built (default: built here)
#
# What it asserts
#   protocol    initialize (the client's version echoed when known, the newest otherwise; serverInfo; capabilities.tools), the initialized and unknown
#               notifications get no answer, ping, tools/list equals tests/mcp/tools.json, unknown method -32601, a line that is not JSON -32700, not a
#               request -32600, unknown tool / no params / arguments that are not an object -32602, string ids come back as strings
#   schema      for every tool and every property of its schema: the handler knows it (a wrong type is `mcp.wrong-type`), and a property the schema does
#               not have is `mcp.unknown-argument`
#   names       16 bad run names and unit names (.., a/b, -x, empty, a;b, $(id), NUL, 65 bytes, ...) to every tool: `mcp.bad-name`; nothing is created
#               under the root or beside it; bad brief paths (../x, /etc/passwd, a/../b, ...): `mcp.bad-path`; both or neither brief, a brief too long
#   arguments   missing and mistyped arguments, a run that does not exist, a code that is empty
#   happy       start (brief_text and brief_path) returns at once with a pid, status is running then finished (stage, verdict, units, state, a log tail),
#               result has project.cho and complete, unit_story has the attempt with its outcome, checker text and diff
#   jobs        the same flow with --jobs 1 and 2 (status, result, unit_story with the diff of the first attempt); stop ends the workers and their agents
#   stuck       a unit that never verifies: status lists it, the story has the refusal; cancho_retry with a hint (shell metacharacters in it run nothing and
#               the hint reaches the unit agent's task file byte for byte) ends done; cancho_patch with code ends done
#   secrets     the key file's path and an API-key-shaped string, put by the stand-in into the project code, never appear in any output of the server
#   bounds      a 100 KB project and a 100 KB diff: result and story are cut and say so; no tool text is over 48 KiB; a line over 4 MiB is refused and the
#               server goes on
#   limits      with --max-runs 1: a second start is `mcp.too-many-runs`, the same name again `mcp.already-running`; stop ends the process AND what it
#               started; stop of a run not alive is refused; a new run can start after
#   eof         the end of standard input ends the server (exit 0) and the runs it started go on without it; a new server sees them and their end
#   command line  no options, a relative root, `..` in the root, a missing board: exit 2, a message on standard error, nothing on standard output
#
# Needs the real cancho as CANCHO and python3 (the test client only). Exit 0: every case held.
set -u

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
CANCHO=$(command -v "$CANCHO")
root=$(cd "$(dirname "$0")/.." && pwd)
SRC="${MCP_SRC:-$root/src/mcp.cho}"

if [ "${1:-}" = "--mutants" ]; then
    work=$(cd "$(mktemp -d -t cc-mcp-mut-XXXXXX)" && pwd -P)
    trap 'rm -rf "$work"' EXIT
    fail=0
    # The tools are built once and shared by every run of the gate on a broken copy.
    mkdir -p "$work/tools"
    "$CANCHO" build "$root/tests/programs/build.cho" "$root/src/build.cho" "$root/src/project.cho" "$root/src/plan.cho" "$root/src/driver.cho" \
        "$root/src/checker.cho" "$root/src/signature.cho" "$root/src/loop_check.cho" "$root/src/snapshot.cho" "$root/src/trail.cho" \
        "$root/src/acceptance.cho" "$root/src/splice.cho" "$root/src/pool.cho" "$root/src/parallel.cho" "$root/src/library.cho" "$root/src/cases.cho" --std -o "$work/tools/cancho-build" >/dev/null 2>&1 || { echo "FAIL: the build tool did not build" >&2; exit 1; }
    "$CANCHO" build "$root/tests/programs/board.cho" "$root/src/board.cho" "$root/src/plan.cho" --std -o "$work/tools/cancho-board" >/dev/null 2>&1 || { echo "FAIL: the board tool did not build" >&2; exit 1; }
    mutant() {
        name=$1; from=$2; to=$3
        grep -q "// MUTANT:$name" "$root/src/mcp.cho" || { echo "FAIL: no marker MUTANT:$name in src/mcp.cho" >&2; fail=1; return; }
        python3 - "$root/src/mcp.cho" "$work/$name.cho" "$name" "$from" "$to" <<'PY' || { echo "FAIL: mutant $name: the marked line does not contain the text to change" >&2; fail=1; return; }
import sys
src, dst, name, a, b = sys.argv[1:6]
out, hit = [], 0
for line in open(src).read().split("\n"):
    if "// MUTANT:" + name in line:
        if a not in line:
            sys.exit(1)
        line, hit = line.replace(a, b), hit + 1
    out.append(line)
sys.exit(0 if hit == 1 and open(dst, "w").write("\n".join(out)) else 1)
PY
        if env MCP_SRC="$work/$name.cho" MCP_TOOLS="$work/tools" sh "$0" >"$work/$name.out" 2>&1; then
            echo "FAIL: mutant $name survived: the gate passed on a broken server" >&2; fail=1
        else
            echo "ok: mutant $name is red ($(grep -c '^FAIL' "$work/$name.out") failures)" >&2
        fi
    }
    mutant pathrel    'bytes.find(text, "..") >= 0 || bytes.find(text, "//") >= 0 || bytes.find(text, "/-") >= 0 || bytes.find(text, "/.") >= 0 || int_of(text[0]) == 46' 'false'   # a brief path with .. is accepted
    mutant namedots   'bytes.find(text, "..") >= 0' 'false'                       # a run name with .. is accepted
    mutant keypath    'cfg.secret' '""'                                           # the key file's path is no longer taken out of a result
    mutant keypattern 'bytes.equal(text[i..i + 7], "sk-ant-")' 'false'            # an API-key-shaped string is no longer taken out of a result
    mutant shell      'echo $!";' 'for last; do :; done; eval \"$last\"; echo $!";'   # the last argument (a hint) is run by a shell
    mutant resultcap  'result_cap()' '100000000'                                  # the project is read whole
    mutant storycap   '2048' '2000000'                                            # a diff is returned whole
    mutant cap        'live >= cfg.max_runs' 'live >= 1000'                       # the limit on runs at once is not enforced
    mutant eof        'read == 1' 'read == 7'                                     # the end of input does not end the server
    mutant handlerkey '"name|unit|code"' '"name|unit|code|force"'                 # a handler takes a property its schema does not have
    mutant schemaname '\"brief_path\"' '\"brief_file\"'                           # the schema names a property the handler does not take
    exit $fail
fi

work=$(cd "$(mktemp -d -t cc-mcp-XXXXXX)" && pwd -P)
cleanup() {
    # Whatever a failed case left running under the work directory.
    pkill -f "$work" >/dev/null 2>&1
    rm -rf "$work"
}
trap cleanup EXIT
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }
expect() { [ "$2" = "$3" ] || bad "$1: wanted '$3', got '$2'"; }
T="$root/tests/mcp"
B="$root/tests/buildcmd"
P="$root/tests/project"
Q() { python3 "$T/q.py" "$1" "$2" "$3"; }

# ---- the programs ----
tools="${MCP_TOOLS:-$work/tools}"
mkdir -p "$work/tools" "$work/out" "$work/in"
if [ -z "${MCP_TOOLS:-}" ]; then
    "$CANCHO" build "$root/tests/programs/build.cho" "$root/src/build.cho" "$root/src/project.cho" "$root/src/plan.cho" "$root/src/driver.cho" \
        "$root/src/checker.cho" "$root/src/signature.cho" "$root/src/loop_check.cho" "$root/src/snapshot.cho" "$root/src/trail.cho" \
        "$root/src/acceptance.cho" "$root/src/splice.cho" "$root/src/pool.cho" "$root/src/parallel.cho" "$root/src/library.cho" "$root/src/cases.cho" --std -o "$tools/cancho-build" >"$work/build.log" 2>&1 || { cat "$work/build.log" >&2; echo "FAIL: the build tool did not build" >&2; exit 1; }
    "$CANCHO" build "$root/tests/programs/board.cho" "$root/src/board.cho" "$root/src/plan.cho" --std -o "$tools/cancho-board" >"$work/build.log" 2>&1 || { cat "$work/build.log" >&2; echo "FAIL: the board tool did not build" >&2; exit 1; }
fi
exe="$work/cancho-mcp"
"$CANCHO" build "$root/tests/programs/mcp.cho" "$SRC" --std -o "$exe" >"$work/build.log" 2>&1 || { cat "$work/build.log" >&2; echo "FAIL: the server did not build" >&2; exit 1; }

ROOT="$work/root"; mkdir -p "$ROOT"
KEYDIR="$work/keys"; mkdir -p "$KEYDIR"
KEYFILE="$KEYDIR/anthropic.key"
printf 'sk-ant-api03-GATESECRETGATESECRET\n' > "$KEYFILE"

# ---- helpers ----
# the stand-in agent's recipes: mkrc <plan.json> -> the recipe directory (a.sh, b.sh, c.sh as tests/project/recipes-good, plan.sh copies the plan)
mkrc() {
    d=$(mktemp -d "$work/rc-XXXXXX")
    cp "$P"/recipes-good/*.sh "$d"/
    printf 'cp "%s" "$1"\n' "${1:-$P/plan.json}" > "$d/plan.sh"
    : > "$d/log"
    echo "$d"
}
agent_for() { echo "sh $B/agent.sh $1 $1/log --key-file $KEYFILE"; }
RC=$(mkrc); AGENT=$(agent_for "$RC")

# srv <timeout> <request file> <response file> [more server options]  (later options win)
srv() {
    st=$1; rq=$2; rs=$3; shift 3
    python3 "$T/rpc.py" "$st" "$rs" "$rq" -- "$exe" --root "$ROOT" --build-bin "$tools/cancho-build" --board-bin "$tools/cancho-board" \
        --prices "$root/eval/prices.json" --checker "$CANCHO" --agent-command "$AGENT" --provider stand --model m1 --guide "$B/guide.txt" "$@"
}
rqs() { printf '{"jsonrpc":"2.0","id":%s,"method":"%s","params":%s}\n' "$1" "$2" "$3"; }
tc() { rqs "$1" tools/call "{\"name\":\"$2\",\"arguments\":$3}"; }
n=0
# one <name of the case> <request line> [server options]: one request, one response in $work/out/<n>
one() {
    n=$((n + 1)); label=$1; line=$2; shift 2
    printf '%s\n' "$line" > "$work/in/$n"
    srv 60 "$work/in/$n" "$work/out/$n" "$@"; ONE_RC=$?
    ONE=$work/out/$n
}
# wait_done <name> [server options]: poll cancho_status until the run's process is gone
wait_done() {
    wname=$1; shift
    k=0
    while [ $k -lt 160 ]; do
        one poll "$(tc 1 cancho_status "{\"name\":\"$wname\"}")" "$@"
        [ "$(Q "$ONE" 1 "T['alive']")" = false ] && return 0
        sleep 0.5; k=$((k + 1))
    done
    bad "wait_done: $wname did not end"; return 1
}
JS='r["result"]["isError"]'

# ---- protocol ----
{
    rqs 1 initialize '{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"gate","version":"1"}}'
    printf '{"jsonrpc":"2.0","method":"notifications/initialized"}\n'
    rqs 2 initialize '{"protocolVersion":"1999-01-01"}'
    rqs 3 ping '{}'
    rqs 4 tools/list '{}'
    printf '{"jsonrpc":"2.0","method":"whatever/else","params":{}}\n'
    rqs 5 nope '{}'
    printf 'this is not json\n'
    printf '[1]\n'
    printf '{"jsonrpc":"1.0","id":6,"method":"ping"}\n'
    printf '{"jsonrpc":"2.0","id":7}\n'
    rqs 8 tools/call '{"name":"nope","arguments":{}}'
    rqs 9 tools/call '{}'
    rqs 10 tools/call '{"name":"cancho_status","arguments":[1]}'
    printf '{"jsonrpc":"2.0","id":"str-id","method":"ping"}\n'
} > "$work/in/proto"
srv 30 "$work/in/proto" "$work/out/proto"; rc=$?
expect "protocol: exit code at the end of input" "$rc" 0
expect "protocol: one answer per request, none per notification" "$(wc -l < "$work/out/proto" | tr -d ' ')" 13
P1="$work/out/proto"
expect "protocol: the client's version is echoed" "$(Q $P1 1 "r['result']['protocolVersion']")" 2025-06-18
expect "protocol: an unknown version gets the newest" "$(Q $P1 2 "r['result']['protocolVersion']")" 2025-11-25
expect "protocol: serverInfo" "$(Q $P1 1 "r['result']['serverInfo']['name']")" cancho-code
expect "protocol: capabilities.tools" "$(Q $P1 1 "'tools' in r['result']['capabilities']")" true
expect "protocol: no capability that is not served" "$(Q $P1 1 "sorted(r['result']['capabilities'])")" '["tools"]'
expect "protocol: jsonrpc and id on the answer" "$(Q $P1 1 "[r['jsonrpc'], r['id']]")" '["2.0", 1]'
expect "protocol: ping" "$(Q $P1 3 "r['result']")" '{}'
expect "protocol: tools/list is tests/mcp/tools.json" "$(Q $P1 4 "r['result']==json.load(open('$T/tools.json'))")" true
expect "protocol: seven tools" "$(Q $P1 4 "len(r['result']['tools'])")" 7
expect "protocol: every tool has a description and a closed object schema" "$(Q $P1 4 "all(t['description'] and t['inputSchema']['type']=='object' and t['inputSchema']['additionalProperties']==False and set(t['inputSchema']['required'])<=set(t['inputSchema']['properties']) for t in r['result']['tools'])")" true
expect "protocol: the tools that return build text say it is data" "$(Q $P1 4 "all('DATA' in t['description'] for t in r['result']['tools'] if t['name'] in ('cancho_status','cancho_unit_story','cancho_result'))")" true
expect "protocol: unknown method" "$(Q $P1 5 "r['error']['code']")" -32601
expect "protocol: not JSON" "$(Q $P1 6 "[r['error']['code'], r['id']]")" '[-32700, null]'
expect "protocol: a batch is not a request" "$(Q $P1 7 "r['error']['code']")" -32600
expect "protocol: jsonrpc 1.0 is not a request" "$(Q $P1 8 "[r['error']['code'], r['id']]")" '[-32600, 6]'
expect "protocol: a request without a method" "$(Q $P1 9 "r['error']['code']")" -32600
expect "protocol: unknown tool" "$(Q $P1 10 "r['error']['code']")" -32602
expect "protocol: tools/call without params" "$(Q $P1 11 "r['error']['code']")" -32602
expect "protocol: arguments that are not an object" "$(Q $P1 12 "r['error']['code']")" -32602
expect "protocol: a string id comes back a string" "$(Q $P1 13 "r['id']")" str-id

# ---- the schema and the handlers agree ----
python3 "$T/cases.py" schema "$T/tools.json" > "$work/in/schema"
srv 60 "$work/in/schema" "$work/out/schema"; expect "schema: exit code" "$?" 0
expect "schema: every property of every schema is known to its handler, and no other is" "$(python3 "$T/cases.py" schema-check "$T/tools.json" "$work/out/schema")" OK

# ---- bad names and paths ----
beside() { ls -A "$work" | grep -v -e '^before.txt$' -e '^after.txt$' | sort; }
beside > "$work/before.txt"
python3 "$T/cases.py" names > "$work/in/names"
srv 90 "$work/in/names" "$work/out/names"; expect "names: exit code" "$?" 0
expect "names: every bad run or unit name is refused" "$(python3 "$T/cases.py" names-check "$work/out/names")" OK
expect "names: nothing was created under the root" "$(ls -A "$ROOT" | wc -l | tr -d ' ')" 0
beside > "$work/after.txt"
expect "names: nothing was created beside the root" "$(diff "$work/before.txt" "$work/after.txt" | wc -l | tr -d ' ')" 0
python3 "$T/cases.py" paths > "$work/in/paths"
srv 60 "$work/in/paths" "$work/out/paths"; expect "paths: exit code" "$?" 0
expect "paths: every bad brief path is refused" "$(python3 "$T/cases.py" paths-check "$work/out/paths")" OK
expect "paths: nothing was created under the root" "$(ls -A "$ROOT" | wc -l | tr -d ' ')" 0
one nobrief "$(tc 1 cancho_build_start '{"name":"pp","brief_path":"nope.txt"}')"
expect "paths: a brief that is not there" "$(Q "$ONE" 1 "T['error']['rule']")" mcp.no-brief
one bothbrief "$(tc 1 cancho_build_start '{"name":"pp","brief_path":"nope.txt","brief_text":"x"}')"
expect "brief: both" "$(Q "$ONE" 1 "T['error']['rule']")" mcp.brief
one neitherbrief "$(tc 1 cancho_build_start '{"name":"pp"}')"
expect "brief: neither" "$(Q "$ONE" 1 "T['error']['rule']")" mcp.brief
python3 -c "import json;print(json.dumps({'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':'cancho_build_start','arguments':{'name':'pp','brief_text':'x'*16385}}}))" > "$work/in/bigbrief"
srv 30 "$work/in/bigbrief" "$work/out/bigbrief"
expect "brief: 16385 bytes of text" "$(Q "$work/out/bigbrief" 1 "T['error']['rule']")" mcp.brief-too-long
expect "brief: nothing was created" "$(ls -A "$ROOT" | wc -l | tr -d ' ')" 0

# ---- missing and mistyped arguments ----
{
    tc 1 cancho_build_start '{}'
    tc 2 cancho_build_start '{"name":5,"brief_text":"x"}'
    tc 3 cancho_build_start '{"name":"a","brief_text":5}'
    tc 4 cancho_status '{}'
    tc 5 cancho_status '{"name":["a"]}'
    tc 6 cancho_unit_story '{"name":"a"}'
    tc 7 cancho_patch '{"name":"a","unit":"b"}'
    tc 8 cancho_patch '{"name":"a","unit":"b","code":""}'
    tc 9 cancho_retry '{"name":"a","unit":"b","hint":7}'
    tc 10 cancho_result '{"name":"nosuch"}'
    tc 11 cancho_status '{"name":"nosuch"}'
    tc 12 cancho_unit_story '{"name":"nosuch","unit":"u"}'
    tc 13 cancho_retry '{"name":"nosuch","unit":"u"}'
    tc 14 cancho_patch '{"name":"nosuch","unit":"u","code":"x"}'
    tc 15 cancho_stop '{"name":"nosuch"}'
    tc 16 cancho_stop '{}'
    tc 17 cancho_retry '{"name":"nosuch","unit":"u","hint":"'"$(python3 -c "print('h'*4001)")"'"}'
} > "$work/in/args"
srv 60 "$work/in/args" "$work/out/args"; expect "arguments: exit code" "$?" 0
A="$work/out/args"
for i in 1 2 3 4 5 6 7 9 16; do expect "arguments: $i is a type error" "$(Q $A $i "[$JS, T['error']['rule']]")" '[true, "mcp.wrong-type"]'; done
expect "arguments: an empty code" "$(Q $A 8 "T['error']['rule']")" mcp.bad-code
for i in 10 11 12 13 14; do expect "arguments: $i names no run" "$(Q $A $i "T['error']['rule']")" mcp.no-such-run; done
expect "arguments: stop of a run that is not there" "$(Q $A 15 "T['error']['rule']")" mcp.not-running
expect "arguments: a hint over 4000 bytes" "$(Q $A 17 "T['error']['rule']")" mcp.bad-hint
expect "arguments: nothing was created" "$(ls -A "$ROOT" | wc -l | tr -d ' ')" 0

# ---- a run made by hand, adopted: the reading tools work on a directory under the root ----
cp -R "$root/tests/board/done" "$ROOT/fx-done"
one adopt "$(tc 1 cancho_status '{"name":"fx-done"}')"
expect "adopt: status of a run made by hand" "$(Q "$ONE" 1 "[T['ok'], T['alive'], T['state'], T['cost_usd']>0, 'units_stuck' in T]")" '[true, false, "not_running", true, true]'
one adoptr "$(tc 1 cancho_retry '{"name":"fx-done","unit":"decode"}')"
expect "adopt: ... but a retry needs the brief record the server wrote" "$(Q "$ONE" 1 "T['error']['rule']")" mcp.no-such-run
rm -rf "$ROOT/fx-done"

# ---- the happy path: start, poll, result, story ----
# b.sh also writes what a leaking agent would: the key file's path and a key-shaped string, in a comment above its function (a comment that belongs to no
# item is trivia, which putting a unit's items into the file, docs/parallel.md, does not carry)
cat > "$RC/b.sh" <<'XEOF'
printf "\n// --key-file KEYFILE sk-ant-api03-LEAKLEAKLEAK\nfn is_big(x: int) -> [] bool { return x > 10; }\n" >> "$1"
XEOF
sed -i.bak "s#KEYFILE#$KEYFILE#" "$RC/b.sh"
one start "$(python3 "$T/cases.py" call cancho_build_start name=h1 brief_text=@"$B/brief.txt")"
expect "happy: start returns" "$(Q "$ONE" 1 "[$JS, T['ok'], T['started'], T['run']]")" '[false, true, true, "h1"]'
HPID=$(Q "$ONE" 1 "T['pid']")
[ -f "$ROOT/h1/brief.txt" ] || bad "happy: brief_text was not saved as brief.txt in the run's directory"
one status0 "$(tc 1 cancho_status '{"name":"h1"}')"
expect "happy: status right after start is a status" "$(Q "$ONE" 1 "T['ok']")" true
wait_done h1
one status "$(tc 1 cancho_status '{"name":"h1"}')"
S="$ONE"
expect "happy: status: finished" "$(Q $S 1 "[T['alive'], T['state'], T['stage'], T['verdict']]")" '[false, "finished", "done", "done"]'
expect "happy: status: units" "$(Q $S 1 "[T['units_verified'], T['units_total'], T['units_stuck']]")" '[3, 3, []]'
expect "happy: status: a log tail with the verdict" "$(Q $S 1 "'[BUILD_VERDICT]' in T['log_tail']")" true
expect "happy: status: cost is a field (null for a stand-in that records no usage)" "$(Q $S 1 "'cost_usd' in T")" true
one result "$(tc 1 cancho_result '{"name":"h1"}')"
expect "happy: result: complete, with project.cho" "$(Q "$ONE" 1 "[T['complete'], T['verdict'], 'fn big_double' in T['project_cho'], T['truncated']]")" '[true, "done", true, false]'
one story "$(tc 1 cancho_unit_story '{"name":"h1","unit":"a"}')"
expect "happy: story: the attempt" "$(Q "$ONE" 1 "[T['attempts_total'], T['attempts'][0]['outcome'], 'double' in T['attempts'][0]['diff'], 'refused' in T['attempts'][0]['checker']]")" '[1, "verified", true, true]'
expect "happy: story: says it is data" "$(Q "$ONE" 1 "'DATA' in T['note']")" true
one story2 "$(tc 1 cancho_unit_story '{"name":"h1","unit":"nosuchunit"}')"
expect "happy: story: a unit the plan does not have" "$(Q "$ONE" 1 "T['error']['rule']")" mcp.no-such-unit
# brief_path: a file under the root
cp "$B/brief.txt" "$ROOT/mybrief.txt"
one startpath "$(tc 1 cancho_build_start '{"name":"h2","brief_path":"mybrief.txt"}')"
expect "happy: start with brief_path" "$(Q "$ONE" 1 "[T['ok'], T['started']]")" '[true, true]'
wait_done h2
one status2 "$(tc 1 cancho_status '{"name":"h2"}')"
expect "happy: brief_path run finished" "$(Q "$ONE" 1 "T['verdict']")" done
# the stand-in really did write the leak into the project (so the secrets case below means something)
grep -q "$KEYFILE" "$ROOT/h1/project.cho" || bad "secrets: the stand-in did not put the key path into project.cho (the case is empty)"
one resultleak "$(tc 1 cancho_result '{"name":"h1"}')"
expect "secrets: the leak is replaced in a result" "$(Q "$ONE" 1 "T['project_cho'].count('[redacted]')>=2")" true

# ---- the same through a build that runs units side by side (the server passes --jobs when its operator gave one; build's default is 4) ----
for jb in 1 2; do
    JN=$(printf '{"name":"hj%s"}' $jb)
    one "jobs$jb" "$(tc 1 cancho_build_start "$(printf '{"name":"hj%s","brief_text":"a tiny library"}' $jb)")" --jobs $jb
    expect "jobs $jb: start" "$(Q "$ONE" 1 "[T['ok'], T['started']]")" '[true, true]'
    wait_done hj$jb --jobs $jb
    one "jobs${jb}s" "$(tc 1 cancho_status "$JN")" --jobs $jb
    expect "jobs $jb: status: finished, three units" "$(Q "$ONE" 1 "[T['alive'], T['state'], T['verdict'], T['units_verified'], T['units_total'], T['units_stuck']]")" '[false, "finished", "done", 3, 3, []]'
    one "jobs${jb}r" "$(tc 1 cancho_result "$JN")" --jobs $jb
    expect "jobs $jb: result: complete" "$(Q "$ONE" 1 "[T['complete'], 'fn big_double' in T['project_cho']]")" '[true, true]'
    one "jobs${jb}u" "$(tc 1 cancho_unit_story "$(printf '{"name":"hj%s","unit":"a"}' $jb)")" --jobs $jb
    expect "jobs $jb: story: the attempt, its checker text and its diff against the file before" "$(Q "$ONE" 1 "[T['attempts_total'], T['attempts'][0]['outcome'], 'double' in T['attempts'][0]['diff'], 'refused' in T['attempts'][0]['checker']]")" '[1, "verified", true, true]'
done
expect "jobs 2: the journal says the units ran in lanes" "$(grep -c '"lane":' "$ROOT/hj2/journal/events.jsonl" | sed 's/^[1-9][0-9]*$/some/')" some
expect "jobs 1: it did not" "$(grep -c '"lane":' "$ROOT/hj1/journal/events.jsonl")" 0
# stop ends the workers and what they started too
RCP=$(mkrc "$P/plan.json"); printf 'exec sleep 298\n' > "$RCP/a.sh"; cp "$RCP/a.sh" "$RCP/b.sh"
AP=$(agent_for "$RCP")
one pstart "$(tc 1 cancho_build_start '{"name":"hp","brief_text":"slow units"}')" --agent-command "$AP" --jobs 2
k=0; while [ $k -lt 80 ]; do [ "$(ps -A -o args= | grep -c '[s]leep 298')" -ge 2 ] && break; sleep 0.25; k=$((k + 1)); done
[ "$(ps -A -o args= | grep -c '[s]leep 298')" -ge 2 ] || bad "jobs 2: two units were not running together"
one pstop "$(tc 1 cancho_stop '{"name":"hp"}')" --agent-command "$AP" --jobs 2
expect "jobs 2: stop" "$(Q "$ONE" 1 "T['stopped']")" true
k=0; while [ $k -lt 40 ]; do ps -A -o args= | grep -q '[s]leep 298' || break; sleep 0.25; k=$((k + 1)); done
ps -A -o args= | grep -q '[s]leep 298' && bad "jobs 2: stop left the units' agents running"

# ---- a stuck unit, a retry with a hint, a patch ----
SRC_STUCK() { # a.sh: wrong without a HINT line, right with one (and keeps the task it saw)
    cat <<'XEOF'
if grep -q '^HINT:' "$1.task"; then
    cp "$1.task" "WORKDIR/task.copy"
    printf "\nfn double(x: int) -> [] int { return x * 2; }\n" >> "$1"
else
    sed -i.bak "/fn double/d" "$1"; printf "\nfn double(x: int) -> [] int { return x + 3; }\n" >> "$1"
fi
XEOF
}
RC2=$(mkrc "$P/plan.json"); SRC_STUCK | sed "s#WORKDIR#$work#" > "$RC2/a.sh"
A2=$(agent_for "$RC2")
one stuck "$(tc 1 cancho_build_start '{"name":"st","brief_text":"a tiny library"}')" --agent-command "$A2"
wait_done st --agent-command "$A2"
one ststatus "$(tc 1 cancho_status '{"name":"st"}')" --agent-command "$A2"
expect "stuck: verdict and stuck units" "$(Q "$ONE" 1 "[T['verdict'], T['units_stuck'], T['units_verified']]")" '["stuck", ["a"], 1]'
one ststory "$(tc 1 cancho_unit_story '{"name":"st","unit":"a"}')"
expect "stuck: story: the attempt did not verify, with a signature and a refusal or example output" "$(Q "$ONE" 1 "[T['column'], T['attempts'][-1]['outcome']!='verified', len(T['attempts'][-1]['signature'])>0, len(T['attempts'][-1].get('checker',''))+len(T['attempts'][-1].get('acceptance',''))>0]")" '["stuck", true, true, true]'
HINT="multiply; touch $work/PWN1 \$(touch $work/PWN2) \`touch $work/PWN3\` && echo \"q\" 'r' | cat > $work/PWN4"
python3 - "$HINT" > "$work/in/hint" <<'PY'
import json, sys
print(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "cancho_retry", "arguments": {"name": "st", "unit": "a", "hint": sys.argv[1]}}}))
PY
srv 60 "$work/in/hint" "$work/out/hint" --agent-command "$A2"
expect "retry: started" "$(Q "$work/out/hint" 1 "[T['ok'], T['started']]")" '[true, true]'
wait_done st --agent-command "$A2"
one stdone "$(tc 1 cancho_status '{"name":"st"}')" --agent-command "$A2"
expect "retry: ends done" "$(Q "$ONE" 1 "[T['verdict'], T['units_verified'], T['retry']]")" '["done", 3, "a"]'
expect "retry: the hint reached the unit agent's task byte for byte" "$(grep -c -F "HINT: $HINT" "$work/task.copy")" 1
ls "$work"/PWN* >/dev/null 2>&1 && bad "retry: a shell ran the hint (a PWN file exists)"
case "$(cat "$RC2/unit.args")" in *multiply*|*--hint*) bad "retry: the hint went into the agent's command line" ;; esac
# patch: another stuck run, then the person's own code (with shell metacharacters in a comment)
RC3=$(mkrc "$P/plan.json"); printf 'sed -i.bak "/fn double/d" "$1"; printf "\\nfn double(x: int) -> [] int { return x + 3; }\\n" >> "$1"\n' > "$RC3/a.sh"
A3=$(agent_for "$RC3")
one stuck2 "$(tc 1 cancho_build_start '{"name":"st2","brief_text":"a tiny library"}')" --agent-command "$A3"
wait_done st2 --agent-command "$A3"
python3 - "$work" > "$work/in/patch" <<'PY'
import json, sys
w = sys.argv[1]
code = "```\nfn double(x: int) -> [] int { return x * 2; } // ; touch %s/PWN5 $(touch %s/PWN6)\n```\n" % (w, w)
print(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "cancho_patch", "arguments": {"name": "st2", "unit": "a", "code": code}}}))
PY
srv 60 "$work/in/patch" "$work/out/patch" --agent-command "$A3"
expect "patch: started" "$(Q "$work/out/patch" 1 "[T['ok'], T['started']]")" '[true, true]'
wait_done st2 --agent-command "$A3"
one pdone "$(tc 1 cancho_status '{"name":"st2"}')" --agent-command "$A3"
expect "patch: ends done, names the unit" "$(Q "$ONE" 1 "[T['verdict'], T['patch']]")" '["done", "a"]'
ls "$work"/PWN* >/dev/null 2>&1 && bad "patch: a shell ran the code (a PWN file exists)"
[ -f "$ROOT/st2/patch-a.cho" ] || bad "patch: the code was not written in the run's directory"

# ---- bounds ----
RC4=$(mkrc "$P/plan.json")
printf 'printf "\\nfn double(x: int) -> [] int { return x * 2; }\\n" >> "$1"; i=0; while [ $i -lt 2000 ]; do printf "// padding padding padding padding padding padd\\n" >> "$1"; i=$((i+1)); done\n' > "$RC4/a.sh"
A4=$(agent_for "$RC4")
one big "$(tc 1 cancho_build_start '{"name":"bg","brief_text":"a tiny library"}')" --agent-command "$A4"
wait_done bg --agent-command "$A4"
one bgresult "$(tc 1 cancho_result '{"name":"bg"}')"
expect "bounds: result: project.cho is cut and says so" "$(Q "$ONE" 1 "[T['truncated'], len(T['project_cho'])<=24576, len(T['project_cho'])>20000]")" '[true, true, true]'
expect "bounds: result: the text of the tool is under 48 KiB" "$(Q "$ONE" 1 "len(r['result']['content'][0]['text'])<49152")" true
one bgstory "$(tc 1 cancho_unit_story '{"name":"bg","unit":"a"}')"
expect "bounds: story: the diff is cut at 2048 bytes and says so" "$(Q "$ONE" 1 "[T['attempts'][0]['diff_truncated'], len(T['attempts'][0]['diff'])<=2048]")" '[true, true]'
expect "bounds: story: the whole text is under 32 KiB" "$(Q "$ONE" 1 "len(r['result']['content'][0]['text'])<32768")" true
python3 -c "
import json
print('{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"cancho_status\",\"arguments\":{\"name\":\"' + 'x'*(4*1024*1024+100) + '\"}}}')
print('{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}')" > "$work/in/longline"
srv 60 "$work/in/longline" "$work/out/longline"; expect "bounds: a line over 4 MiB: exit" "$?" 0
expect "bounds: a line over 4 MiB is refused" "$(Q "$work/out/longline" 1 "r['error']['code']")" -32600
expect "bounds: ... and the server goes on" "$(Q "$work/out/longline" 2 "r['result']")" '{}'

# ---- limits, stop ----
RC5=$(mkrc "$P/plan.json"); printf 'sleep 299\n' > "$RC5/plan.sh"
A5=$(agent_for "$RC5")
one la "$(tc 1 cancho_build_start '{"name":"la","brief_text":"slow"}')" --agent-command "$A5" --max-runs 1
expect "limits: first run starts" "$(Q "$ONE" 1 "T['started']")" true
LPID=$(Q "$ONE" 1 "T['pid']")
k=0; while [ $k -lt 40 ]; do ps -A -o args= | grep -q '[s]leep 299' && break; sleep 0.25; k=$((k + 1)); done
ps -A -o args= | grep -q '[s]leep 299' || bad "limits: the slow run never started its child"
one lb "$(tc 1 cancho_build_start '{"name":"lb","brief_text":"slow"}')" --agent-command "$A5" --max-runs 1
expect "limits: a second run over the cap" "$(Q "$ONE" 1 "[$JS, T['error']['rule']]")" '[true, "mcp.too-many-runs"]'
[ -e "$ROOT/lb" ] && bad "limits: the refused run left a directory"
one lc "$(tc 1 cancho_build_start '{"name":"la","brief_text":"slow"}')" --agent-command "$A5" --max-runs 1
expect "limits: the same run again" "$(Q "$ONE" 1 "T['error']['rule']")" mcp.already-running
one ld "$(tc 1 cancho_retry '{"name":"la","unit":"a"}')" --agent-command "$A5" --max-runs 1
expect "limits: retry of a run that is alive" "$(Q "$ONE" 1 "T['error']['rule']")" mcp.already-running
one le "$(tc 1 cancho_status '{"name":"la"}')" --agent-command "$A5" --max-runs 1
expect "limits: status of the alive run" "$(Q "$ONE" 1 "[T['alive'], T['state']]")" '[true, "running"]'
one lf "$(tc 1 cancho_stop '{"name":"la"}')" --agent-command "$A5" --max-runs 1
expect "limits: stop" "$(Q "$ONE" 1 "[$JS, T['stopped']]")" '[false, true]'
k=0; while [ $k -lt 40 ]; do one lg "$(tc 1 cancho_status '{"name":"la"}')" --agent-command "$A5" --max-runs 1; [ "$(Q "$ONE" 1 "T['alive']")" = false ] && break; sleep 0.25; k=$((k + 1)); done
expect "limits: the stopped run is not alive" "$(Q "$ONE" 1 "[T['alive'], T['state']]")" '[false, "not_running"]'
k=0; while [ $k -lt 20 ]; do ps -A -o args= | grep -q '[s]leep 299' || break; sleep 0.25; k=$((k + 1)); done
ps -A -o args= | grep -q '[s]leep 299' && bad "limits: stop left what the run started (sleep 299)"
one lh "$(tc 1 cancho_stop '{"name":"la"}')" --agent-command "$A5" --max-runs 1
expect "limits: stop of a run that is not alive" "$(Q "$ONE" 1 "T['error']['rule']")" mcp.not-running
one li "$(tc 1 cancho_build_start '{"name":"lb","brief_text":"slow"}')" --agent-command "$A5" --max-runs 1
expect "limits: a new run starts once the first is gone" "$(Q "$ONE" 1 "T['started']")" true
one lj "$(tc 1 cancho_stop '{"name":"lb"}')" --agent-command "$A5" --max-runs 1

# ---- the end of input, and the runs that go on without the server ----
RC6=$(mkrc "$P/plan.json"); printf 'sleep 5; cp "%s" "$1"\n' "$P/plan.json" > "$RC6/plan.sh"
A6=$(agent_for "$RC6")
start=$(date +%s)
one eof "$(tc 1 cancho_build_start '{"name":"ed","brief_text":"goes on"}')" --agent-command "$A6"
elapsed=$(( $(date +%s) - start ))
expect "eof: the server ends at the end of input (exit 0)" "$ONE_RC" 0
[ "$elapsed" -lt 4 ] || bad "eof: the server took $elapsed seconds to end, the run takes more: it waited for the run"
EPID=$(Q "$ONE" 1 "T['pid']")
kill -0 "$EPID" 2>/dev/null || bad "eof: the run did not outlive the server"
one eof2 "$(tc 1 cancho_status '{"name":"ed"}')" --agent-command "$A6"
expect "eof: a new server sees the run alive" "$(Q "$ONE" 1 "T['alive']")" true
wait_done ed --agent-command "$A6"
one eof3 "$(tc 1 cancho_status '{"name":"ed"}')" --agent-command "$A6"
expect "eof: ... and its end" "$(Q "$ONE" 1 "[T['verdict'], T['units_verified']]")" '["done", 3]'

# ---- secrets: nowhere in anything the server printed ----
if grep -r -l -F "$KEYFILE" "$work/out" >/dev/null 2>&1; then bad "secrets: the key file's path is in the server's output: $(grep -r -l -F "$KEYFILE" "$work/out" | head -3 | tr '\n' ' ')"; fi
if grep -r -l -F "sk-ant-" "$work/out" >/dev/null 2>&1; then bad "secrets: an API-key-shaped string is in the server's output"; fi
if grep -r -l -F "GATESECRET" "$work/out" >/dev/null 2>&1; then bad "secrets: the key file's content is in the server's output"; fi
if grep -r -l -F "$KEYDIR" "$work/out" >/dev/null 2>&1; then bad "secrets: the key file's directory is in the server's output"; fi

# ---- the command line ----
cl() { rm -f "$work/cl.out" "$work/cl.out.err"; python3 "$T/rpc.py" 10 "$work/cl.out" /dev/null -- "$exe" "$@"; echo $?; cp "$work/cl.out.err" "$work/cl.err" 2>/dev/null; }
expect "command line: no options: exit" "$(cl)" 2
[ -s "$work/cl.err" ] || bad "command line: no message on standard error"
[ -s "$work/cl.out" ] && bad "command line: something on standard output"
rm -f "$work/cl.err"
OPTS="--build-bin $tools/cancho-build --board-bin $tools/cancho-board --prices $root/eval/prices.json --checker $CANCHO --agent-command x --provider p --model m"
expect "command line: a relative root" "$(cl --root rel/dir $OPTS)" 2
expect "command line: .. in the root" "$(cl --root "$ROOT/../x" $OPTS)" 2
expect "command line: a root with a space or a quote" "$(cl --root "$ROOT/a b" $OPTS)" 2
expect "command line: no board tool" "$(cl --root "$ROOT" --build-bin $tools/cancho-build --prices $root/eval/prices.json --checker $CANCHO --agent-command x --provider p --model m)" 2
expect "command line: an option it does not know" "$(cl --root "$ROOT" $OPTS --key-file /x)" 2
expect "command line: --max-runs 0" "$(cl --root "$ROOT" $OPTS --max-runs 0)" 2
expect "command line: a valid command line ends at the end of input" "$(cl --root "$ROOT" $OPTS)" 0

[ "$fail" = 0 ] && echo "test-mcp: every case held" >&2
exit $fail
