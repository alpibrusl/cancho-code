# A finished build as a library: `build --library NAME`

A build leaves one file, `project.cho`: every function private, the tests of each unit beside it (`tests-<id>.cho`, which call the unit's helpers by name). A
package other programs `import` is a *module*: a file with `module NAME;` whose public functions are marked `pub`, and a test file written against `NAME.fn(...)`.
Until this step existed, a person made that change by hand after every build (the first cancho-diff build: `module diff;`, three `pub`, `cancho fmt`, a test
file). That is a hand edit of what the tools made; this step is the tools making it.

```
build <checker> <brief> <workdir> <agent> --provider P --model M --guide G --contract <contract.txt> --library NAME
```

After a build whose verdict is `done`, and only then, it writes

| file | content |
|---|---|
| `<workdir>/src/NAME.cho` | `project.cho` with `module NAME;` after its `edition` line and `pub` in front of exactly the functions the contract file declares (`pub fn ...` lines), formatted by the checker's `fmt` |
| `<workdir>/tests/NAME_test.cho` | the plan's own tests for those functions (the units whose function the contract names), each call written `NAME.fn(...)`, under a header that imports `std.test`, the standard modules the text names, and `NAME`; formatted |

Private helper units keep only their in-build tests (`tests-<id>.cho`). A plan that still has `cases` and no `tests` is expanded first (`src/cases.cho`), the way the
plan agent does.

It then runs the checker over both: `fmt --check`, and `test --std tests/NAME_test.cho src/NAME.cho`. A library that does not compile with its tests
is not a library, and the step says so.

## The result

One line on success: `[LIBRARY]<TAB>ok<TAB>NAME<TAB><src path><TAB><tests path><TAB><N>` (N is the number of `pub fn test_` generated). For each contract function the plan
gives no tests (only examples, which are documentation), `[LIBRARY_SKIPPED]<TAB>fn<TAB>why`: its public-API test is not generated, and the line says so, so it is not
silent. The `[BUILD_VERDICT]` line is the build's and does not change.

Exit 0 ok; 6 the step refused (`[LIBRARY_ERROR]<TAB>tag<TAB>detail`). `--library` without `--contract`, or with a name that is not a module name, is exit 2 before anything runs.

| tag | when |
|---|---|
| `library-name` | the name is not a module name: lowercase letters, digits and `_`, not starting with a digit, at most 64 bytes, not `std` or `test` |
| `library-no-contract` | `--library` without `--contract` |
| `library-contract-empty` | the contract file declares no `pub fn` |
| `library-contract-missing` | a contract function is declared by no line of `project.cho` (the detail names it) |
| `library-has-module` | `project.cho` already declares a module |
| `library-no-edition` | `project.cho` has no `edition` line |
| `library-unread` | the contract, `project.cho` or `plan.json` cannot be read, or the plan has no units |
| `library-no-tests` | the plan gives none of the contract functions a test: there would be nothing to verify the library with |
| `library-write` | the directories or the files cannot be written |
| `library-format` | `fmt` refused one of the files (the detail is the checker's first line) |
| `library-tests` | `fmt --check` or the tests failed (the detail is the checker's first line): a test of the plan that fails against the code is this tag, not `ok` |

## What it does not do

* A contract function is public by *name*: an overloaded or generic function is not a case the language has, but a helper that shares a contract function's name would be marked too.
* A call of a contract function inside a string literal of a test is qualified too (the planner does not write one there; unmeasured).
* The tests are the plan's, written by the planner from the brief; they are not an independent oracle. The held-out audit of a package is a separate thing and is not here.
* It does not publish, commit or open a pull request: that is a Forge step (cancho-forge `docs/autonomy.md`).

## Gate

`scripts/test-library.sh`: over the first cancho-diff build (`tests/library/diff/`: its `project.cho`, `plan.json` and contract, the input that needed these edits by
hand) the step must give a file with `module diff;` on line 2, exactly three `pub fn`, clean under `fmt --check`, and a test file the checker runs (`test result: ok. N
passed`, N the count the step printed); a contract function with no tests is `[LIBRARY_SKIPPED]`; every tag above but the two write ones is reached once; and the command
refuses a missing contract or a bad name before it asks a model for anything. The gate was checked to fail: with `pub` not added, and with the test count broken, it is red.
