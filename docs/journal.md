# The journal

A run leaves a journal from which the whole story can be told and shown: what the planner was asked and what it answered, which cases the review dropped and why, and for every unit every attempt: what the model was asked, what it wrote, what the compiler said about it in full, what the examples said, and what changed from the attempt before.

`build` and `project` write it in the work directory, always:

```
<workdir>/journal/
  events.jsonl     one JSON object per line, in the order things happened
  blobs/           the texts the events name: prompts, replies, code, diffs, refusals
```

The other files of a run (`state.txt`, `trail-<id>.jsonl`, `usage.jsonl`, `raw.txt`, `run.log`, `build.json`) are as they were. The journal does not replace them; it holds what they could not: the texts. Nothing in it is a credential: the key and the request headers never reach it (the gate greps the journal for the key it used).

## Rules

- **Append-only, whole lines.** An event is added by writing the file to a temporary name and renaming it over `events.jsonl`, so a run killed at any moment leaves the journal as of the last whole line. The file stops growing at 2 MiB (the events are a few hundred bytes; the bulk is in the blobs); a run that fills it keeps running unrecorded.
- **Every event has `t_ms`** (Unix milliseconds) **and `kind`.** Events are in the order they happened and `t_ms` never goes back.
- **A missing field means "not recorded", never an error.** An agent that leaves no prompt, a unit without a diff: the field is not there. Readers treat every field but `t_ms` and `kind` as optional.
- **Blobs are file names under `journal/blobs/`**, none over 256 KiB; a longer text is cut and ends with `[... cut here: a journal blob holds at most 262144 bytes ...]`.
- **The primer is stored once.** The language primer (13k tokens, identical on every call) is `blobs/primer.txt`; the prompt blobs hold only what varies from call to call, and an event says `"primer": true` when the call carried it.
- **A resumed run appends.** Its `run_start` follows the last event of the killed one.

## The events

