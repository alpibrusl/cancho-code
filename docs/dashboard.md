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

`{"schema":1, "run":{name, brief, stage, plan_valid, provider, model, started_unix, seconds, verdict}, "files":{...}, "metrics":{...}, "truncated":false, "units":[{id, function, column, deps, attempts, regressions, calls, tokens, cost_usd, trail}]}`. Every value the tool could not know is `null`. Units past 256 are dropped and `truncated` is true. There is no timestamp: the same directory gives the same file. A run with a journal adds one more key, `journal` (below); a run without one has no such key, so a board.json made before the journal existed (the demos on the landing page) is still schema 1 and renders as it did.

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

## Read-only

The tool opens the run directory for reading and writes the one output file. It refuses an output path inside the run directory (and `..`, and relative paths: the file capability traps on `..`), and `scripts/test-board.sh` checks that the directory is byte-identical, mtimes included, after a run. Its authority is pinned in `docs/authority-board.json`: `fs_read`, `fs_write`, `args`, `err_write`, `heap`, no network, no process. The pin says `fs_write("")` like the project driver's does: which file may be written is the tool's rule and the gate's check, not something the capability can say, because the path is an argument. The page makes no request but `board.json`, has no form and no way to send anything (the gate greps for both).

Gate: `scripts/test-board.sh` (fixtures in `tests/board/`: a done run, a stuck run with refusal history, one mid-build, one with a regressed unit, one with most files missing, one with no log, an empty directory, junk, and three with a journal) and `scripts/test-board.sh --mutants` (seven broken tools must each turn it red). `tests/reference/board_ref.py` is the oracle.
