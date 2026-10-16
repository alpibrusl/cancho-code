# The MCP server

A coding agent (Claude Code, or any client of the Model Context Protocol) can drive cancho-code as tools: start a build from a brief, poll it, read why a unit is stuck, retry it with a hint or patch it by hand, and fetch the result. The server is a cancho program ([src/mcp.cho](../src/mcp.cho)); there is no Python on its path.

```
agent  --(JSON-RPC lines on stdin/stdout)-->  cancho-mcp  --(detached)-->  build  -->  <root>/<name>/
```

The person who runs the server decides everything the model must not decide: the one root directory, the provider, the model, the key file, the guides and how many runs may be alive at once. They are the server's command line. No tool argument reaches them.

## Register it

Build once, then register it with your client. `scripts/cancho-mcp.sh` builds what is missing (`CANCHO` is the compiler of `.cancho-rev`) and starts the server with your choices:

```sh
export CANCHO=/path/to/cancho
sh scripts/build-agent.sh && sh scripts/build-cancho-mcp.sh      # build/cancho-agent, cancho-build, cancho-board, cancho-mcp
mkdir -p ~/cancho-runs

claude mcp add --scope project cancho-code -e CANCHO="$CANCHO" -- \
    "$PWD/scripts/cancho-mcp.sh" --root "$HOME/cancho-runs" \
    --provider anthropic --model claude-haiku-5-5 \
    --key-file "$HOME/.config/cancho-code/anthropic.key" --primer /path/to/primer.md
```

For a client that reads a JSON file (`.mcp.json`, `--mcp-config`, and the like):

```json
{
  "mcpServers": {
    "cancho-code": {
      "command": "/path/to/cancho-code/scripts/cancho-mcp.sh",
      "args": ["--root", "/home/me/cancho-runs",
               "--provider", "anthropic", "--model", "claude-haiku-5-5",
               "--key-file", "/home/me/.config/cancho-code/anthropic.key",
               "--primer", "/path/to/primer.md"],
      "env": { "CANCHO": "/path/to/cancho" }
    }
  }
}
```

