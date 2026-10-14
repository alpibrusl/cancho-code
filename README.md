# cancho-code

**An assistant for [cancho](https://github.com/alpibrusl/cancho) that proves its work.**

Most coding assistants hand you a transcript and ask you to read the diff.
cancho-code hands you a verdict: every task ends in a machine-readable result
produced by the type checker — not by what the model says about itself. A task
is driven by a loop bounded by contracts, and *done is a proof the gate
evaluates, never a status anyone sets*.

**Status: the loop is built and gated.** The decision module, the failure
signature, the subprocess checker, the snapshot ring, the composed driver with
its `[ISSUE_VERDICT]` lines, the Mistral provider over native HTTPS, the
Ollama agent, and the `fix` front door — all in cancho, all gated.

```sh
# Build the tool.
"$CANCHO" build tests/programs/fix.cho src/driver.cho src/checker.cho \
    src/signature.cho src/loop_check.cho src/snapshot.cho src/trail.cho src/acceptance.cho \
    --std --backend cranelift -o ./fix

# Fix a broken program with a local model (no key, no egress).
ollama pull qwen3.8:27b
# The agent runs with no environment (no exported variable reaches it), so the model
# is named inside the agent command. The last two arguments: attempts, seconds per turn.
./fix "$CANCHO" demo/wordcount.cho "OLLAMA_MODEL=qwen3.8:27b $(pwd)/scripts/agent-ollama.sh" 4 300
[ISSUE_VERDICT]	verified	attempts 2
```

The model edits the file; the real `cancho check --output json` is the only
oracle; a looping model stops at the same-signature rule, a struggling one
gets its full ceiling; a verified answer is checked *again* before it is
believed, then snapshotted. Exit 0 is a proof.

A cloud model works the same way — `scripts/test-provider.sh mistral` with
`MISTRAL_API_KEY` in the environment runs the end-to-end gate against the
real API, the checker still the oracle.

## The plan

`plancheck <plan.json>` checks a plan (units with a signature, examples and dependencies) with no model: `[PLAN_ERROR]` lines for every problem, then `[PLAN] valid|invalid`, exit 0, 1 or 2. Format and rules: [docs/plan.md](docs/plan.md); gate: `scripts/test-plan.sh`, one fixture per rule.

## A project

`project <checker> <plan.json> <workdir> <agent-command> [attempts [agent-seconds]]` builds a plan unit by unit: dependencies first, each unit verified by its own examples, everything that had verified re-checked after every unit, a killed run resumed from `state.txt`. Ends `[PROJECT_VERDICT] done|stuck|no_plan|provider_error|gate_failed`, exit 0, 1, 3, 4. Spec: [docs/project.md](docs/project.md); gate: `scripts/test-project.sh` (a stand-in agent, no model). The Ollama agent reads the unit's task from `<project.cho>.task`.

## A Claude agent

`scripts/agent-anthropic.sh` is the same agent over Anthropic's Messages API. **Its key comes from a file**, never from the environment or the command line: the driver's agent has no environment, and a key in the agent command would be in the process list.

```sh
install -m 600 /dev/null ~/.config/cancho-code/anthropic.key     # then put the key in it (e.g. pbpaste > that file)
./project "$CANCHO" "$PLAN" "$WORK" \
  "ANTHROPIC_KEY_FILE=$HOME/.config/cancho-code/anthropic.key ANTHROPIC_MODEL=claude-haiku-5-5 ANTHROPIC_PRIMER=$(pwd)/guidelines.md $(pwd)/scripts/agent-anthropic.sh" 6 900
```

Claude thinks before it answers and **the thinking counts against `ANTHROPIC_MAX_TOKENS`**: on a long prompt a model can spend the whole bound thinking and leave no answer (every reply of the first long runs). `ANTHROPIC_THINKING=disabled|adaptive` and `ANTHROPIC_EFFORT=low|medium|high|xhigh|max` (the API's own values) control it, and `ANTHROPIC_MAX_TOKENS=16000` gives it room. `ANTHROPIC_WORKSPACE_ID` is needed for a key that is not scoped to a workspace.

A key file that group or others can read is refused before any request; the key is printed nowhere. The language page is sent as a cached `system` block, so every call after the first pays the cached-input price for it. Gate: `scripts/test-agent-anthropic.sh` (a stub of the API; no key, no spend).

## The agent contract

`fix <checker> <project.cho> <agent-command> [attempts [agent-seconds]]` runs the agent as a shell command with the project file as its argument. Each promise below has its own gate (`scripts/test-agent.sh`):

- **The checker's answer** for the file is in `<project.cho>.feedback` before every turn, the first included, so a model sees what the compiler refused.
- **Almost no environment.** The agent gets no `HOME` and nothing from yours, and exactly one variable the driver passes: `PATH=/usr/local/bin:/usr/bin:/bin`, exported. A shell's own default `PATH` is not exported to what it launches, so a build the agent or the acceptance ran (`cancho test` calling `cc`) failed to link on Linux until this was passed explicitly.
- **A turn is capped** by `agent-seconds` (default 30). Past it the run ends `unavailable agent`, named, not burned as a failure.
- **An acceptance command** (optional sixth argument, seconds as the seventh) runs on the file after the checker verifies it: exit 0 prints `[ACCEPTANCE] pass`; anything else is `[ACCEPTANCE] fail`, a retryable failure whose output the agent reads in `<project.cho>.feedback`. `verified` then means "meets this check", not only "type-checks": on the first audit, three builds were `verified` and none met the brief's shapes.
- **A failing agent is named**: a non-zero exit, a timeout, a signal each end `unavailable agent` and are recorded in `<project.cho>.trail.jsonl` (`agent_exit`, `agent_timeout`, ...). The file is left as it was.

`scripts/agent-ollama.sh` is the local-model agent (Ollama's HTTP API; `OLLAMA_MODEL` is required, there is no default model or provider: the script you name is the provider, the variable is the model; `scripts/test-agent-ollama.sh` runs it against a stub server).

**Give a local model the language's own page.** A model that has never seen cancho repeats the same refusal: on a trivial task (`clamp`), 6 of 6 baseline runs ended `failed signature` on `-> int` without the effect row, with or without the offending source line shown. With `OLLAMA_PRIMER` naming the output of `cancho agent-guidelines` (about 5,500 tokens, generated from the binary), 3 of 3 verified in one turn:

```sh
cancho agent-guidelines > guidelines.md
./fix "$CANCHO" project.cho "OLLAMA_MODEL=qwen3.8:27b OLLAMA_NUM_CTX=16384 OLLAMA_PRIMER=$(pwd)/guidelines.md $(pwd)/scripts/agent-ollama.sh" 6 900
```

`verified` means the checker accepts the file, nothing more: see the audit numbers in alpibrusl/cancho-code#9.

## Running the gates

```sh
cancho test tests/loop_check_test.cho tests/signature_test.cho src/loop_check.cho src/signature.cho --std --backend cranelift
CANCHO=<path> scripts/test-checker.sh
CANCHO=<path> scripts/test-snapshot.sh
CANCHO=<path> scripts/test-trail.sh
CANCHO=<path> scripts/test-agent.sh
scripts/test-agent-ollama.sh
CANCHO=<path> scripts/test-fix.sh
scripts/test-agent-anthropic.sh
CANCHO=<path> scripts/test-acceptance.sh
CANCHO=<path> scripts/test-verdicts.sh
CANCHO=<path> scripts/test-plan.sh
CANCHO=<path> scripts/test-project.sh
CANCHO=<path> scripts/test-eval.sh
CANCHO=<path> scripts/test-page.sh
CANCHO=<path> scripts/test-reference-ports.sh
CANCHO=<path> scripts/test-driver.sh
CANCHO=<path> CANCHO_PACKAGES=<compiler>/packages scripts/test-provider.sh build
```

Thirteen unit tests and three gate suites — each §4 contract with a case
where a stand-in loops forever and the assertion is that the loop stops,
named, in seconds rather than hours. All green without a network or a key.

## Why

The model it follows is
[lex-code](https://github.com/alpibrusl/lex-code) — and the failure it must
not repeat is lex-code's own, measured and documented there: runs that
continue for a long time without solving anything. Loop-safety is contracts
here, not tuning flags, and the gates found four silent false-passes in this
repository's own code on the way (each one recorded where it was fixed).

cancho-code is written in cancho and runs under the same capability grants it
enforces: the checker and the agent run under a narrowed `Exec` capability,
and the tool's authority report will name the one directory each may live in.

## Project page

[`docs/index.html`](docs/index.html), served at
`alpibrusl.github.io/cancho-code` once GitHub Pages is enabled for this
repository (Settings → Pages → Deploy from branch `main`, folder `/docs`).

## Contributing

Design before code, in [`docs/design.md`](docs/design.md), with claims
measured; a gate is fixed before the code it judges and must be able to fail;
a claim that turns out false is corrected in place. See the epic
([#8](https://github.com/alpibrusl/cancho-code/issues/8)) for the working
rules and the task list.

## Licence

EUPL-1.2, matching the rest of the ecosystem.