| `kind` | when | fields |
|---|---|---|
| `run_start` | a run begins | `brief` (path as given), `provider`, `model`, `options` {`review`, `rounds`, `attempts`, `agent_seconds`, `plan_seconds`}. A `project` run by hand has only `options` {`review`, `attempts`, `agent_seconds`}. |
| `plan_call` | each model call of the plan stage: the plan's, and the review's | `round`, `sample` (1; the review's retry is 2), `tokens` {`in`, `out`, `thinking`, `cache_write`, `cache_read`}, `ms`, `stop`, `outcome` (`written`, `rejected`, `cut_off`, `no_plan`, `needs_input`; the review's: `reviewed`, `review_rejected`, `review_failed`; `unreachable`, `api_error`), `prompt`, `reply` (blobs), `primer`, `errors` (what the plan check or the cases refused, one string per line, to be fed back next round) |
| `plan_review` | after a review answered | `round`, `kept` and `of` (cases), `dropped` [{`unit`, `case`, `reason`}] (`reason` is "planner X reviewer Y"), `error` (the refusal, when the review refused the plan), `blob` (the review's whole report) |
| `plan_final` | the plan the build goes on with is known | `valid`, `units`, `plan` (blob; a plan reused from an earlier run is recorded too) |
| `unit_start` | a unit is handed to the agent | `unit`, `function`, `deps` |
| `attempt` | each attempt of a unit, after its check | `unit`, `n` (0-based), `outcome`, `decision`, `signature`, `ms`, `exit`, `tokens`, `stop`, `samples`, `primer`, and blobs: `prompt`, `reply`, `stderr`, `feedback`, `code`, `checker`, `acceptance`, `diff` |
| `unit_end` | the unit is done with | `unit`, `state` (`verified`, `stuck`, `unavailable`), `attempts` |
| `sweep` | after a unit verified (or at the start of a resumed run), the earlier verified units were re-checked | `after_unit` (empty at a resume), `held` [unit...], `regressed` [unit...] |
| `run_end` | the run ends | `verdict` (the word of `build.md`), `exit`, `seconds` |

An `attempt` is one turn of the agent and the check that followed:

- `outcome`: `verified`, `refused` (the compiler refused the code), `acceptance_failed` (it compiled and its examples or scenarios failed), `agent_failed` (the agent did not answer: `exit` says how it ended), `defect`, `outage`.
- `decision`: what the loop did next: `retry`, `verified`, `signature` (the same refusal twice, the loop stops), `ceiling`, `defect`, `provider`, `agent_exit`, `agent_timeout`, `agent_signal`, `agent_output`, `agent_failed`, `regressed`.
- `signature`: the short form the stop rule compares. The whole refusal is `checker`.
- `ms` is the wall time of the agent's turn; `tokens`, `stop` and `samples` are the agent's own (several samples in one turn when a reply had no program).
- `feedback` is what the agent was shown at the start of the turn (the checker's answer on the file as it stood, and the acceptance output of the attempt before); `checker` is the checker's whole answer after the turn; `acceptance` the acceptance command's whole output when it ran and failed.
- `code` is `project.cho` after the turn. `diff` is a unified diff of it against the code of the attempt before (the file as it stood before the unit, for attempt 0): `patch` applied to the previous code gives this code.

## The agent's sidecars

The driver knows the unit and the attempt; the agent knows the call. So the agent leaves what it knows beside the project file, the way `.feedback` and `.task` work, and the driver turns it into the `attempt` event. The driver makes the directory `<project.cho>.call/` and clears its files before each turn; an agent writes into it when it can and a stand-in agent need not:

| file | what |
|---|---|
| `prompt.txt` | the message sent after the primer, exactly |
| `reply.txt` | the raw reply; a later sample of the same turn follows a line `=== sample K ===` |
| `meta.json` | `{"samples":1,"tokens":{"in":..,"out":..,"thinking":..,"cache_write":..,"cache_read":..},"ms":..,"stop":"end_turn","outcome":"written","primer":true}`, totals over the samples of the turn |
| `primer.txt` | the primer; the driver keeps the first as `blobs/primer.txt` |
| `stderr.txt` | the agent's standard error, written by the driver itself (the agent command runs with `2>`), so any agent has one |

The plan stage has no unit and no attempt, so the plan agent (`--mode plan`) writes its own events: `build` gives it `--journal <workdir>/journal`, and it adds a `plan_call` per model call and a `plan_review` per review, with their blobs. Without `--journal` it records nothing.

## An example

A two-unit project; `to_roman` is refused once. The events (blob names shortened, `t_ms` left out):

```
{"kind":"run_start","brief":"/runs/roman/brief.txt","provider":"anthropic","model":"claude-haiku-5-5","options":{"review":true,"rounds":3,"attempts":6,"agent_seconds":300,"plan_seconds":900}}
{"kind":"plan_call","round":1,"sample":1,"tokens":{"in":3112,"out":2650,"thinking":0,"cache_write":0,"cache_read":13350},"ms":21400,"stop":"end_turn","outcome":"written","prompt":"plan-r1-s1-prompt.txt","reply":"plan-r1-s1-reply.txt","primer":true,"errors":[]}
{"kind":"plan_call","round":1,"sample":1,"tokens":{"in":1840,"out":410,"thinking":0,"cache_write":0,"cache_read":0},"ms":4100,"stop":"end_turn","outcome":"reviewed","prompt":"plan-r1-s1-prompt.txt","reply":"plan-r1-s1-reply.txt","primer":true,"errors":[]}
{"kind":"plan_review","round":1,"kept":13,"of":14,"dropped":[{"unit":"roman_value","case":4,"reason":"planner 4 reviewer 6"}],"blob":"plan-r1-review.txt"}
{"kind":"plan_final","valid":true,"units":2,"plan":"plan-1792068490000.json"}
{"kind":"unit_start","unit":"roman_value","function":"roman_value","deps":[]}
{"kind":"attempt","unit":"roman_value","n":0,"outcome":"verified","decision":"verified","signature":"","ms":5230,"exit":0,"tokens":{...},"stop":"end_turn","prompt":"roman_value-a0-prompt.txt","reply":"roman_value-a0-reply.txt","code":"roman_value-a0-code.cho","diff":"roman_value-a0-diff.txt","checker":"roman_value-a0-checker.json","acceptance":"roman_value-a0-acceptance.txt",...}
{"kind":"unit_end","unit":"roman_value","state":"verified","attempts":1}
{"kind":"unit_start","unit":"to_roman","function":"to_roman","deps":["roman_value"]}
{"kind":"attempt","unit":"to_roman","n":0,"outcome":"refused","decision":"retry","signature":"borrow-escape:...","ms":8120,"checker":"to_roman-a0-checker.json","code":"to_roman-a0-code.cho",...}
{"kind":"attempt","unit":"to_roman","n":1,"outcome":"verified","decision":"verified","signature":"","feedback":"to_roman-a1-feedback.txt","diff":"to_roman-a1-diff.txt",...}
{"kind":"unit_end","unit":"to_roman","state":"verified","attempts":2}
{"kind":"sweep","after_unit":"to_roman","held":["roman_value"],"regressed":[]}
{"kind":"run_end","verdict":"done","exit":0,"seconds":96}
```

The story of the retry is `to_roman-a0-checker.json` (what the compiler said, whole), `to_roman-a1-feedback.txt` (what the next attempt was shown: the same text), `to_roman-a1-prompt.txt` and `-reply.txt` (what the model was asked and answered), and `to_roman-a1-diff.txt` (what it changed).

## Showing it

Everything a viewer needs is in these two places: `events.jsonl` is a timeline; each event's blobs are its detail. The board (docs/dashboard.md) reads exactly this layout.

## Gate

`scripts/test-journal.sh` runs `build` against a stand-in agent that leaves sidecars: the events in order, every attempt, the compiler's whole refusal (the compiler is run again on the recorded code and the answers compared), the diff (`patch` rebuilds the code), the blob cap, the stuck and provider cases, a run killed with SIGKILL. `scripts/test-planner.sh` checks the plan stage's events (the prompt blob plus the primer is the request's prompt), `scripts/test-agent-native.sh` the sidecars of a unit call and that the key is nowhere in them.
