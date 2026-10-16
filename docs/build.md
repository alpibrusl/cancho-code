# From a brief to a verified build

`build` is one command, written in cancho, that chains the tools that used to be run by hand: the agent writes a **plan** from the brief (`--mode plan`, with its own retry rounds and the optional blind review of the cases), the **plan check** accepts or refuses it, the **project driver** ([docs/project.md](project.md)) builds it unit by unit, and the run ends with one machine-readable verdict and an exit code.

```
build <checker> <brief.txt> <workdir> <agent-command> --provider <p> --model <m> [options]
```

`checker` is the absolute path of the cancho compiler; `workdir` must exist. `agent-command` is the agent as a shell command *without* provider and model (for example `scripts/cancho-agent.sh --key-file ... --primer ...`): `build` adds `--provider`, `--model` and `--usage-log <workdir>/usage.jsonl` for every call. There is no default provider and no default model; the key comes from the file the agent command names, never from the environment or an argument.

| option | |
|---|---|
| `--provider`, `--model` | required |
| `--guide <file>` | how to write a plan ([plan-guide.md](plan-guide.md)); required unless the work directory already holds a valid `plan.json` |
| `--review on --review-guide <file>` | the blind re-derivation of every case ([review-guide.md](review-guide.md)) |
| `--contract <file>` | exact public signatures the plan must keep |
| `--rounds N` | the plan agent's own retry rounds (3). A round whose reply was cut off by the output bound (a model that thinks first can use all of it before the first byte) is asked again with the bound doubled, at most 32000, and told which case it was; the unit agent does the same for a patch cut off (`agent-<id>.log` shows `a sample was cut off` and `the bound for the next round is N`) |
| `--attempts N`, `--agent-seconds N` | per unit: the attempt ceiling (4) and the cap on one agent turn (30) |
| `--plan-seconds N` | the cap on the whole plan call (900) |

Paths, provider and model go into shell command lines, so they may hold only letters, digits and `. _ / + : = @ % , -`. A path with `..` in it is refused (the file capability traps on it).

## Example

```sh
scripts/build-agent.sh                      # the agent: build/cancho-agent
scripts/build-cancho-build.sh               # this tool: build/cancho-build
mkdir -p runs/roman
build/cancho-build "$CANCHO" "$PWD/eval/roman/brief.txt" "$PWD/runs/roman" \
    "$PWD/scripts/cancho-agent.sh --key-file $HOME/.config/cancho-code/anthropic.key --primer $PWD/guidelines.md --max-tokens 16000" \
    --provider anthropic --model claude-haiku-5-5 \
    --guide "$PWD/docs/plan-guide.md" --review on --review-guide "$PWD/docs/review-guide.md" \
    --attempts 6 --agent-seconds 300
...
[BUILD_VERDICT]	done
```

## Verdicts

The last line is `[BUILD_VERDICT]<TAB><word>`; the exit code follows the word.

