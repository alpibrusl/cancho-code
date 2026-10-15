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
| `--rounds N` | the plan agent's own retry rounds (3). A round whose reply was cut off by the output bound (a model that thinks first can use all of it before the first byte) is asked again with the bound doubled, at most 32000, and told which case it was |
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
| `stuck` | 1 | a unit failed, or a unit depended on one that did |
| `gate_failed` | 1 | every unit verified, the whole did not check |
| `plan_failed` | 3 | no valid plan: the agent used its rounds up, needs a decision (`plan.json.questions.json`), or wrote a plan the check refuses (its `[PLAN_ERROR]` lines are printed). **The project step does not run.** |
| `provider_error` | 4 | the agent could not be reached, in the plan or in a unit; what verified is kept |

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
| `run.log` | the lines below, appended by every run |
| `build.json` | the run as a whole, rewritten after each stage and at the end |

`run.log` holds `[BUILD_STAGE]<TAB>plan|plan<TAB>reused|build`, `[PLAN]` and `[PLAN_ERROR]`, `[PLAN_REVIEW]<TAB>reviewed|unreviewed` (only when the plan agent ran with `--review on`: `unreviewed` means the review gave no usable answer twice, so the plan's cases were kept without a second reader; the plan agent's words are in `plan.log`), `[UNIT]<TAB><id><TAB>building|verified|kept|regressed|failed|skipped|unavailable`, `[AGENT_LOG]<TAB><id><TAB>agent-<id>.log` (after a unit that did not verify), `[PROJECT_VERDICT]` and `[BUILD_VERDICT]`. The loop's per-attempt `[ACCEPTANCE]` and `[ISSUE_VERDICT]` lines go to the console only; the attempts are in the trails.

`build.json`, one line:

```json
{"brief":"/.../eval/roman/brief.txt","stage":"build","plan_valid":true,"units_total":6,"units_verified":2,"verdict":"","started_unix":1792068476,"seconds":412,"provider":"anthropic","model":"claude-haiku-5-5","review":"reviewed"}
```

`review` is `reviewed`, `unreviewed` or `none` (no review, or no plan.log), read from the plan agent's output; it is never silent when a plan stands without its review. `stage` is the stage in progress (`plan`, `build`) and `done` once the run has ended, with `verdict` set to the word above (empty before). `units_verified` is counted from `state.txt` at each write; during the build, `state.txt` is the live count. `started_unix` and `seconds` are of this invocation (Unix seconds from the wall clock, which can step; the number is a stamp, not a timer). A run that is killed leaves the file as of its last stage.

## Gate and authority

`scripts/test-build.sh` runs the whole chain against a stand-in agent (no network, no key, no model): the happy path, the arguments each call gets, plan reuse, an invalid plan, a plan the agent gave up on, an unreachable agent, a build killed with SIGKILL and resumed, a failing unit, a stuck unit, usage errors, and the fields of `build.json`. The authority report is pinned in [authority-build.json](authority-build.json) (`scripts/check-authority.sh --build`): the tool spawns processes and reads and writes files; it has no network.

## The brief's names are the plan's names

A bullet in the brief of the form `- name(...) : what it does` (or `- name(...) -> Type : ...`) names a public function. After the plan check the build checks that every such name is declared by a unit (`fn name(` or `fn name[`, the whole name). A plan that renames one is refused with `[PLAN_ERROR]<TAB>brief-name<TAB>name`, the verdict is `plan_failed`, and nothing is built; a valid `plan.json` left in the work directory that lacks one is not reused. A brief with no such bullet requires nothing. Found on the first real run: a plan that called `to_roman` `roman_to_roman` was `done` by its own examples and scored 0 on the audit that calls `to_roman`.
