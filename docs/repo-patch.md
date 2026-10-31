# A change request for an existing repository: `build --repo`

Everything else in this repository builds from a brief to a new program. `repo.patch` is the other direction: a repository **already exists**, a person (or Forge) writes a *change request*, and the tool answers it with a patch to that checkout, gated by the repository's own checks. It is the agent-side half of the `repo.change` task type of cancho-forge's `docs/company-lifecycle.md` (section 4.2): Forge prepares the input and bounds the output, this command is the stand-in-free worker that fills the middle.

```
cancho-build --repo DIR --change change.txt --checker CANCHO --work WORKDIR --agent CMD --provider P --model M [--kind bug|feature|refactor|rename] [--constraints FILE] [options]
```

It works on a **copy** of `DIR`. It never writes `DIR`, never runs `git` (there is no `git` in its code, and the copy leaves `.git` out), and ends with a `change.patch` and the changed tree in the work directory. Publishing, pushing and opening a pull request are somebody else's step.

| option | |
|---|---|
| `--repo DIR` | the checkout: absolute; it needs a `src/` and has no link in `src/` or `tests/` (`repo-invalid`, exit 2). A `.git` inside it is not copied |
| `--change FILE` | the request, plain text, at most 16 KiB (longer is cut with a marker). Reaches the model inside a fixed frame that says it is a report and never an instruction about the task, the answer or the files (the lifecycle doc, 4.4: a mitigation, not a control) |
| `--kind` | `bug`, `feature` (default), `refactor` or `rename`. The first two must add a test ([below](#a-test-is-required)) |
| `--checker`, `--work` | the compiler (absolute) and the work directory (created; it may not contain `DIR` nor be inside it) |
| `--agent`, `--provider`, `--model` | as for `build`: the agent command, with no default provider and no default model. The agent is run as `AGENT --provider P --model M --usage-log WORKDIR/usage.jsonl --output change WORKDIR/bundle.txt` |
| `--constraints FILE` | optional, absolute: a small closed file of bounds on the *shape* of the change, enforced by the command ([below](#constraints-on-the-shape-of-a-change)). A line it does not know is a usage error (exit 2) |
| `--attempts N` (4), `--agent-seconds N` (300), `--test-seconds N` (300) | the attempt ceiling, the cap on one agent turn, the cap on one `cancho test` |
| `--max-files N` (8, at most 64), `--max-bytes N` (65536, at most 1000000) | the bounds on a change: sections (files) and bytes of the reply |

Paths are absolute, made of letters, digits and `. _ / + : = @ % , -`, with no `..` (they go into shell command lines, as in `build`).

## What the model is shown, and what it answers

`WORKDIR/bundle.txt` is every `.cho` file of `src/` and `tests/` of the copy, each after a line `=== FILE <path>` (at most 400000 bytes, else exit 2 `bundle-too-large`). The task file beside it holds the frame, the kind and the request. The agent's third output mode, `--output change`, asks for an **envelope** and writes it over the bundle:

```
=== FILE src/diff.cho
remove fn edit_count
fn edit_distance(...) -> [] int { ... }          <- complete items to add or replace, as in --output patch
=== FILE tests/diff_test.cho
fn test_edit_distance() -> [] int { ... }
=== FILE src/extra.cho                             <- a path the checkout does not have: the whole new file
edition 7;
...
```

* **Items** are put in by `splice.splice`, exactly as patch mode does (an item with the same name is replaced in place, a new one is appended, new imports go with the imports).
* **Removal** (`remove fn NAME`, `remove struct NAME`, `remove enum NAME`, or `remove type NAME`) is `splice.remove_items`: the item goes, its leading comment and the blank space after it with it. Removals are done first, then the items, so *a rename is a removal plus an addition*. Nothing looks for uses of the removed item: a use that is left is a compile error in the gate, in the compiler's words, and goes back to the model (`tests-failed`). A removal of an item the file does not have is a `[SPLICE_ERROR]<TAB>-<TAB>LINE:patch: remove fn NAME: the file has no such item` line, like the other splice errors; a removal in a file that is being created is `remove-in-new-file`; a `remove` line of another shape is `remove-syntax`.
* **A new file** is its whole text and must start with `edition N;` (`new-file-no-edition`). A section with nothing in it is `section-empty`.
* An envelope is read by `change.section_at`; text before the first header (a preamble, reasoning, a `</think>` block) is not part of it, and an agent answer with no header is exit 11, "gave up", like a patch with no code.

## One attempt

Each attempt starts from a fresh copy of the base (`WORKDIR/tree`), so a retry never builds on a half-applied answer:

1. the agent answers; its exit code decides: 0 go on, 10/11/12 it gave up (`agent-gave-up`, the attempt is lost, the next one is told), anything else (or a timeout) is `provider_error`, exit 4;
2. **bounds** on the envelope, all reported together: no section (`envelope-empty`), more than `--max-files` (`too-many-files`), more than `--max-bytes` (`change-too-large`), a path that may not be written, the same path twice (`path-duplicate`). A path may be written only if it is relative, made of letters, digits and `_ - . /`, has no empty, `.`, `..` or hidden component (so no `.git`), lies under `src/` or `tests/` and ends in `.cho`: `path-absolute`, `path-dotdot`, `path-git`, `path-component`, `path-chars`, `path-length`, `path-outside`. Links cannot lead out: the repository is refused if it has one in `src/` or `tests/`, and a path is written only under those two directories. A path with a file where a directory is needed is `path-conflict`. **Nothing is written when one of these fails**;
3. the sections are applied to the tree (`splice`/`remove_items`; errors as above);
4. **`cancho fmt` runs on every file written** (the compiler's own formatter, nothing hand-rolled). A file `fmt` cannot read is `fmt-failed`, with its words;
5. **the gate**, cheap checks first:
   * **2000-line guard**: a written file that is over 2000 lines and longer than it was is `file-too-long` (a file that was already over and did not grow is not blamed);
   * **a test is required**: see below, `no-test-added`; for a feature the tests must call the new code (`test-not-exercising`);
   * **the constraints**, when `--constraints` was given: see below, `constraint-*`;
   * the repo's own `cancho fmt --check src tests` (`fmt-check-failed`);
   * `cancho test --std --backend cranelift tests/X_test.cho src/*.cho` for every `tests/*_test.cho` (`tests-failed`, the first lines of the compiler's or the runner's answer); no such test file at all is `no-tests`;
   * for kind `bug`, the tests that were added or changed are run against the **base** and must fail there (`test-passes-on-base`);
6. **`change.patch`** is `diff -ruN base tree` run in the work directory (so the paths read `base/src/x.cho` and `tree/src/x.cho`; `patch -p1` applies it to a fresh copy of the checkout). A tree equal to the base is `empty-change`.

A refusal is printed as `[CHANGE_ATTEMPT]<TAB>N<TAB>refused<TAB>tag,tag` and its `[CHANGE_ERROR]<TAB>tag<TAB>path<TAB>detail` lines (or the `[SPLICE_ERROR]` lines), and the first 1400 bytes of them are the next attempt's feedback, so the model reads the tag. `[CHANGE_ATTEMPT]<TAB>N<TAB>passed` ends a good run. Everything goes to the console and to `WORKDIR/run.log`.

### A test is required

For kind `bug` or `feature` the change must **add or change at least one test function** (`fn test_...`) in a file under `tests/`: a `test_` item of a written `tests/` file that the base does not have, or has with other text (`splice.changed_tests`). If it adds none the result is `no-test-added` and the retry feedback says so and what to do ("add a test that fails without the change"). `refactor` and `rename` are exempt. This is the answer to the one logic bug of the measurement (M-1, F1 sample 1: a swapped tuple that compiled and passed every existing test). A test that exists is not yet a test that proves something (M-1b: one feature sample's two tests used inputs on which the right answer and the swapped one are equal), so two rules need no model and no mutation engine:

**A bug fix: the tests must fail on the base (`test-passes-on-base`).** After the repo's own checks pass, every `tests/NAME_test.cho` that has an added or changed test function is run against `src/*.cho` of the **base** (`WORKDIR/probe`: a copy of the base with that one test file from the tree put over it, run as the gate runs it). *Every* test function the change added or changed must fail there; the ones that pass are named, and the retry feedback says "a test for a bug must fail without the fix: use inputs on which the buggy code gives the wrong answer". A test that does not compile on the base (it calls something the fix adds) fails there and is accepted: the check is "does not pass on the base", not "fails for the right reason". Test files the gate does not run (not directly `tests/NAME_test.cho`) are not probed. An untouched older test does not have to fail.

**A feature: the tests must call the new code (`test-not-exercising`).** A feature cannot be run against the base (the new function does not compile there), so the check is the cheap deterministic part: among the text of the test functions the change adds or changes, some function the change added or replaced in `src/` and made `pub` must be *called* (its name as a whole word followed by `(`, so `mathx.quarter(9)` and `quarter (9)` count, `test_quarter(` and a mention in a comment of the item do not). If the change adds or replaces no public function (a private helper, a struct) there is nothing a test could be asked to call and the rule does not apply. `bug`, `refactor` and `rename` are not asked.

Neither rule checks that the test is *good* (a mutation of the new code is a bigger piece); they close the two holes the real-model run showed: a test that cannot fail on the bug, and a test that never touches the new function.

## Constraints on the shape of a change

`--constraints FILE` is a small closed file of bounds the gate can see, for requests like "keep the test names" or "change nothing but these functions", which the model reads in the task (the file is shown to it) and the command enforces mechanically on the written files. One constraint per line; blank lines and lines starting with `#` are skipped.

| line | meaning | refusal |
|---|---|---|
| `keep-names GLOB` | no `fn` of a file matching GLOB (a `src/` or `tests/` path, with a `*` only at its end: `tests/*`, `src/diff.cho`) may be removed or renamed. A changed body is fine; a rename is a removal and an addition, so it is caught by the removal. May be given more than once | `constraint-keep-names` |
| `max-added-items N` | at most N items (fns, structs, enums) are *added* to `src/` (a replaced item is not an addition; items of `tests/` do not count) | `constraint-max-added-items` |
| `max-added-lines N` | at most N lines are added to `src/` (the `+` lines of `diff -ruN base/src tree/src`; the new tests are not counted) | `constraint-max-added-lines` |
| `only-items a,b,c` | the only items of `src/` that may be added, replaced or removed (tests may change freely) | `constraint-only-items` |

Item names are those of `splice.item_delta` (functions, structs, enums, one namespace). A violation is one `[CHANGE_ERROR]` line per constraint broken, with the names and counts in its words, reported together with the other refusals of the gate, and it is the retry feedback like any other. A line that is not one of these four, a number that is not a number, a second `max-added-items`, `max-added-lines` or `only-items`, a glob outside `src/` and `tests/` or with a `*` elsewhere than at its end, a file that cannot be read (or is over 16 KiB) or a relative path is a usage error: exit 2, nothing run, the line number in the message.

## The verdict, the exit code, the files

The last line is `[CHANGE_VERDICT]<TAB>done|stuck|provider_error`; with `done`, `[CHANGE_PATCH]<TAB>WORKDIR/change.patch` before it.

| exit | |
|---|---|
| 0 | `done`: the patch is written |
| 1 | `stuck`: every attempt refused |
| 2 | usage, or a repository that cannot be used (`repo-invalid`, `repo-copy`, `repo-bundle`, `bundle-too-large`); nothing was run |
| 4 | `provider_error`: the agent could not be reached |

`WORKDIR/`: `base/` (the pristine copy), `tree/` (the last attempt's, the changed tree when `done`), `change.patch`, `bundle.src` (what the model is shown), `bundle.txt` and its `.task` and `.feedback`, `agent.log` (the agent's standard error), `usage.jsonl`, `run.log`.

## What it does not do (yet)

* **One model call per attempt, over all the files.** The model sees every file of `src/` and `tests/` (up to 400000 bytes): there is no selection of the files that matter, so a repository bigger than that is refused. M-1 measured one file per call.
* **The stale-base rule is Forge's.** The lifecycle doc has Forge apply the accepted patch to the *current* tip at publish and re-derive once (`patch-base-stale`). This command works on the working tree it is given and records no base revision.
* **The gate is the one the task named**: `fmt --check`, `test` of `tests/*_test.cho` against `src/*.cho`, the line guard. A repository with other checks (examples, a `main`, a doc build) gets those from its own CI, not here; and `fmt --check` runs on all of `src/` and `tests/`, so a base that is not formatted is refused until it is.
* **The required test is not shown to be good.** A bug fix's tests must fail on the base and a feature's must call the new code, but nothing mutates the new code to see that the tests would notice a wrong one.
* **Renames of files, mode changes and binary files cannot be expressed**: the envelope names files to write, never to move or delete, so a whole file cannot be removed (an item can).
* It has none of `build`'s other machinery (effort tiers, memory, the journal, parallel units, resuming a killed run): this is the smallest slice.

## Where this differs from the lifecycle doc

`company-lifecycle.md` section 4.2 describes `repo.change` with a throw-away *git checkout* of `base` in `ev/base/`, an `ev/change.txt` and an `ev/scope.txt` (the allowed paths from `publish_allow` minus `publish_deny`), an output `ev/change.patch` bounded by Forge (`max_patch_files`, `max_patch_lines`, no rename/mode/binary), and a check program that applies it to a second copy and prints `TOTAL a/b`. Here:

* the copy is made with `tar` from a directory, not a git checkout, and carries no revision;
* the allowed set is fixed in the tool (`src/**.cho`, `tests/**.cho`), not read from `scope.txt`;
* the bounds are on the number of files and the bytes of the model's reply (`--max-files`, `--max-bytes`), enforced on the envelope **before** a patch exists, not on added lines of a patch;
* the gate is run by this command, not by a check program, and prints tags, not `TOTAL a/b`;
* the patch is `diff -ruN base tree`, with those prefixes.

The doc's refusal tags `patch-path-denied`, `patch-too-large` and `patch-kind-invalid` correspond to `path-*`, `too-many-files`/`change-too-large`; `patch-not-applicable` and `patch-base-stale` have no counterpart here.

## Gate

`scripts/test-repo-patch.sh` (the real compiler, a stand-in agent `tests/repochange/agent.sh` that answers from recipe files, a small repository `tests/repochange/repo/`): the pure functions one at a time (paths, kinds, envelopes, sections, removals, test counting), a feature over `src/` and `tests/` written on one line and made `fmt`-clean, `change.patch` applying to a fresh copy, the original untouched byte for byte (also read-only), a rename (the old function gone), a removal of a missing item and of an item the tests still call (both refused, the retry told), `no-test-added` for a feature and a bug and not for a refactor or a rename, a changed test counting, a bug fix whose tests pass on the buggy base (refused, named, the retry told), fail on it (accepted), or are one of each, a feature whose tests do not call the new function, the constraints one by one (a renamed test, too many items or lines, an item that was not allowed) and their usage errors, every bound and path refusal with nothing written outside, the 2000-line guard, `fmt-failed`, an agent that gives up and one that is away, and the usage errors. `sh scripts/test-repo-patch.sh --mutants` breaks one rule at a time in a copy of `src/` (the test probe on the base, the probe on the fix instead of the base, the call check, each of the four constraints, the usage check of the constraints, and others) and requires the gate to go red for each. `scripts/test-agent-native-ollama.sh` holds `--output change` against a stub model.
