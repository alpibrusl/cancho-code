# Language profiles: `build --profile <file>`

`build` was written for one language: it calls the cancho compiler with fixed flags, names its files `project.cho`, `main.cho` and
`tests-<id>.cho`, turns a unit's examples into cancho tests and reads the compiler's findings under the key `rule`. A **profile** is
a small JSON file that the operator passes with `--profile <file>` and that states those choices. Without `--profile` the build uses the
**default profile**, which is today's cancho behaviour, byte for byte: the same commands, the same files, the same lines.

The point is a second target language (the first one in view is cancho-ui: the UI spike in statuslite's `docs/ui-spike.md`, section 4) without a fork of the build. This page is the design; what is implemented and what is left is at the end.

## What a profile says

| key | what | default (cancho) |
|---|---|---|
| `profile` | the schema's name and version, exactly `"cancho-build-profile/1"` | |
| `name` | a word for logs and docs, and the language the task names (`LANGUAGE:`, below) | `"cancho"` |
| `ext` | the source extension: `.` and 1 to 8 letters or digits | `".cho"` |
| `files.entry` | the file the units are written into (replaces `project.cho`) | `"project.cho"` |
| `files.main` | the fixed program file every check compiles beside the entry (replaces `main.cho`; the build writes cancho's fixed `main` into it); `""` is none: nothing is written and no command names a main. `""` runs with `units: "components"` only, and `components` with `""` only | `"main.cho"` |
| `files.tests` | a unit's tests file; `{id}` (exactly once) is the unit's id (replaces `tests-<id>.cho`) | `"tests-{id}.cho"` |
| `commands.check` | the words after the compiler for the unit's check, whose JSON answer is the loop's oracle | `["check","--std","--output","json","--backend","cranelift"]` |
| `commands.compile` | the words after the compiler for the whole-program check whose exit code alone is read (the integration of parallel units) | `["check","--std","--backend","cranelift"]` |
| `commands.test` | the words after the compiler for a unit's tests (the unit's verify, and the final gate) | `["test","--std","--backend","cranelift"]` |
| `units` | what a unit of the plan is: `"functions"` (a `signature` and its `examples`/`tests`) or `"components"` (a `component` and its `trace`, below) | `"functions"` |
| `unit_tests` | how a unit's tests file is made: `"examples"` (each `CALL == EXPECTED` becomes a `test_<id>_<k>` cancho test, `src/project.cho` `write_tests`) or `"trace"` (the plan's trace, written as it stands, `write_trace`). `"functions"` runs with `"examples"` and `"components"` with `"trace"`; the two mixed pairs are refused as not implemented | `"examples"` |
| `findings.key` | the key of a finding's rule in the check's JSON answer | `"rule"` |
| `findings.clean` | the text a clean answer holds (with exit 0); anything else with no finding is the checker being away, never a pass (so a checker that prints nothing when clean needs a wrapper that says so: cancho-ui, below) | `"\"refused\": []"` |
| `primer` | an absolute file the agent gets as `--primer <file>`, for the plan and every unit; `""` is none (the agent command may carry its own) | `""` |

The compiler itself is never in the profile: it is the build's first argument, as today, an absolute path. A profile names
words to put after it, never a program, so "the operator names the compiler on the command line" stays true and nothing in a
profile file can start another program.

### The commands, as the build runs them

`<checker>` is the build's first argument, `<wd>` the work directory, `<entry>`, `<main>`, `<tests>` the profile's files
:

| when | command |
|---|---|
| a unit's check (every attempt, and the feedback the agent reads) | `<checker> <check...> <wd>/<entry> <wd>/<main>` (no `<wd>/<main>` when `files.main` is `""`, here and below) |
| a unit's verify (after its check is clean) | `<checker> <test...> <wd>/<entry> <wd>/<tests>` |
| the final gate | the check above (`> /dev/null`), then the verify of every unit, `&&`-joined |
| the integration of a parallel unit | `<checker> <compile...> <wd>/<entry> <wd>/<main>` |

For the default profile these are exactly the commands of [project.md](project.md) and [build.md](build.md).

### How findings become the build's lines

