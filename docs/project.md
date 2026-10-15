# The project driver

docs/parity.md P5. `fix` drives one issue against one file. A **project** is a plan (docs/plan.md) built unit by unit: the next unit whose dependencies are done, each verified by its own examples, everything that had verified re-checked after every unit, a killed run resumable. lex-code's `lex issue next` / `--project` is the model.

```
project <checker> <plan.json> <workdir> <agent-command> [attempts [agent-seconds [acceptance-command [lib-files]]]]
```

`checker` and `workdir` are absolute paths (a relative checker is exit 2: the first implementation died with SIGILL on one); `workdir` must exist. The agent command is the same shell command `fix` takes: it is run with the project file appended as its last argument and reads `<project.cho>.task` to learn what to write (scripts/cancho-agent.sh does). `attempts` is the ceiling per unit (default 4), `agent-seconds` the cap on one agent turn (default 30). `acceptance-command` and `lib-files` are for a plan with an `integration` unit (below); they are the `fix` hook's and extra files' counterparts.

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
DESCRIPTION: <the unit's description, decoded; only when the plan has one>
EXAMPLES:
<one example per line, as in the plan>
INSTRUCTIONS: Add this function to project.cho, keeping every other function as it is. The file has no main. Do not write tests or examples of your own: the examples above are run for you.
NOTE: <only after a regression: which unit broke, with the failing test output>
```

## The tests

An example `CALL == EXPECTED` becomes `pub fn test_<sid>_<k>() -> [] int { test.assert(CALL == EXPECTED); return 0; }` in `tests-<id>.cho` (which starts `edition 7;` and `import std.test;`); `<sid>` is the unit id with every character that is not a letter, digit or `_` turned into `_`. `==` compares scalars (int, bool, and a field read such as `f(1).ok`). The compiler has no `==` on enums, so the one enum an example may name is an `Option`: `CALL == option.Option::Some(X)` becomes a `match` on the call comparing `X`, and `CALL == option.Option::None` a `match` that expects `None`. The tests file does not `import std.option;` (files compiled together share their imports, and the project file must import it for the unit's signature to exist). A test file that does not build is the unit's failure, with the compiler's message in the feedback.

A unit's **acceptance command** (the `fix` hook, docs: acceptance) is:
`<checker> test --std --backend cranelift <workdir>/project.cho <workdir>/tests-<id>.cho || { cat <workdir>/legend-<id>.txt; exit 1; } #`

The loop's **check command** is `<checker> check --std --output json --backend cranelift <workdir>/project.cho <workdir>/main.cho`.

A unit that carries `tests` (docs/plan.md) uses them instead: each is decoded and appended verbatim to `tests-<id>.cho`, the examples are not turned into tests, and the legend only says the tests are the unit's own. The author is then responsible for unique test names and for what the file imports: the tests file already has `import std.test;`, and must not import what `project.cho` imports (files compiled together share their imports), so `std.result`, `std.buffer`, `std.bytes` are named by `project.cho` and used here as `result.`, `buffer.`, `bytes.`.

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

## Services: the integration unit

A service (docs/parity.md P7) is not built from one function, but its logic is: the briefs in `eval/services/<name>/brief.txt` name the pure functions (parsing, validation, state transitions) and the application only wires them to the fixed skeleton (`eval/services/skeleton/main.cho`: the server loop and `main`). The blocker for decomposing it was that unit tests need `cancho test`, which supplies its own `main`, and the skeleton has one. The smallest change that removes it:

