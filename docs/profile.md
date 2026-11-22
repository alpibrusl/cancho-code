# Language profiles: `build --profile <file>`

`build` was written for one language: it calls the cancho compiler with fixed flags, names its files `project.cho`, `main.cho` and
`tests-<id>.cho`, turns a unit's examples into cancho tests and reads the compiler's findings under the key `rule`. A **profile** is
a small JSON file that the operator passes with `--profile <file>` and that states those choices. Without `--profile` the build uses the
**default profile**, which is today's cancho behaviour, byte for byte: the same commands, the same files, the same lines.

The point is a second target language (the first one in view is cancho-ui: the UI spike in statuslite's `docs/ui-spike.md`, section 4) without a fork of the build. This page is the design; what this change implements and what it leaves is at the end.

## What a profile says

| key | what | default (cancho) |
|---|---|---|
| `profile` | the schema's name and version, exactly `"cancho-build-profile/1"` | |
| `name` | a word for logs and docs | `"cancho"` |
| `ext` | the source extension: `.` and 1 to 8 letters or digits | `".cho"` |
| `files.entry` | the file the units are written into (replaces `project.cho`) | `"project.cho"` |
| `files.main` | the fixed program file every check compiles beside the entry (replaces `main.cho`; the build writes cancho's fixed `main` into it); `""` (none) is in the schema and refused as not implemented yet | `"main.cho"` |
| `files.tests` | a unit's tests file; `{id}` (exactly once) is the unit's id (replaces `tests-<id>.cho`) | `"tests-{id}.cho"` |
| `commands.check` | the words after the compiler for the unit's check, whose JSON answer is the loop's oracle | `["check","--std","--output","json"]` |
| `commands.compile` | the words after the compiler for the whole-program check whose exit code alone is read (the integration of parallel units) | `["check","--std"]` |
| `commands.test` | the words after the compiler for a unit's tests (the unit's verify, and the final gate) | `["test","--std"]` |
| `units` | what a unit of the plan is: `"functions"` (a `signature` and its `examples`/`tests`) or `"components"` | `"functions"` |
| `unit_tests` | how a unit's tests file is made: `"examples"` (each `CALL == EXPECTED` becomes a `test_<id>_<k>` cancho test, `src/project.cho` `write_tests`) or `"trace"` | `"examples"` |
| `findings.key` | the key of a finding's rule in the check's JSON answer | `"rule"` |
| `findings.clean` | the text a clean answer holds (with exit 0); anything else with no finding is the checker being away, never a pass | `"\"refused\": []"` |
| `primer` | an absolute file the agent gets as `--primer <file>`, for the plan and every unit; `""` is none (the agent command may carry its own) | `""` |

The compiler itself is never in the profile: it is the build's first argument, as today, an absolute path. A profile names
words to put after it, never a program, so "the operator names the compiler on the command line" stays true and nothing in a
profile file can start another program.

### The commands, as the build runs them

`<checker>` is the build's first argument, `<wd>` the work directory, `<entry>`, `<main>`, `<tests>` the profile's files
:

| when | command |
|---|---|
| a unit's check (every attempt, and the feedback the agent reads) | `<checker> <check...> <wd>/<entry> <wd>/<main>` |
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
and `bad-test` apply. `units: "components"` (designed, not implemented) is a unit that is one component: it has `component` (the
name) and `trace` (a JSON trace) instead of `signature` and `examples`; `bad-signature`, `needs-tests` and `bad-test` do not apply,
and the trace must parse and name the component. A plan with `files` (several source files, [multi-file.md](multi-file.md)) is
cancho's module system and is refused under any profile but the default (`[PLAN_ERROR]` `profile-files`, below).

### A cancho-ui profile (not in this change)

The schema is shaped so that this file can be written; it is refused today with `profile-not-implemented` (`units`, `unit_tests`):

```json
{"profile": "cancho-build-profile/1", "name": "cancho-ui", "ext": ".cui",
 "files": {"entry": "app.cui", "main": "", "tests": "trace-{id}.json"},
 "commands": {"check": ["check", "--output", "json"], "compile": ["check"], "test": ["test"]},
 "units": "components", "unit_tests": "trace",
 "findings": {"key": "code", "clean": "[]"},
 "primer": "/abs/cancho-ui-primer.md"}
```

One unit is one component plus its trace. Its verify is `cancho-ui check --output json app.cui` clean, then
`cancho-ui test app.cui trace-<id>.json` exit 0. With `unit_tests: "trace"`, `files.tests` ends in `.json` (it is the trace, written
from the plan's `trace` as it stands), not in `ext`. `findings.clean` for cancho-ui is to be confirmed against its `check --output json`
on a clean file; the spike saw the findings array, not the clean answer.

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
| `profile-not-implemented` | `units: "components"`, `unit_tests: "trace"` or `files.main: ""`: values of the schema that this build does not run yet |

Two more refusals are about a valid profile and the rest of the command line, with the same line shape and exit 2: `profile-jobs`
(`--jobs` above 1 with a profile other than the default: the parallel path still names the default files, see below) and
`profile-patch` (`--patch` with a profile other than the default: the patch splicer reads cancho items). Under such a profile
`--jobs` defaults to 1. And one is about the plan: a plan with `files` under a profile other than the default is refused by the
build's plan judgement with `[PLAN_ERROR]<TAB>profile-files<TAB>files<TAB>...`, verdict `plan_failed`, exit 3.

"Other than the default" is decided by value: a profile file that states exactly the default (`tests/profile/cancho.json`) **is**
the default, and the build runs as if no `--profile` had been given (`--jobs 4`, `--patch`, everything). `name`, `ext`, `units` and
`unit_tests` are checked but change nothing by themselves; the other fields are compared with the default.

Each tag is exercised by `scripts/test-profile.sh` with a fixture in `tests/profile/` (`bad-<tag>*.json`).

## What is not in scope

* No claim about model quality: nothing here says a model writes a second language well. The gate uses the stand-in agent.
* The cancho-ui profile itself (components, traces, its primer, Forge's step profile and artifact name): a later, separate change.
* The `project` command (`tests/programs/project.cho`) has no `--profile` yet; it runs the default.

## This change, and the next slices

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

How the profile travels: the build turns it into the project driver's `checker` value (`src/project.cho` `tool_program`,
`tool_get`): the checker path alone for the default, the path and one `key<TAB>value` line per field that differs from the default
otherwise (keys `entry`, `main`, `tests_pre`, `tests_suf`, `check`, `compile`, `test`, `key`, `clean`, `primer`). Every place that
names a file or a flag reads it from there, with the default beside it.

Left, in order (file:line on this branch):

1. **Parallel units under a profile** (`profile-jobs` goes): `src/project.cho:1750` `par_start` (the workspace copy names
   `project.cho`, lines 1765-1767), `:1640` `unit_worker` (its check command, line 1665, and `driver.run_issue_journal` at 1693
   with cancho's findings), `:1934` `combined_holds` (line 1939), `:2005` `par_finish` (the splice back into the entry).
2. **The journal's names**: `src/trail.cho:557` (`"file"` is recorded when the driven file is not `project.cho`, so under a profile
   every attempt carries `"file": "<entry>"`, which the board reads as a module file), `src/trail.cho:587,658,670` (blob names
   `code.cho`), `src/snapshot.cho:57` `path_of` (`.cho` on snapshots), `src/project.cho:1068` `unit_start_event` (`"file"` from the
   plan).
3. **The task's words**: `src/project.cho:711,713` (`write_task`'s `INSTRUCTIONS:` name `project.cho`), `src/prompt.cho:118`
   (the native agent reads findings under `rule` and `position`) and `:255-257` ("The cancho program below"), `src/cancho_agent.cho`
   (its `--output file` whole-file reply is the shape a second language wants: the default splicer reads cancho items).
4. **The scaffold and the main**: `src/build.cho:95` `scaffold` (`edition 7;` and std imports from the signatures, line 122),
   `src/project.cho:803` `write_fixed` (cancho's `main`, and the `edition 7;` seed of the entry at line 819): a field `files.seed`,
   and `files.main: ""` (no main file) lifted from `profile-not-implemented` with a gate.
5. **`units: "components"`, `unit_tests: "trace"`**: `src/plan.cho` (unit fields, and the `bad-signature`/`needs-tests`/`bad-test`
   branch), `src/project.cho:559` `write_tests` (write the plan's trace instead of cancho tests), the plan agent's own plan check in
   `src/cancho_agent.cho`. This is where the cancho-ui profile above becomes runnable.
6. **Multi-file plans under a profile** (`profile-files` goes): `src/plan.cho:713` `file_name_ok` (`.cho` names, `main.cho`,
   `tests-`), `:796` `root_slot` and `:1209` `unit_file` (`project.cho` as the root), `src/project.cho:252` `file_block`.
7. **`project --profile`**: `tests/programs/project.cho`.
8. **`--patch` under a profile** (`profile-patch` goes): `src/project.cho:1480` `apply_patch` (the cancho splicer).
