# The dashboard

docs/parity.md P12. A read-only view of a run: a board of the plan's units and the run's numbers. Two parts, and no server: a cancho program that turns a run directory into one file, and one static page that draws it.

```sh
scripts/cancho-board.sh <run dir>                  # writes docs/board.json (builds the tool the first time: CANCHO= the compiler)
python3 -m http.server -d docs 8000                # or any static server; then open http://localhost:8000/board.html
```

The page also works from `file://`: browsers do not let it fetch `board.json` there, so use **Open board.json** (or drop the file on the page). `scripts/cancho-board.sh <run dir> /some/where/board.json [prices.json]` writes elsewhere (never inside the run directory: the tool refuses). **Reload** reads `board.json` again, and "refresh every 5 s" does it on a timer, for a run in progress. Phone width, light and dark follow the device.

## What it reads

The tool takes a run directory as the existing tools leave it and never writes there:

| file | gives |
|---|---|
| `plan.json` (else the path in `run.json`'s `plan`) | the units, their function names and dependencies, their order |
| `run.log` | each unit's last event (`building`, `verified`, `failed`, `skipped`, `regressed`...) and the run's verdict |
| `state.txt` | the units verified (what a resumed run keeps) |
| `trail-<unit>.jsonl` | each attempt: outcome, refusal signature, decision, time; for the unit being built, `project.cho.trail.jsonl` |
| `usage.jsonl` | tokens and calls per unit (a line's `task` starts `UNIT: <id>`) |
| `run.json`, `build.json` | provider, model, seconds; `build.json` (made by the build command, optional) also brief, stage, `plan_valid`, `started_unix` |
| `audit.txt` | the last `TOTAL n/m` |
| prices file (3rd argument, default `eval/prices.json`) | the price of the run's model, to turn tokens into money |

**A missing or unreadable file is unknown, not an error and not zero**: the page shows "unknown", and `board.json`'s `files` says which files were there. A line that does not parse is skipped.

## The columns

- **Waiting**: its dependencies are not verified yet, or it was skipped because one failed.
- **Building**: the unit being built now (the last line for it in `run.log` is `building`), with the attempts so far.
- **Verified**: its examples pass and still did at the last sweep. A unit that regressed and was rebuilt is here, with `regressed 1x` on the card.
- **Stuck**: it failed (the attempts ran out, the same refusal came twice, or the agent was unavailable). The card lists every attempt: outcome, the refusal signature the loop compared, what it decided.
- **Regressed**: it had verified, a later unit broke it, and it has not been rebuilt: back on the board.
- **Unknown**: only when there is no `run.log` and nothing else says (a run directory with a plan and a state but no log).

## The numbers

Cost, tokens, thinking share and token efficiency are [eval/metrics.py](../eval/metrics.py)'s definitions, reproduced in cancho with whole numbers (`scripts/test-board.sh` compares the two); cost is rounded to millionths of a dollar per unit and summed, as metrics.py does.

- **Cost**: tokens times the price per million, over every call (retries included). Prices change: the file is an argument so the number can be argued with, and its date is in `eval/prices.json`.
- **Token efficiency**: of all output tokens, the share that was both kept (the last written reply of a verified unit) and new work (not the file repeated).
- **Thinking share**: thinking tokens over output tokens; unknown for runs that did not record thinking.
- **Cache read share**: cache-read tokens over all input tokens (input, cache write, cache read). Not in metrics.py.
- **Units verified / total**: cards in Verified over all cards. metrics.py counts only units with a verdict line, so its total can be smaller.
- **Audit**: from `audit.txt`.

## `board.json`

`{"schema":1, "run":{name, brief, stage, plan_valid, provider, model, started_unix, seconds, verdict}, "files":{...}, "metrics":{...}, "truncated":false, "units":[{id, function, column, deps, attempts, regressions, calls, tokens, cost_usd, trail}]}`. Every value the tool could not know is `null`. Units past 256 are dropped and `truncated` is true. There is no timestamp: the same directory gives the same file.

## Read-only

The tool opens the run directory for reading and writes the one output file. It refuses an output path inside the run directory (and `..`, and relative paths: the file capability traps on `..`), and `scripts/test-board.sh` checks that the directory is byte-identical, mtimes included, after a run. Its authority is pinned in `docs/authority-board.json`: `fs_read`, `fs_write`, `args`, `err_write`, `heap`, no network, no process. The pin says `fs_write("")` like the project driver's does: which file may be written is the tool's rule and the gate's check, not something the capability can say, because the path is an argument. The page makes no request but `board.json`, has no form and no way to send anything (the gate greps for both).

Gate: `scripts/test-board.sh` (fixtures in `tests/board/`: a done run, a stuck run with refusal history, one mid-build, one with a regressed unit, one with most files missing, one with no log, an empty directory, junk) and `scripts/test-board.sh --mutants` (three broken tools must each turn it red). `tests/reference/board_ref.py` is the oracle.