| word | exit | meaning |
|---|---|---|
| `done` | 0 | every unit verified and the final gate held |
| `stuck` | 1 | a unit failed (its refusals, its examples, or the agent reached the model and gave up: [project.md](project.md#the-agents-exit-codes)), or a unit depended on one that did |
| `gate_failed` | 1 | every unit verified, the whole did not check |
| `plan_failed` | 3 | no valid plan: the agent used its rounds up, needs a decision (`plan.json.questions.json`), or wrote a plan the check refuses (its `[PLAN_ERROR]` lines are printed). **The project step does not run.** |
| `provider_error` | 4 | the agent could not be reached (or crashed, or timed out), in the plan or in a unit; what verified is kept |

Exit 2 is a usage error (nothing was run). A killed run is resumed by running the same command: a valid `plan.json` is not asked for again, and `state.txt` keeps the units that verified (they are re-checked, as in `project`).

## The run directory

`<workdir>/` is the whole record of a run; other tools read exactly these files.

| file | what |
|---|---|
| `plan.json` | the plan; absent or empty until a valid one exists |
| `plan.log` | the plan agent's standard error and output (the rounds it was rejected in) |
| `state.txt` | `verified <id>` per verified unit |
| `trail-<id>.jsonl` | the unit's trail, kept whatever its outcome |
| `agent-<id>.log` | the unit agent's standard error, per attempt, kept whatever the outcome ([docs/project.md](project.md)): where to look when a unit ends `provider_error` or `stuck` |
| `usage.jsonl` | one JSON line per API call, plan and units, written by the agent |
| `project.cho`, `main.cho`, `tests-<id>.cho`, ... | the project driver's files ([docs/project.md](project.md)) |
| `journal/` | the whole story of the run: `events.jsonl` and `blobs/` ([journal.md](journal.md)) |
| `run.log` | the lines below, appended by every run |
| `build.json` | the run as a whole, rewritten after each stage and at the end |

`run.log` holds `[BUILD_STAGE]<TAB>plan|plan<TAB>reused|build`, `[PLAN]` and `[PLAN_ERROR]`, `[PLAN_REVIEW]<TAB>reviewed|unreviewed` (only when the plan agent ran with `--review on`: `unreviewed` means the review gave no usable answer twice, so the plan's cases were kept without a second reader; the plan agent's words are in `plan.log`), `[UNIT]<TAB><id><TAB>building|verified|kept|regressed|failed|skipped|unavailable`, `[AGENT_LOG]<TAB><id><TAB>agent-<id>.log` (after a unit that did not verify), `[UNIT_WHY]<TAB><id><TAB>agent:gave-up:<why>` (only when the unit's last attempt was the agent giving up), `[INTEGRATE]<TAB><id><TAB>fast|merge` or `requeued|failed<TAB><why>` (only with `--jobs` above 1: a verified unit's work went into `project.cho`, or did not fit it; [parallel.md](parallel.md)), `[PROJECT_VERDICT]` and `[BUILD_VERDICT]`. The loop's per-attempt `[ACCEPTANCE]` and `[ISSUE_VERDICT]` lines go to the console only; the attempts are in the trails.

`build.json`, one line:

```json
{"brief":"/.../eval/roman/brief.txt","stage":"build","plan_valid":true,"units_total":6,"units_verified":2,"verdict":"","started_unix":1792068476,"seconds":412,"provider":"anthropic","model":"claude-haiku-5-5","review":"reviewed"}
```

`review` is `reviewed`, `unreviewed` or `none` (no review, or no plan.log), read from the plan agent's output; it is never silent when a plan stands without its review. `stage` is the stage in progress (`plan`, `build`) and `done` once the run has ended, with `verdict` set to the word above (empty before). `units_verified` is counted from `state.txt` at each write; during the build, `state.txt` is the live count. `started_unix` and `seconds` are of this invocation (Unix seconds from the wall clock, which can step; the number is a stamp, not a timer). A run that is killed leaves the file as of its last stage.

## Continuing a stuck unit

A run that ends `stuck` is not lost: the plan and `state.txt` are in the work directory, and the units that verified stay verified. Run the same command again with one more option and only the unit you name (and the units that need it) is worked on:

```sh
# the unit `get` was refused three times. Try it again, and tell the model what you see:
build "$CANCHO" brief.txt "$PWD/runs/sortedmap" "$AGENT" --provider anthropic --model claude-haiku-5-5 \
    --retry get --hint "the key is a borrowed slice: compare with buffer.bytes(k), not k"

# or write it yourself: the code in a file, checked like a model's would be, with no model call
build "$CANCHO" brief.txt "$PWD/runs/sortedmap" "$AGENT" --provider anthropic --model claude-haiku-5-5 \
    --patch get get.cho
```

| option | |
|---|---|
| `--retry <unit>` | re-opens the unit: it goes back to not verified (even if it had verified), its attempts start counting from one and the same-refusal rule starts over, and it is built again. The units that need it are checked again after it, and one that broke is rebuilt; the other units are left alone. The earlier attempts stay in `trail-<unit>.jsonl` (the new ones are numbered after them) and in the journal |
| `--jobs <N>` | how many units are built at the same time (1 to 64; default 4): the units whose dependencies are verified, each in a workspace of its own, put into `project.cho` by one writer when they verify, and built again when they do not fit together. `--jobs 1` is one unit at a time, the output and files of before. [parallel.md](parallel.md) |
| `--hint <text>` | with `--retry`: your words about the unit. They reach the agent as `HINT:` lines of the unit's task and the model reads them under "What the person who runs this build says about this unit"; the compiler and the unit's own examples still decide. Not empty, at most 4000 bytes; it is data, never run by a shell |
| `--patch <unit> <file>` | the code in `<file>` (the unit's function and what it needs, as complete top-level items; a model's reply shape, fences and a word around it are fine) is put into `project.cho` the way a model's patch would be, then checked by the compiler and the unit's own examples: one attempt, no model. If it does not verify, `project.cho` is put back as it was and the refusal is shown (`[PATCH]<TAB><unit><TAB>refused`, exit 1, `stuck`). If it does, the units that were waiting for the unit are built as in any run |

`--retry` and `--patch` do not go together, and each needs the plan the run left (`plan.json` valid in the work directory, the unit in it); a unit the plan does not have, an empty hint, a file that cannot be read: exit 2 with the reason and nothing changed. `run.log` says `[RETRY]<TAB><unit>[<TAB>hint]` and `[PATCH]<TAB><unit><TAB>applying|verified|refused`, `build.json` has `"retry":"<unit>"` or `"patch":"<unit>"` for this invocation, and the journal ([journal.md](journal.md)) marks the unit's start (`retry` / `patch`), puts the hint on the attempts of a retried unit, and records a patch as an attempt with outcome `human_patch`. The verdict lines and exit codes are the same as always. `project` takes the same options after its positional arguments.

The board ([dashboard.md](dashboard.md)) shows this command, ready to copy, in the panel of a stuck unit.

## Gate and authority

`scripts/test-build.sh` runs the whole chain against a stand-in agent (no network, no key, no model): the happy path, the arguments each call gets, plan reuse, an invalid plan, a plan the agent gave up on, an unreachable agent, a build killed with SIGKILL and resumed, a failing unit, a stuck unit, a stuck unit continued with `--retry` and `--patch`, usage errors, and the fields of `build.json`. The authority report is pinned in [authority-build.json](authority-build.json) (`scripts/check-authority.sh --build`): the tool spawns processes and reads and writes files; it has no network.

## The brief's names are the plan's names

A bullet in the brief of the form `- name(...) : what it does` (or `- name(...) -> Type : ...`) names a public function. After the plan check the build checks that every such name is declared by a unit (`fn name(` or `fn name[`, the whole name). The plan agent runs the same check in each of its rounds (`--mode plan`, after the plan check, `src/plan.cho` `brief_report`), so a plan that renames a function is fed back while the model can fix it: every missing name at once, each with the action (`declare fn <name> with exactly this name (the brief states it; do not rename it)`); the build keeps the check as a backstop for a `plan.json` it did not just ask for. A plan that renames one is refused with `[PLAN_ERROR]<TAB>brief-name<TAB>name<TAB>the action`, the verdict is `plan_failed`, and nothing is built; a valid `plan.json` left in the work directory that lacks one is not reused. A brief with no such bullet requires nothing. Found on the first real run: a plan that called `to_roman` `roman_to_roman` was `done` by its own examples and scored 0 on the audit that calls `to_roman`.