The check's answer is JSON. The loop's **signature** of a refusal is the value under `"<findings.key>": "` of the first finding,
a colon, and its `"message": "` normalised (`src/signature.cho`). That signature is what the trail's `signature`, the
`[ISSUE_VERDICT]` lines, the same-refusal rule and the memory classes are made of; the profile changes only where the rule is read
from, never the lines. A check that exits 0 with `findings.clean` in its answer is verified; no finding and no clean text is
`unavailable` (the checker is away), as today.

### How the plan check treats `fn` signatures

With `units: "functions"` the plan check is today's ([plan.md](plan.md)): every unit has a cancho `signature`
(`fn NAME(...) -> [row] TYPE`), `examples` of the form `CALL == EXPECTED` or its own `tests`, and `bad-signature`, `needs-tests`
and `bad-test` apply. A plan with `files` (several source files, [multi-file.md](multi-file.md)) is cancho's module system and is
refused under any profile but the default (`[PLAN_ERROR]` `profile-files`, below).

With `units: "components"` a unit is one component (`src/plan.cho` `check_as`, `collect_components`, `report_component`):

```json
{"id": "a", "component": "Counter", "description": "...", "trace": {"schema": "cancho-ui-trace", "version": "0.1.0", "component": "Counter", "steps": [...]}, "deps": []}
```

`id`, `component` (a string), `trace` and `deps` (an array of strings) are required, `description` and `effort` are as for a function;
`signature`, `examples`, `tests` and `cases` are not read, and `bad-signature`, `needs-tests`, `bad-test` and the example rules
(`no-example`, `example-*`, `tautology`) do not apply. `trace` is a JSON object, or a string that holds one (as the model may write
it). `duplicate-id`, `unknown-dep`, `cycle` and the `integration` rules are as for functions; there are no file rules (one entry
file), and a unit with a `file` is `unit-field`. Two rules are the components' own:

| rule | refused when |
|---|---|
| `unit-field` | (as for functions, with the components' fields) the unit is not an object, or lacks a string `id`, a string `component`, a `trace`, an array of strings `deps`; or has a `description` that is not a string, an `effort` that is not a level, or a `file` |
| `bad-component` | `component` is not one identifier (letters, digits, `_`, not a digit first), or is the component of an earlier unit ("a component is added by exactly one unit") |
| `bad-trace` | `trace` is neither an object nor a string; a string that is not a JSON object; a trace with no string `component`, or one that is not the unit's component (cancho-ui replays the file's last component when the trace names none) |

The build's backstop that the brief's function names are in the plan (`brief-name`) is not applied to a plan of components: the brief's
`- name(...) :` bullets are functions, and a component plan declares none. Under the default profile a component plan is refused
(`unit-field`: it has no `signature`), and a function plan under a components profile is refused the same way. The plan check
the plan agent runs in its own rounds (`src/cancho_agent.cho`) is still the functions' one (left, below).

### A cancho-ui profile

`tests/profile/cancho-ui.json` (its primer is `""`; the gate puts `tests/profile/cancho-ui-primer.md` in):

```json
{"profile": "cancho-build-profile/1", "name": "cancho-ui", "ext": ".cui",
 "files": {"entry": "app.cui", "main": "", "tests": "trace-{id}.json"},
 "commands": {"check": ["check", "--output", "json"], "compile": ["check"], "test": ["test"]},
 "units": "components", "unit_tests": "trace",
 "findings": {"key": "code", "clean": "[]"},
 "primer": "/abs/cancho-ui-primer.md"}
```

One unit is one component plus its trace. Its verify is `cancho-ui check --output json app.cui` clean, then
`cancho-ui test app.cui trace-<id>.json` exit 0. With `unit_tests: "trace"`, `files.tests` ends in `.json` (it is the trace), not in
`ext`. The trace file is the plan's `trace` as it stands: a string decoded, an object written compactly (its strings with their escapes
as written, its numbers as their text: `src/plan.cho` `trace_text`), with a final newline. The unit's legend says which component it replays.

What the run does differently, and nothing else:

