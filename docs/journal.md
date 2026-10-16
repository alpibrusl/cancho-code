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
| `plan_call` | each model call of the plan stage: the plan's, and the review's (its blobs are `review-r<round>-s<sample>-*`, and it carries no primer) | `round`, `sample` (1; the review's retry is 2), `tokens` {`in`, `out`, `thinking`, `cache_write`, `cache_read`}, `ms`, `stop`, `outcome` (`written`, `rejected`, `cut_off`, `no_plan`, `needs_input`; the review's: `reviewed`, `review_rejected`, `review_failed`; `unreachable`, `api_error`), `prompt`, `reply` (blobs), `primer`, `errors` (what the plan check or the cases refused, one string per line, to be fed back next round) |
| `plan_review` | after a review answered | `round`, `kept` and `of` (cases), `dropped` [{`unit`, `case`, `reason`}] (`reason` is "planner X reviewer Y"), `error` (the refusal, when the review refused the plan), `blob` (the review's whole report) |
| `plan_final` | the plan the build goes on with is known | `valid`, `units`, `plan` (blob; a plan reused from an earlier run is recorded too) |
| `unit_start` | a unit is handed to the agent | `unit`, `function`, `deps`, `retry` (true when the person re-opened it with `--retry`), `patch` (true when the person applied code with `--patch`) |
| `attempt` | each attempt of a unit, after its check | `unit`, `n` (0-based), `outcome`, `decision`, `signature`, `ms`, `hint`, `memory`, `exit`, `tokens`, `stop`, `samples`, `primer`, and blobs: `prompt`, `reply`, `stderr`, `feedback`, `code`, `checker`, `acceptance`, `diff` |
| `unit_end` | the unit is done with | `unit`, `state` (`verified`, `stuck`, `unavailable`), `attempts` |
| `sweep` | after a unit verified (or at the start of a resumed run), the earlier verified units were re-checked | `after_unit` (empty at a resume), `held` [unit...], `regressed` [unit...] |
| `run_end` | the run ends | `verdict` (the word of `build.md`), `exit`, `seconds` |

An `attempt` is one turn of the agent and the check that followed:

- `outcome`: `verified`, `refused` (the compiler refused the code), `acceptance_failed` (it compiled and its examples or scenarios failed), `agent_failed` (the agent did not answer: `exit` says how it ended; with a `signature` `agent:gave-up:cut-off|no-program|splice` it reached the model and gave up, and the loop retries it like a refusal; without one, its `decision` is `agent_exit`, `agent_timeout`, ...: it is away, a wait), `defect`, `outage`, `human_patch` (the person's own code, `--patch`: no model was asked, so no `prompt`, `reply`, `stderr`, `feedback` or `tokens`; `code` is the project file with their code in it, `decision` says whether it verified (`verified`) or not (`ceiling`), `signature` why; a patch the splice could not even put in the file has `signature` `splice` and its report as `feedback`).
- `decision`: what the loop did next: `retry`, `verified`, `signature` (the same refusal twice, the loop stops), `ceiling`, `defect`, `provider`, `agent_exit`, `agent_timeout`, `agent_signal`, `agent_output`, `agent_failed`, `regressed`.
- `hint`: on the attempts of a unit the person re-opened with `--retry <unit> --hint "..."`, their text (the prompt blob of the attempt holds it too). `n` goes on from the attempts before the retry, so the earlier attempts and their blobs stay and the numbers do not repeat.
- `memory`: on the attempts of a run given `--memory <dir>` ([memory.md](memory.md)), what the agent's memory added to that attempt's prompt: an array of `{"id", "text"}`, one per lesson (id `L` and eight hex digits: the lesson's class) and one per fact of the person's own (`F1`, `F2`, ...), the text as it stands in the prompt. Absent when nothing was added, which is every attempt of a run without `--memory`. The prompt blob shows the same text; the field is what lets a reader (and the miner, which counts a lesson that was recalled and refused again against it) know which attempts carried which lesson. The board can show it later: it is one more optional field of the same events.
- `signature`: the short form the stop rule compares. The whole refusal is `checker`.
- `ms` is the wall time of the agent's turn; `tokens`, `stop` and `samples` are the agent's own (several samples in one turn when a reply had no program).
- `feedback` is what the agent was shown at the start of the turn (the checker's answer on the file as it stood, and the acceptance output of the attempt before); `checker` is the checker's whole answer after the turn; `acceptance` the acceptance command's whole output when it ran and failed.
- `code` is `project.cho` after the turn. `diff` is a unified diff of it against the code of the attempt before (the file as it stood before the unit, for attempt 0): `patch` applied to the previous code gives this code.

## The agent's sidecars

The driver knows the unit and the attempt; the agent knows the call. So the agent leaves what it knows beside the project file, the way `.feedback` and `.task` work, and the driver turns it into the `attempt` event. The driver makes the directory `<project.cho>.call/` and clears its files before each turn. The agent's standard error is not a sidecar: the project driver already runs the agent with `2>` to `<project.cho>.agent.err` (docs/project.md), and the attempt's `stderr` blob is a bounded copy of that file as it stands after the turn, so any agent has one; an agent writes into it when it can and a stand-in agent need not:

| file | what |
|---|---|
| `prompt.txt` | the message sent after the primer, exactly |
| `reply.txt` | the raw reply; a later sample of the same turn follows a line `=== sample K ===` |
| `meta.json` | `{"samples":1,"tokens":{"in":..,"out":..,"thinking":..,"cache_write":..,"cache_read":..},"ms":..,"stop":"end_turn","outcome":"written","primer":true}`, totals over the samples of the turn |
| `primer.txt` | the primer; the driver keeps the first as `blobs/primer.txt` |
| `memory.json` | with `--memory`, an array of `{"id","text"}`: the lessons and facts the memory added to the prompt ([memory.md](memory.md)); the driver copies it into the attempt's `memory` field, and leaves the field out when the file is missing or not an array |

The plan stage has no unit and no attempt, so the plan agent (`--mode plan`) writes its own events: `build` gives it `--journal <workdir>/journal`, and it adds a `plan_call` per model call and a `plan_review` per review, with their blobs. Without `--journal` it records nothing.

## An example

A real run (`sortedmap`, claude-haiku-5-5; trimmed: `t_ms`, most tokens and the other six units left out). The plan is refused once, written on the second round, reviewed; the unit `get` is refused by its own tests twice and the run ends `stuck`:

```
{"kind":"run_start","brief":"/runs/sortedmap/brief.txt","provider":"anthropic","model":"claude-haiku-5-5","options":{"review":true,"rounds":3,"attempts":6,"agent_seconds":300,"plan_seconds":900}}
{"kind":"plan_call","round":1,"sample":1,"tokens":{"in":4530,"out":13115,"thinking":5897,"cache_write":0,"cache_read":13374},"ms":48396,"stop":"end_turn","outcome":"rejected","primer":true,"prompt":"plan-r1-s1-prompt.txt","reply":"plan-r1-s1-reply.txt","errors":["[PLAN_ERROR]\tno-example\tlower_bound\tthe unit has no example; give at least one `CALL == EXPECTED`", "..."]}
{"kind":"plan_call","round":2,"sample":1,"tokens":{...},"ms":30946,"stop":"end_turn","outcome":"written","primer":true,"prompt":"plan-r2-s1-prompt.txt","reply":"plan-r2-s1-reply.txt","errors":[]}
{"kind":"plan_call","round":2,"sample":1,"tokens":{...},"ms":1554,"stop":"end_turn","outcome":"reviewed","prompt":"review-r2-s1-prompt.txt","reply":"review-r2-s1-reply.txt","errors":[]}
{"kind":"plan_review","round":2,"kept":5,"of":5,"dropped":[],"blob":"plan-r2-review.txt"}
{"kind":"plan_final","valid":true,"units":8,"plan":"plan-1792097306798.json"}
{"kind":"unit_start","unit":"get","function":"sm_get","deps":["lower_bound"]}
{"kind":"attempt","unit":"get","n":0,"outcome":"acceptance_failed","decision":"retry","signature":"acceptance:/runs/.../tests-get.cho:3:1: erro","ms":3120,"exit":0,"tokens":{...},"stop":"end_turn","samples":1,"primer":true,"prompt":"get-a0-prompt.txt","reply":"get-a0-reply.txt","stderr":"get-a0-stderr.txt","feedback":"get-a0-feedback.txt","code":"get-a0-code.cho","checker":"get-a0-checker.json","acceptance":"get-a0-acceptance.txt","diff":"get-a0-diff.txt"}
{"kind":"attempt","unit":"get","n":1,"outcome":"acceptance_failed","decision":"signature","signature":"acceptance:/runs/.../tests-get.cho:3:1: erro","ms":6314,...,"feedback":"get-a1-feedback.txt","code":"get-a1-code.cho","diff":"get-a1-diff.txt",...}
{"kind":"unit_end","unit":"get","state":"stuck","attempts":2}
{"kind":"run_end","verdict":"stuck","exit":1,"seconds":126}
```

The story of the retry is in the blobs. `get-a0-acceptance.txt` is what the examples said about the first attempt (here the unit's own test file did not compile: "`option` is already bound to another import here"); `get-a1-feedback.txt` is what the second attempt was shown (the checker's clean answer, then that text); `get-a1-prompt.txt` and `get-a1-reply.txt` are what the model was asked and answered; `get-a1-code.cho` is its code and `get-a1-diff.txt` what it changed from the first attempt:

```
--- a0
+++ a1
@@ -1,5 +1,6 @@
 edition 7;
 import std.option;
+import std.option as opt;
@@ -19,12 +20,12 @@
-fn sm_get[&k, &v](...) -> [] option.Option[int] {
+fn sm_get[&k, &v](...) -> [] opt.Option[int] {
```

A run that fails for a reason the verdict hides is told the same way (this one is why the exit codes of the agent are documented, [project.md](project.md#the-agents-exit-codes): the unit now ends `stuck`, with the signature `agent:gave-up:cut-off`, and the second turn is another attempt): another run's unit `parse` ended `provider_error`, and its single `attempt` event said `"outcome":"agent_failed"`, `"exit":1`, `"stop":"max_tokens"`, `"tokens":{"out":48000,...}`, with `parse-a0-stderr.txt` holding three lines "a sample was cut off by the bound": the model was cut off three times, the API was never down.

## Showing it

Everything a viewer needs is in these two places: `events.jsonl` is a timeline; each event's blobs are its detail. The board (docs/dashboard.md) reads exactly this layout.

## Gate

`scripts/test-journal.sh` runs `build` against a stand-in agent that leaves sidecars: the events in order, every attempt, the compiler's whole refusal (the compiler is run again on the recorded code and the answers compared), the diff (`patch` rebuilds the code), the blob cap, the stuck and provider cases, a run killed with SIGKILL. `scripts/test-planner.sh` checks the plan stage's events (the prompt blob plus the primer is the request's prompt), `scripts/test-agent-native.sh` the sidecars of a unit call and that the key is nowhere in them.
