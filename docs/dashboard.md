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
| `journal/events.jsonl`, `journal/blobs/*` | the whole story of the run: see [The journal](#the-journal) |
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

`{"schema":1, "run":{name, brief, stage, plan_valid, provider, model, started_unix, seconds, verdict}, "files":{...}, "metrics":{...}, "truncated":false, "units":[{id, function, file, column, deps, attempts, regressions, calls, tokens, cost_usd, trail}]}`. `file` is the module file of the unit ([multi-file.md](multi-file.md)): it is there only for a plan that has `files` or a unit that names one (`project.cho` for a unit that names none), so the board of a single-file run has no such key and is as it was, and a reader of schema 1 that ignores unknown keys is not broken; the unit being built is read from `<file>.trail.jsonl`. Every value the tool could not know is `null`. Units past 256 are dropped and `truncated` is true. There is no timestamp: the same directory gives the same file. A run with a journal adds one more key, `journal` (below); a run without one has no such key, so a board.json made before the journal existed (the demos on the landing page) is still schema 1 and renders as it did.

## The journal

A run made with the journal writes `<run dir>/journal/events.jsonl` (one JSON object per line, in order, each with `t_ms` and `kind`: `run_start`, `plan_call`, `plan_review`, `plan_final`, `unit_start`, `attempt`, `sweep`, `unit_end`, `run_end`) and the big texts as files under `journal/blobs/` (`primer.txt` once; an event says `"primer": true`). Any field may be missing. This is the read side: what the board makes of it.

**How the page gets the blobs.** The page and the run directory are different places, so the tool inlines a bounded excerpt of every blob an event names (`prompt`, `reply`, `code`, `feedback`, `checker`, `acceptance`, `diff`, `stderr`, `blob`, `plan`, and `primer.txt`) into `board.json`; the page then needs nothing else, works from a file picker, and the tool stays read-only with one output file. The bounds: 32 KiB of text per blob (cut at a character boundary, `truncated: true`, and the page says where the full file is), 2 MiB of blob text in all (a blob past that is `{"omitted": true}`), 20,000 events, no event line over 64 KiB. A name with a slash, backslash or `..` is never read.

```
"journal": {
  "events":  [ ...the event objects, verbatim, in file order... ],
  "costs":   [ ...one per event: the call's cost in dollars at the prices file, null when the event has no tokens or there is no price... ],
  "blobs":   { "<name>": {"bytes": 3120, "truncated": false, "text": "..."} | null (the file is not there) | {"omitted": true} },
  "skipped_lines": 0,       // lines that were not a JSON object (and are left out)
  "partial_tail": false,    // the last line has no newline and is not complete: the run was killed while writing it
  "events_dropped": 0, "blobs_omitted": 0,
  "limits": {"blob_bytes": 32768, "total_bytes": 2097152}
}
```

The key is absent when there is no `events.jsonl`. Size: a synthetic run of 12 units with 3 attempts each, 7 texts per attempt (about 6 KB for the prompt) and a 24 KB primer gives a 0.7 MB `board.json`; the cap is about 2.3 MiB plus the events. A journal is read up to 8 MiB.

**In the page**
- **Details** on a unit card (or a line of the timeline) opens a panel: a drawer on a desktop, the whole screen on a phone; `Escape`, the Close button or a click outside closes it, focus stays inside while it is open and returns to the card. It shows the unit's state, its dependencies (each opens that unit), its total cost, and every attempt in order: the outcome, decision, time, stop reason, tokens and cost of that call, the diff against the previous attempt (unified, `+` green and `-` red, the signs kept in the text), the compiler's refusal in full, the checker and test output, the code, the reply and the prompt, with a collapsed "primer (same for every call)" under the prompt. Attempts are numbered from 0 as the journal numbers them.
- **Story** (a tab, shown only when there is a journal): the brief, model and verdict; the plan stage, round by round (what was asked, what came back, the refusals fed back to the next round), the review (kept, each dropped case with its reason) and the plan that was used; then the timeline of every event in order, each line opening the same detail (a unit event opens the unit at that attempt).
- **Not recorded**: a field, blob or file the journal lacks is said so ("Not recorded: ...", "the file journal/blobs/x is missing", "left out of board.json to keep it small"), never shown empty or as zero. A run with no journal still opens a panel from its trail file and says so. A half-written last line, unreadable lines, a run with no end, dropped events and omitted blobs are each stated on the Story.
- **Continue this unit**: on the panel of a **stuck** unit, the command to try it again with a hint of your own (`build <checker> <brief> <workdir> <agent-command> --provider P --model M --retry <unit> --hint "..."`, [build.md](build.md#continuing-a-stuck-unit)), as text with a Copy button. The brief, provider and model come from `board.json`'s `run` when they are plain words; the checker, the work directory, the agent command and the hint are placeholders, because the board cannot know them. The board runs nothing: it is text to copy. An attempt the person made shows as such ("A person's own code", "The person's hint for this attempt").

Gate for this part: fixtures `continued` (a unit retried with a hint and then patched by a person, still stuck: the events carry `hint` and `human_patch`, `build.json` names the unit), `journal` (a retry with a long refusal and a diff, a plan stage with a dropped case, costs), `journal-killed` (last event half written, a missing plan blob), `journal-gaps` (fields missing, a missing blob, an unsafe blob name, a line that is not an event, a missing primer), the runs with no journal (the old fixtures: no `journal` key), and a large one made at test time (a blob cut inside a two-byte character, the 2 MiB budget exceeded). The mutations: a blob inlined whole, events out of order, a half-written line counted as a bad line, a `..` name read, plus the output-in-run-directory one.

## The graph and the timeline

Two more views next to Board and Story, drawn from what `board.json` already holds: **no new field**, so a `board.json` made before them (the demos on the landing page) renders as it did. The logic is a block of pure functions in `board.html` (between the `graph-logic` markers); `scripts/test-board.sh` runs it under node.

**Graph** (always there: it needs only the plan's dependencies and the columns). The units as a layered DAG, left to right: a unit's layer is the longest chain of dependencies below it, a root is in layer 0. An arrow from A to B means B needs A. Each node is coloured by its column (the board's colours, and the column's name is written in it), labelled with the unit id, function, attempts and cost, and the agent time when the trails have it; with a journal it also says in what order the run built the units (`#3`). A node and a card also show the unit's `file` when the board has one, and the detail panel has it among the unit's chips; the journal's `unit_start` line in the Story says "in <file>". A click or Enter on a node opens the same detail panel as a card. The **critical path** is drawn thick, with a ring on its nodes: the longest chain **by agent time** (the sum of each unit's attempts' `agent_ms` in its trail) when every unit has one recorded (a unit nobody has built counts 0), else **by number of units**; the legend and the summary line say which. The graph scrolls inside its frame (a plan of 256 units, the tool's cap, measured 4,286 px wide for a random layered one and 18,450 px tall for 256 independent units; the page itself never scrolls sideways), nodes are focusable (`role=button`), and "The graph as a list" under it is the same graph as a nested list ("unit: depends on ..."). A plan with a cycle, a dependency on a unit that is not in the plan or a repeated id is not refused here (the plan check does that): the page says "the dependencies of this plan are not a DAG", names what is wrong, draws what it can place and draws no critical path. A board with no `plan.json` says so instead of drawing.

**Timeline** (only with a journal). One row per unit in the order they ran, the plan stage first. A bar is one model call (plan) or one attempt: green when it verified (written, for the plan), red with stripes when it was refused, failed or rejected, grey when the outcome is not recorded; a click opens the attempt. The pale band behind is the unit from `unit_start` to `unit_end`, the hatched strip the sweep after it. `t_ms` is when an event was written, after the call, so a call of `ms` ran from `t_ms - ms` to `t_ms`. A call with no `ms` is drawn as a point. Gaps are empty track. When a resumed run is more than two minutes after the one before, the pause is taken out of the axis and marked. Below it, the estimate, in one line: `agent time total X s; critical path Y s; units run one after another today, so parallel units could save at most X-Y s here.` X is the sum of every attempt's `ms` in the journal, Y the longest chain of the plan weighed by each unit's attempt time. It is an estimate and an upper bound, not a promise: checks, sweeps and any waiting are not in it. If an attempt has no `ms`, there is no plan, or the plan is not a DAG, the line says "not recorded" (or no critical path) instead of a number. Units are built one at a time today; the page offers no way to change that.

Measured on a real run (`sortedmap`, haiku, 8 units, stuck at `get`): agent time 37.9 s, critical path 14.5 s (`mid`, `lower_bound`, `get`), so at most 23.4 s of agent time could overlap; the run's units took 44.8 s from the first unit start to the last unit end, and the plan stage before it took about 81 s.

## Read-only

The tool opens the run directory for reading and writes the one output file. It refuses an output path inside the run directory (and `..`, and relative paths: the file capability traps on `..`), and `scripts/test-board.sh` checks that the directory is byte-identical, mtimes included, after a run. Its authority is pinned in `docs/authority-board.json`: `fs_read`, `fs_write`, `args`, `err_write`, `heap`, no network, no process. The pin says `fs_write("")` like the project driver's does: which file may be written is the tool's rule and the gate's check, not something the capability can say, because the path is an argument. The page makes no request but `board.json`, has no form and no way to send anything (the gate greps for both).

Gate: `scripts/test-board.sh` (fixtures in `tests/board/`: a done run, a stuck run with refusal history, one mid-build, one with a regressed unit, one with most files missing, one with no log, an empty directory, junk, three with a journal, and the graph fixtures below) and `scripts/test-board.sh --mutants` (seven broken tools and, with node, seven broken page functions must each turn it red). `tests/reference/board_ref.py` is the oracle, and with `--layout` the oracle of the graph and the estimate.

The graph and timeline gate: fixtures `graph-diamond`, `graph-chain`, `graph-wide` (eight independent units), `graph-big` (34 units), `graph-unknown`, `graph-cycle`, `graph-stuck`, `graph-journal` (a diamond with a retry, a refused plan round and sweeps) and `graph-resumed` (a journal of two runs an hour apart); plans of 1 to 256 units made at test time (a chain, 256 independent units, a mesh, a random one, and 300 units of which the tool keeps 256); odd plans (a self-dependency, a cycle of 256, repeated ids, `__proto__` as a unit id, dependencies that are not lists) and a hostile journal. The page's own functions give the layers, the critical path, the placement, the rows and the estimate; they are compared with `board_ref.py --layout` (a second implementation) on every board, the demos included, and with hand-written expectations (`tests/board/expected/page-logic.json`). The page-logic mutations: a unit put in the layer of its dependency, the shortest chain taken as critical, a bar that starts where it ends, every bar opening attempt 0, an unknown dependency not told apart, a cycle drawn as a plan, a saving that grows with the critical path. Without node on PATH the step is skipped and says so (the CI workflow does not install node and relies on the runner image having it: check the log of the gate for the note).
