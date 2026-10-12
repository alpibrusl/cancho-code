# The project driver

docs/parity.md P5. `fix` drives one issue against one file. A **project** is a plan (docs/plan.md) built unit by unit: the next unit whose dependencies are done, each verified by its own examples, everything that had verified re-checked after every unit, a killed run resumable. lex-code's `lex issue next` / `--project` is the model.

```
project <checker> <plan.json> <workdir> <agent-command> [attempts [agent-seconds]]
```

`checker` and `workdir` are absolute paths (a relative checker is exit 2: the first implementation died with SIGILL on one); `workdir` must exist. The agent command is the same shell command `fix` takes: it is run with the project file appended as its last argument and reads `<project.cho>.task` to learn what to write (scripts/agent-ollama.sh does). `attempts` is the ceiling per unit (default 4), `agent-seconds` the cap on one agent turn (default 30).

## Layout (flat: a program cannot make directories)

| file in `workdir` | what |
|---|---|
| `project.cho` | `edition 7;` and the units' functions. The ONLY file the agent edits. Created (`edition 7;`) when absent. |
| `main.cho` | a fixed `main` that releases every capability; written by the driver each run. `cancho test` supplies its own `main`, so the program's `main` lives apart from the functions. |
| `project.cho.task` | the unit being built: written before each unit |
| `tests-<id>.cho` | the unit's examples as tests, written before each unit |
| `legend-<id>.txt` | test name and example text, one per line |
| `state.txt` | one line `verified <id>` per verified unit, rewritten whole after every change: what a resumed run keeps |
| `trail-<id>.jsonl` | the unit's trail (the P0 record), copied after the unit **whatever its outcome**: a unit that failed is the one whose trail is wanted |
| `project.cho.before` | `project.cho` as it was before the unit was built; a unit that fails (not one that is merely unavailable) puts it back, so the units that do not depend on it still build on a file without the failed unit's leftovers |
| `project.cho.feedback`, `.acceptance`, `.trail.jsonl`, `project.cho.snap<N>.cho`... | what `fix`'s loop writes beside its file (the loop is reused: `driver.run_issue`) |

Files without a `module` header share one namespace when compiled together, so the tests call the functions unqualified.

## The task file

```
UNIT: <id>
FUNCTION: <name>
SIGNATURE: <signature, as in the plan>
EXAMPLES:
<one example per line, as in the plan>
INSTRUCTIONS: Add this function to project.cho, keeping every other function as it is. The file has no main.
NOTE: <only after a regression: which unit broke, with the failing test output>
```

## The tests

An example `CALL == EXPECTED` becomes `pub fn test_<sid>_<k>() -> [] int { test.assert(CALL == EXPECTED); return 0; }` in `tests-<id>.cho` (which starts `edition 7;` and `import std.test;`); `<sid>` is the unit id with every character that is not a letter, digit or `_` turned into `_`. `==` compares scalars (int, bool, and a field read such as `f(1).ok`); an example whose result is an enum or a record needs a field read. This limit is the compiler's, not the driver's (`==` is not defined on enums), and a test file that does not build is the unit's failure, with the compiler's message in the feedback.

A unit's **acceptance command** (the `fix` hook, docs: acceptance) is:
`<checker> test --std --backend cranelift <workdir>/project.cho <workdir>/tests-<id>.cho || { cat <workdir>/legend-<id>.txt; exit 1; } #`

The loop's **check command** is `<checker> check --std --output json --backend cranelift <workdir>/project.cho <workdir>/main.cho`.

## The loop

1. `plancheck` the plan (src/plan.cho, in process). Invalid: print its `[PLAN_ERROR]` lines and `[PLAN]<TAB>invalid`, then `[PROJECT_VERDICT]<TAB>no_plan`, exit 3. Valid: `[PLAN]<TAB>valid`.
2. Write `main.cho`; create `project.cho` if absent; read `state.txt` (a missing file is empty).
3. **Re-verify what the state says is verified**: for each such unit, run its acceptance command. Holds: `[UNIT]<TAB><id><TAB>kept`. Fails: it is dropped from the state (`[UNIT]<TAB><id><TAB>regressed`) and goes back on the board.
4. **Next unit**: the first unit in file order that is not verified, not failed, and whose dependencies are all verified. None left: go to 6.
5. Build it: write the task and the tests, print `[UNIT]<TAB><id><TAB>building`, run `driver.run_issue` on `project.cho` with the check command, the acceptance command, `attempts`, K=2 and `agent-seconds`. Then:
   - Verified: add to the state (rewrite `state.txt`), print `[UNIT]<TAB><id><TAB>verified`, copy the trail to `trail-<id>.jsonl`, then **sweep**: run the acceptance command of every OTHER verified unit. One that fails is dropped from the state, printed `[UNIT]<TAB><sid><TAB>regressed`, and its next task carries a `NOTE:` naming the unit that broke it and the failing output. Back to 4.
   - Failed (signature, ceiling, defect): mark it failed for this run, print `[UNIT]<TAB><id><TAB>failed`. Back to 4: units that do not depend on it are still built.
   - Unavailable (the agent or the checker is away): print `[UNIT]<TAB><id><TAB>unavailable`, stop at once with `[PROJECT_VERDICT]<TAB>provider_error`, exit 4. The state keeps what verified.
6. Units never reached because a dependency failed are printed `[UNIT]<TAB><id><TAB>skipped`. If any unit failed or was skipped: `[PROJECT_VERDICT]<TAB>stuck`, exit 1. Otherwise the **final gate**: check `project.cho` + `main.cho`, and run every unit's tests, one `cancho test` per tests file (each starts `import std.test;`, and two such files in one run are refused: `test is already bound to another import`). Holds: `[PROJECT_VERDICT]<TAB>done`, exit 0. Fails: `[PROJECT_VERDICT]<TAB>gate_failed`, exit 1.

Usage errors (fewer than 4 arguments, `workdir` or the plan file unreadable): exit 2.

## Two facts the first implementation and the gate turned up

- **The acceptance signature is the informative line, not the first.** On macOS the linker prints a warning before every test run, with a temp directory in its text; as the first line it made every attempt's signature different, and a unit whose agent was always wrong ran to its ceiling instead of stopping at the second identical failure. `src/acceptance.cho` now picks the first line that says `FAILED` or `error`, else the first that is not `ld:` noise (`scripts/test-acceptance.sh`, case `noise`).
- **An example's `==` compares scalars.** A result that is an enum or a record needs a field read; a test file that does not build is the unit's failure, with the compiler's message in the feedback.

- **The acceptance and the agent get a `PATH`.** `exec_spawn`'s environment is exactly what the parent passes, so both are spawned with `PATH=/usr/local/bin:/usr/bin:/bin`. Without it, `cancho test` inside the acceptance failed on Linux (`cc: fatal error: '-fuse-linker-plugin', but liblto_plugin.so not found`): found by CI, reproduced in a Linux container.

## What it does not do

No whole-run turn budget (design section 4; each unit has its ceiling), no parallel units, no unit reordering by cost, no repair round for failures that exist only when units share a file (P8), no hardening or acceptance scenarios for services (P6, P7), no report (P9). A regressed unit is rebuilt like any other, and a regression that two units keep causing each other runs until the per-unit ceilings stop it: each rebuild is a new `run_issue` with a fresh ceiling, so the loop stops after at most `3 x units` rebuilds of one unit (a guard, then `stuck`).