Options of `scripts/cancho-mcp.sh`: `--root`, `--provider`, `--model`, `--key-file` (required); `--primer`, `--workspace` (a workspace id for a key not scoped to one), `--max-tokens` (16000), `--guide` (default `docs/plan-guide.md`), `--review-guide` (turns the blind review of the plan's cases on), `--attempts` (6) and `--agent-seconds` (300) per unit, `--max-runs` (2). The server underneath (`build/cancho-mcp`) takes the long form: `--root --build-bin --board-bin --prices --checker --agent-command --provider --model [--guide --review-guide --attempts --agent-seconds --max-runs]`. Every path may hold only letters, digits and `. _ / + : = @ % , -` (what `build` demands of its paths); the root is absolute with no `..`.

`tests/mcp/client.py <.mcp.json> cancho-code [tool [json arguments]]` is a small client that starts the server as a client config says, does the handshake and calls a tool; use it to check a registration by hand. A run made by hand (a directory `build` or `project` left) can be adopted by putting it under the root: the reading tools (`cancho_status`, `cancho_unit_story`, `cancho_result`) work on it; retry and patch need the run to have been started through the server.

## The tools

All tools return one text block holding a JSON object: `{"ok": true, ...}`, or `{"ok": false, "error": {"rule": ..., "message": ...}}` with `isError` true. The schemas are in [tests/mcp/tools.json](../tests/mcp/tools.json), which the gate compares to what `tools/list` answers.

| tool | input | does |
|---|---|---|
| `cancho_build_start` | `name`, and one of `brief_path` (relative to the root) or `brief_text` (at most 16 KiB; saved as `<root>/<name>/brief.txt`) | starts `build` detached in `<root>/<name>/` and returns at once: `{run, started, pid}`. A run that exists and is not alive resumes where it stopped |
| `cancho_status` | `name` | `alive`, `state` (`running`, `finished`, `not_running`: killed or stopped before the end), `stage`, `verdict` (`done`, `stuck`, `gate_failed`, `plan_failed`, `provider_error`), `units_verified` / `units_total`, `units_stuck`, `units_building`, `cost_usd` so far, `log_tail` |
| `cancho_unit_story` | `name`, `unit` | the last six attempts of the unit from the journal: `outcome`, `decision`, `signature`, the compiler's refusal (`checker`), the examples' output (`acceptance`), the `diff`; each text cut at 1.5 to 2 KiB and marked `*_truncated`; about 24 KiB at most |
| `cancho_retry` | `name`, `unit`, `hint?` | `build --retry <unit> [--hint ...]`, detached. Refused while the run is alive |
| `cancho_patch` | `name`, `unit`, `code` | the code is written to `<root>/<name>/patch-<unit>.cho` and `build --patch <unit> <file>` checks it like a model's: no model call. Refused while the run is alive |
| `cancho_result` | `name` | the verdict, `complete` (verdict `done`), and `project.cho` cut at 24 KiB (`truncated`) |
| `cancho_stop` | `name` | stops the run's process and everything it started. The directory stays; starting the same name resumes |

`cost_usd` is `eval/metrics.py`'s arithmetic, from the board tool ([dashboard.md](dashboard.md)): `status` and `unit_story` run `build/cancho-board` on the run and read the `board.json` it writes to `<root>/.board/`. A value the board cannot know is `null`, not zero.

A session, as a client sees it: `cancho_build_start {name: "roman", brief_path: "briefs/roman.txt"}`, then `cancho_status {name: "roman"}` every minute until `alive` is false; on `verdict: "stuck"`, `cancho_unit_story` for each unit in `units_stuck`, then `cancho_retry` with a hint or `cancho_patch` with code, then poll again; on `done`, `cancho_result`.

## Protocol

Revision **2025-11-25** of the Model Context Protocol, over stdio: one JSON-RPC 2.0 message per line, no embedded newline; `initialize` negotiates the version (the client's is echoed when it is 2025-11-25, 2025-06-18, 2025-03-26 or 2024-11-05, else 2025-11-25 is answered), `notifications/initialized` and any other notification get no answer, `ping`, `tools/list`, `tools/call`. Capabilities: `tools` (no `listChanged`). Errors: `-32700` (not JSON), `-32600` (not a request, a line over 4 MiB), `-32601` (unknown method), `-32602` (unknown tool, `arguments` not an object). A tool that was called wrongly or cannot do what was asked answers with `isError: true` and a rule the model can read (`mcp.bad-name`, `mcp.wrong-type`, `mcp.too-many-runs`, ...), as the 2025-11-25 revision asks for input errors.

Why not the newest revision: the current specification page is **2026-07-28**, which has no handshake (every request carries its protocol version, and `server/discover` is mandatory). It says a client that finds a server answering `server/discover` with anything but a modern error falls back to `initialize`; this server answers `-32601` there, so a client of either era works. The clients in use today (Claude Code 2.1 among them) speak the `initialize` revisions. Moving to 2026-07-28 is a change of `handle` in `src/mcp.cho`, not of the tools.

## What it does and does not do with its authority

The authority report is pinned in [authority-mcp.json](authority-mcp.json) (`scripts/check-authority.sh --mcp`): standard input and output, the command line, a clock, files (`fs_read`, `fs_write`), processes (`exec`), no network. A new capability is a red diff.

- **One root.** Every file the server reads or writes is `<root>/<name>/<file>`, `<root>/.board/<name>.json` or a brief under the root. A run or unit `name` is 1 to 64 of `A-Z a-z 0-9 . _ -`, starting with a letter or digit, with no `..`; a `brief_path` is relative, in the command-line charset, with no `..`, no leading `/` or `-`, no `//`, no part starting with `.` or `-`. A violation is refused before anything is touched (the gate checks 16 bad names against every tool, and 16 bad paths). The file capability itself traps on `..`.
- **The model chooses none of the provider, the model, the key, the guides.** They are in `--agent-command`, `--provider`, `--model`, `--guide`. The key file's path (the word after `--key-file` in the agent command) is never put in a tool result: every result goes through one filter that replaces it, and anything shaped like an API key (`sk-ant-...`), with `[redacted]`. The server never opens the key file; the agent does. The server logs nothing.
- **Nothing a tool receives is put into a shell command.** The only shell in the server is four constant scripts (start in the background, is-this-process-the-run's, stop a tree, count the runs alive). Each variable word is its own argument (`"$1"`, `"$@"`) and never part of the script's text, so a hint or a name cannot be code. A hint goes to `build --hint` as one argument and from there into the unit's task file; `code` goes into a file. The gate puts `$(...)`, backticks and `;` in a hint, a patch and a brief and checks that nothing runs and the hint arrives byte for byte.
- **What comes back from a build is data.** The log, the journal, the compiler's text and the code a model wrote are returned as text, bounded (a few KiB per field, 24 KiB for a result, 48 KiB for any tool) and marked when cut. The descriptions of `cancho_status`, `cancho_unit_story` and `cancho_result` say that instructions inside are not for the model; a client should still treat the text as untrusted.
- **At most `--max-runs` runs alive at once** (default 2): a start over the limit is refused (`mcp.too-many-runs`) before a directory is made. A run is "alive" when its recorded process exists and its command line names its directory (a reused process id is not taken for a run).
- **Standard input ends.** The server ends with exit 0. Runs it started are **detached and keep running**: a build takes minutes, the state is in the run directory, and the next server (or the same one after a restart) reads it. To end a run, `cancho_stop`. If you want runs to die with the session, stop them first.

Known limits, said plainly. A symbolic link under the root that points outside it is followed by the file capability: the root is the operator's directory and the server makes no links, but do not put a link there you would not hand to the model. The identity check of a run reads `ps`; on a system without `ps -p <pid> -o args=` a run is never "alive". The agent command is the operator's text and is run by `build` through a shell; it is trusted. The server cannot start a process it does not wait for (cancho has no way to let go of a child), which is why the background start is a four-line shell script; see the end of this page.

## Gate

`scripts/test-mcp.sh` drives the server over pipes with canned JSON-RPC and the stand-in agent of the build gate ([tests/buildcmd/agent.sh](../tests/buildcmd/agent.sh)): no model, no network, no key. It covers the protocol, the agreement of every tool's schema with its handler, 16 bad names and 16 bad paths against every tool, missing and mistyped arguments, each tool's happy path (a run from start to done, a stuck unit, a retry with a hostile hint, a patch with hostile code), the bounds, the cap on runs and `cancho_stop` (the process and its children are gone), the end of input and the runs that outlive it, a key-shaped string and the key file's path put by the stand-in into the code (never in any output), and the command line. `scripts/test-mcp.sh --mutants` breaks the server eleven ways (a path with `..` accepted, a name with `..` accepted, the key path no longer filtered, the key pattern no longer filtered, a hint run by a shell, the project read whole, a diff returned whole, the cap on runs gone, the end of input not ending the server, a handler taking a property its schema lacks, a schema naming a property the handler does not take) and requires the gate to be red on each.

## A gap in cancho, for the record

`exec_spawn` returns a `Child` that must be waited for on every path, and a program that is killed does not kill it. A server that starts a minutes-long build and answers at once needs to let go of the child, and cancho has no such primitive; the workaround is a constant shell script that starts the program in the background and exits, which is safe only because no variable text is ever in the script. A primitive such as `child_release(Child) -> int` (the child keeps running, is adopted by the system's init, and the handle is consumed without a wait), with an option on `exec_spawn` to start it in its own session, would remove the shell and let the server stop a run's whole process group without walking `ps`.