* **No main.** `files.main: ""`: `write_fixed` writes no main file and no command names one (the check is `<checker> check --output json
  <wd>/app.cui`, the final gate that check `&&` one `test` per unit).
* **The entry starts empty.** The entry seed (`edition 7;`, and the scaffold's std imports from the signatures, `src/build.cho`
  `scaffold`) is cancho's; under `units: "components"` the entry is created empty (`make_project`, `write_fixed`). This is the one place
  the build ties `units` to the language: a function unit is a cancho `signature`, so a `"functions"` profile is a cancho program (the
  `renamed` profile is cancho under other names) and keeps the seed. There is no `files.seed` key: no profile so far needs a seed that is
  neither cancho's nor empty, and the schema stays closed until one does.
* **The task** (`<entry>.task`, `src/project.cho` `write_task`, `component_task`): `UNIT:`, `LANGUAGE: cancho-ui` (the profile's `name`),
  `COMPONENT:`, `DESCRIPTION:`, `EFFORT:`, `TRACE:` (the trace file's text), and `INSTRUCTIONS:` that name the component, the entry and the
  trace file, never `project.cho` or a cancho program. The `LANGUAGE:` line is written under any profile other than the default (and a
  function task there names the profile's entry, not `project.cho`); the native agent's prompt (`src/prompt.cho`) takes the line out of
  the task and says "the cancho-ui program below" where it said "the cancho program". A task without the line, the default's, is the
  same bytes as before, and so is its prompt.

**cancho-ui's own answers** (cancho-ui 0.1.0, observed against `cancho-ui-main`): `check --output json` on a clean file prints
**nothing** and exits 0, so `findings.clean` cannot be matched against cancho-ui itself: the profile's checker is cancho-ui behind
`tests/profile/ui/clean-wrap.sh` (`clean-wrap.sh <cancho-ui> <args>`: prints `[]` when the program exits 0 and printed nothing; sh
builtins only, since the build starts its checker with no environment). A refusal is a JSON array of findings, exit 1, each with
`"code": "..."` and `"message": "..."` (so `findings.key: "code"` signs it); a file that cannot be read is exit 3. `test` exits 0 on a pass
and 4 on a failed or malformed trace (`trace-unknown-component`, `trace-malformed`, `test-state-mismatch`), 1 when the file does not
check, 3 when a file cannot be read; its first line of output is `cancho-ui test <file> <trace>`, so a failed replay's signature is
`acceptance:cancho-ui test <wd>/app.cui <wd>/trace-<id>.json` (it holds the work directory). An empty file checks clean.

The profile gate builds a two-component plan (`tests/profile/ui/plan.json`, recipes in `tests/profile/ui/recipes/`) against a
stand-in cancho-ui (`tests/profile/ui/standin.sh`, behind the same wrapper) to `done`; with `CANCHO_UI=<cancho-ui binary>` it builds it
once more against the real one.

## The schema is closed

A profile is one JSON object with exactly the keys above (`files`, `commands` and `findings` are objects with exactly theirs).
Every key is required: a profile states everything, and a missing key is not filled from the default. The build reads it before
anything else and refuses a malformed one: exit 2, nothing run, nothing written, and one line per problem on standard error:

```
[PROFILE_ERROR]<TAB><tag><TAB><where><TAB><message>
```

| tag | when |
|---|---|
| `profile-unreadable` | the file cannot be read, is empty, or is larger than 64 KiB |
| `profile-json` | the file is not one JSON object |
| `profile-version` | `profile` is not `"cancho-build-profile/1"` |
| `profile-unknown-key` | a key the schema does not have, at the top or in `files`, `commands`, `findings` |
| `profile-missing-key` | a key the schema has is absent |
| `profile-type` | a value of the wrong JSON type: a string where an object or a list is wanted, a list that is empty or holds a non-string |
| `profile-word` | a command word or file name that is empty or holds a byte outside letters, digits and `. _ + : = @ % , -` (file names: no `/`, no `..`); these go into shell command lines |
| `profile-name` | `ext` is not `.` and 1 to 8 letters or digits; `entry`, `main` or (with `unit_tests: "examples"`) `tests` does not end in `ext`; `tests` does not hold `{id}` exactly once; two files with the same name |
| `profile-value` | `name` is empty or not a plain word; `units` or `unit_tests` is a word the schema does not name; `findings.key` is not 1 to 32 of `a-z _`; `findings.clean` is empty or holds a tab or a newline; `primer` is not `""` or an absolute plain path without `..` |
| `profile-primer` | `primer` names a file that cannot be read |
| `profile-not-implemented` | combinations of the schema that this build does not run yet: `units: "components"` with `unit_tests: "examples"`, `"functions"` with `"trace"`, `files.main: ""` with `"functions"`, `"components"` with a main file |

Two more refusals are about a valid profile and the rest of the command line, with the same line shape and exit 2: `profile-jobs`
(`--jobs` above 1 with a profile other than the default: the parallel path still names the default files, see below) and
`profile-patch` (`--patch` with a profile other than the default: the patch splicer reads cancho items). Under such a profile
`--jobs` defaults to 1. And one is about the plan: a plan with `files` under a profile other than the default is refused by the
build's plan judgement with `[PLAN_ERROR]<TAB>profile-files<TAB>files<TAB>...`, verdict `plan_failed`, exit 3.

"Other than the default" is decided by value: a profile file that states exactly the default (`tests/profile/cancho.json`) **is**
the default, and the build runs as if no `--profile` had been given (`--jobs 4`, `--patch`, everything). `ext` is checked but changes
nothing by itself; every other field is compared with the default.

Each tag is exercised by `scripts/test-profile.sh` with a fixture in `tests/profile/` (`bad-<tag>*.json`).

## What is not in scope

* No claim about model quality: nothing here says a model writes a second language well. The gate uses the stand-in agent.
* The cancho-ui profile's real-model use (its primer's content, Forge's step profile and artifact name): the gate's primer is a fixture.
* The `project` command (`tests/programs/project.cho`) has no `--profile` yet; it runs the default.

## What is implemented, and the next slices

Implemented (`scripts/test-profile.sh`, written first and seen red; in CI after `test-build.sh`):

* `--profile <file>` on `build` (`tests/programs/build.cho`), the closed schema and every refusal above (`src/build.cho`
  `profile_parse`, `profile_tool`; `judge` for `profile-files`). Each tag has a fixture `tests/profile/bad-<tag>*.json`; the gate
  requires exit 2, that tag and no other, an untouched work directory and no agent call.
* The default profile is the built-in one: with no `--profile`, or with `tests/profile/cancho.json`, the toolchain is the checker's
  path alone and every command is the old bytes. Every existing gate is unchanged and green, and the gate compares a run with
  `--profile tests/profile/cancho.json` with one without it: the same lines, the same `project.cho`, `main.cho`, `tests-*.cho`,
  `legend-a.txt`, `state.txt`, `run.log`, the same agent arguments.
* The seams, on the one-unit-at-a-time path: the file names (entry, main, tests) in `src/project.cho` (`write_fixed`, `write_tests`,
  `write_task`, `unit_accept`, `verify`, `build`, `final_gate`, `unit_event`, `drive`; `unit_file_in` maps the plan's default file to
  the entry) and `src/build.cho` `make_project`; the check, compile and test words (`add_command`); the findings key and clean text
  (`src/signature.cho` `of_key`, `src/checker.cho` `run_said_as`, `src/driver.cho` `run_issue_journal_as`; `of`, `run_said` and
  `run_issue_journal` are those with cancho's values); the primer (`--primer <file>` appended to the agent command).
* A second, deliberately trivial profile proves the mechanism is real without cancho-ui: the same cancho compiler behind a wrapper
  that reports findings under `code`, files `app.cn`, `entry.cn`, `t-<id>.cn` (`tests/profile/renamed.json`). The build is `done`
  with no `project.cho`, `main.cho` or `tests-*.cho` in the work directory; a unit whose first attempt is refused is fed the refusal,
  retried on its `code` signature and verifies; the same profile with `findings.key: "rule"` cannot read the wrapper's refusals and
  ends `provider_error` (the mutant that shows the key is used).
* The cancho-ui profile, one unit at a time (`tests/profile/cancho-ui.json`, above): `units: "components"` in the plan check, with
  `bad-component` and `bad-trace` (`src/plan.cho`; a fixture in `tests/profile/ui/` for each, built through `build` and refused
  `plan_failed`); `unit_tests: "trace"` (`src/project.cho` `write_trace`); `files.main: ""` (`write_fixed`, `add_main`) and the empty
  entry (`src/build.cho` `make_project`); the task's and the prompt's words (`write_task`, `component_task`, `src/prompt.cho`,
  `tests/prompt_language_test.cho`). The gate holds: a 2-component plan `done` against the stand-in (no `project.cho`, no main, an
  entry of the components alone, each trace file the plan's trace, the agents get the primer); a first attempt refused under `code` is
  retried on its signature; a first attempt whose trace fails is retried on its `acceptance:` signature; a function plan under the
  profile and a component plan under the default are refused; the real cancho-ui case runs when `CANCHO_UI` is set (it held against
  cancho-ui 0.1.0). The mixed pairs (`components` with `examples`, `functions` with `trace`, `main: ""` with `functions`, `components`
  with a main) stay `profile-not-implemented`, each with a fixture.

How the profile travels: the build turns it into the project driver's `checker` value (`src/project.cho` `tool_program`,
`tool_get`): the checker path alone for the default, the path and one `key<TAB>value` line per field that differs from the default
otherwise (keys `name`, `units`, `unit_tests`, `entry`, `main` (an empty value: none), `tests_pre`, `tests_suf`, `check`, `compile`, `test`,
`key`, `clean`, `primer`). Every place that
names a file or a flag reads it from there, with the default beside it.

Left, in order (file:line on this branch):

1. **Parallel units under a profile** (`profile-jobs` goes): `src/project.cho:1854` `par_start` (the workspace copy names
   `project.cho`, lines 1869-1871), `:1744` `unit_worker` (its check command, line 1767, and `driver.run_issue_journal` at 1797
   with cancho's findings), `:2038` `combined_holds` (line 2041), `:2109` `par_finish` (the splice back into the entry).
2. **The journal's names**: `src/trail.cho:557` (`"file"` is recorded when the driven file is not `project.cho`, so under a profile
   every attempt carries `"file": "<entry>"`, which the board reads as a module file), `src/trail.cho:587,658,670` (blob names
   `code.cho`), `src/snapshot.cho:57` `path_of` (`.cho` on snapshots: a cancho-ui run leaves `app.cui.snap0.cho`),
   `src/project.cho:1172` `unit_start_event` (`"file"` from the plan; a component unit records no `"function"` and no component).
3. **The agent's words**: `src/prompt.cho:118` (the native agent reads findings under `rule` and `position`; a cancho-ui finding,
   `code` and `span.start`, reaches the model as the checker's raw text, its first 1,500 bytes), `src/cancho_agent.cho` (its
   `--output file` whole-file reply is the shape a second language wants: the default splicer reads cancho items). The task's
   `INSTRUCTIONS:` and the prompt's "cancho program" are done (above).
4. **The plan agent under a profile**: `src/cancho_agent.cho:457,1022` run `plan.check` (functions) in the plan agent's own rounds, so a
   real plan agent asked for a component plan refuses it in every round; it needs the profile's `units` (an agent flag, `--units
   components`, from `src/build.cho` `plan_command`) and `plan.check_as`. The gate's stand-in plan agent writes the plan directly.
5. **Multi-file plans under a profile** (`profile-files` goes): `src/plan.cho:921` `file_name_ok` (`.cho` names, `main.cho`,
   `tests-`), `:1004` `root_slot` and `:1417` `unit_file` (`project.cho` as the root), `src/project.cho:260` `file_block`.
6. **`project --profile`**: `tests/programs/project.cho`.
7. **`--patch` under a profile** (`profile-patch` goes): `src/project.cho:1584` `apply_patch` (the cancho splicer).
8. **A seed that is neither cancho's nor empty** (`files.seed`): not needed by any profile so far (above); `src/build.cho:100`
   `scaffold` and `src/project.cho:919` `write_fixed` are where it would go.