- **Pure units are ordinary units.** Their logic is pure, so `cancho test project.cho tests-<id>.cho` needs no skeleton. What they need is the project file to import what it uses: `project.cho` of a service starts with the imports the skeleton would have made (`eval/services/bare.sh --header <reference>`: the skeleton's own import lines, plus the reference's std.hmac / std.utf8), and the whole service is built with `eval/services/skeleton/main_bare.cho`, which is `main.cho` without its import lines (files compiled together share their imports, and an import twice is an error; `scripts/test-services.sh` pins that the bare file is `main.cho` minus its imports).
- **The last unit is the application**, named by the plan's `integration` field (docs/plan.md). It has no examples and no tests file. Its acceptance command is the one given as the 7th argument (`python3 eval/service_run.py accept --bare <service>`: build with the skeleton, start the service, replay the scenarios); the driver appends `project.cho` to it. The loop is `driver.run_issue` as for any unit, so a failing scenario is the feedback of the next attempt (the scenario output is in `project.cho.feedback`, cut to the 4096 bytes the driver reads: `service_run.py accept` keeps the head, which names the first failures, and the result line), and the unit fails at the attempt ceiling or the same-signature stop like any other. The task of this unit has no `EXAMPLES:`; its `INSTRUCTIONS:` say to add the application wired from the existing functions, that the scenarios are run on the whole service, and that an earlier function may be corrected if a scenario shows it wrong (the sweep then re-runs every earlier unit's tests, and a unit that broke is rebuilt with a NOTE).
- **`lib-files`** (8th argument, space separated) are source files every compile gets beside the project: the `http-server` package (`project.cho` imports `http.server` through the skeleton's import list). They are added to the check command, to every unit's tests and to the final gate.
- The integration unit's check command is the normal one (`project.cho` + the driver's `main.cho` + the libs): it type-checks the application without the skeleton, and the acceptance command builds the real service (a build error is the first line of its output, which becomes the signature).
- The acceptance of the integration unit may take minutes (a build, a server, scenarios that sleep): 300 seconds per run instead of 60.
- **The final gate** checks `project.cho` + `main.cho` + libs, runs every non-integration unit's tests, then runs the acceptance command once more. After a resume the integration unit is re-verified by the acceptance command like the others.
- A plan with an `integration` unit and no acceptance command is a usage error (`project: the plan names an integration unit and no acceptance command was given`, exit 2, nothing asked of the agent).
- `eval/services/<name>/plan.json` is the hand plan of each service; `pieces.txt` says which top-level items of the reference application belong to which unit; `scripts/test-service-plans.sh` builds each plan with a stand-in agent (`eval/services/standin.sh`) that appends those pieces, then grades the finished project with the hidden attack. `eval/run_service_plan.py` runs the real pipeline (driver + `cancho-agent --output patch`) and grades with the attack.

Gate: `scripts/test-project.sh` case `service` (a stand-in service in `tests/project/service/`: lib file used by a pure unit, a fixed `main`, an acceptance script that builds and runs; happy path, a rerun that keeps both units, a failing scenario whose output reaches the agent and is retried, a never-satisfied application that ends `stuck` with the pure unit still verified, and the usage error).

## Two facts the first implementation and the gate turned up

- **The acceptance signature is the informative line, not the first.** On macOS the linker prints a warning before every test run, with a temp directory in its text; as the first line it made every attempt's signature different, and a unit whose agent was always wrong ran to its ceiling instead of stopping at the second identical failure. `src/acceptance.cho` now picks the first line that says `FAILED` or `error`, else the first that is not `ld:` noise (`scripts/test-acceptance.sh`, case `noise`).
- **An example's `==` compares scalars.** A result that is an enum or a record needs a field read; a test file that does not build is the unit's failure, with the compiler's message in the feedback.

- **The acceptance and the agent get a `PATH`.** `exec_spawn`'s environment is exactly what the parent passes, so both are spawned with `PATH=/usr/local/bin:/usr/bin:/bin`. Without it, `cancho test` inside the acceptance failed on Linux (`cc: fatal error: '-fuse-linker-plugin', but liblto_plugin.so not found`): found by CI, reproduced in a Linux container.

## What it does not do

No whole-run turn budget (design section 4; each unit has its ceiling), no parallel units, no unit reordering by cost, no repair round for failures that exist only when units share a file (P8), no hardening or acceptance scenarios for services (P6, P7), no report (P9). A regressed unit is rebuilt like any other, and a regression that two units keep causing each other runs until the per-unit ceilings stop it: each rebuild is a new `run_issue` with a fresh ceiling, so the loop stops after at most `3 x units` rebuilds of one unit (a guard, then `stuck`).
