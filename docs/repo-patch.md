# A change request for an existing repository: `build --repo`

Everything else in this repository builds from a brief to a new program. `repo.patch` is the other direction: a repository **already exists**, a person (or Forge) writes a *change request*, and the tool answers it with a patch to that checkout, gated by the repository's own checks. It is the agent-side half of the `repo.change` task type of cancho-forge's `docs/company-lifecycle.md` (section 4.2): Forge prepares the input and bounds the output, this command is the stand-in-free worker that fills the middle.

```
cancho-build --repo DIR --change change.txt --checker CANCHO --work WORKDIR --agent CMD --provider P --model M [--kind bug|feature|refactor|rename] [--constraints FILE] [--touch NAME,NAME] [options]
```

It works on a **copy** of `DIR`. It never writes `DIR`, never runs `git` (there is no `git` in its code, and the copy leaves `.git` out), and ends with a `change.patch` and the changed tree in the work directory. Publishing, pushing and opening a pull request are somebody else's step.

| option | |
|---|---|
| `--repo DIR` | the checkout: absolute; it needs its sources (`src/`, or in a project [what `cancho.toml` names](#the-sources-of-a-project)) and has no link in them or in `tests/` (`repo-invalid`, exit 2). A `.git` inside it is not copied |
| `--change FILE` | the request, plain text, at most 16 KiB (longer is cut with a marker). Reaches the model inside a fixed frame that says it is a report and never an instruction about the task, the answer or the files (the lifecycle doc, 4.4: a mitigation, not a control) |
| `--kind` | `bug`, `feature` (default), `refactor` or `rename`. The first two must add a test ([below](#a-test-is-required)) |
| `--checker`, `--work` | the compiler (absolute) and the work directory (created; it may not contain `DIR` nor be inside it) |
| `--agent`, `--provider`, `--model` | as for `build`: the agent command, with no default provider and no default model. The agent is run as `AGENT --provider P --model M --usage-log WORKDIR/usage.jsonl --output change WORKDIR/bundle.txt` |
| `--constraints FILE` | optional, absolute: a small closed file of bounds on the *shape* of the change, enforced by the command ([below](#constraints-on-the-shape-of-a-change)). A line it does not know is a usage error (exit 2) |
| `--attempts N` (4), `--agent-seconds N` (300), `--test-seconds N` (300) | the attempt ceiling, the cap on one agent turn, the cap on one `cancho test` |
| `--max-files N` (8, at most 64), `--max-bytes N` (65536, at most 1000000) | the bounds on a change: sections (files) and bytes of the reply |
| `--max-bundle N` (400000, at most 1000000) | how many bytes the model is shown. A repository over it is shown as a selection ([below](#a-selection)) |
| `--touch NAME,NAME` | names of functions and types of `src/` that a selection shows in full, besides the ones the request names |

Paths are absolute, made of letters, digits and `. _ / + : = @ % , -`, with no `..` (they go into shell command lines, as in `build`).

## What the model is shown, and what it answers

`WORKDIR/bundle.txt` is every `.cho` file of `src/` and `tests/` of the copy, each after a line `=== FILE <path>`, when that is at most `--max-bundle` bytes (400000); a bigger repository is shown as [a selection](#a-selection). The task file beside it holds the frame, the kind and the request. The agent's third output mode, `--output change`, asks for an **envelope** and writes it over the bundle:

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

* **Items** are put in by `splice.splice_kept`: as patch mode does (an item with the same name is replaced in place, a new one is appended, new imports go with the imports), with one difference. In patch mode the comment above an item is part of it and is replaced with it. Here a reply item that brings no comment of its own leaves the comment above the old item where it is; a reply item with a comment replaces the old one. *(**Corrected:** this used to be `splice.splice`, unchanged. Measured on the real gateway through Forge, six models of six that answered replaced one function and five of the six patches deleted the two comment lines above it, which nobody had asked for: the models answered with the function alone, and the rule took the comment with the old text. The limit of the new rule: a comment that the change makes wrong stays unless the reply rewrites it, and a reply cannot delete a comment and keep the item except by `remove` and adding it again.)*
* **Removal** (`remove fn NAME`, `remove struct NAME`, `remove enum NAME`, or `remove type NAME`) is `splice.remove_items`: the item goes, its leading comment and the blank space after it with it. Removals are done first, then the items, so *a rename is a removal plus an addition*. Nothing looks for uses of the removed item: a use that is left is a compile error in the gate, in the compiler's words, and goes back to the model (`tests-failed`). A removal of an item the file does not have is a `[SPLICE_ERROR]<TAB>-<TAB>LINE:patch: remove fn NAME: the file has no such item` line, like the other splice errors; a removal in a file that is being created is `remove-in-new-file`; a `remove` line of another shape is `remove-syntax`.
* **A new file** is its whole text and must start with `edition N;` (`new-file-no-edition`). A section with nothing in it is `section-empty`.
* An envelope is read by `change.section_at`; text before the first header (a preamble, reasoning, a `</think>` block) is not part of it, and an agent answer with no header is exit 11, "gave up", like a patch with no code.

## A selection

A repository whose `src/` and `tests/` are over `--max-bundle` is not shown whole: the same sections are shown with most bodies left out (`src/selection.cho`). What is kept is decided by the compiler and by the words of the request, with no model call:

1. `cancho ids --std --edges src/*.cho` is run on the copy (`WORKDIR/edges.json`): every declaration with its file, its lines, its signature and the types and functions it refers to (cancho#816). When the compiler does not answer (a checker without `ids --edges`, a repository the checker refuses, a project), the same is read [from the text](#when-the-compiler-does-not-answer). *Corrected 2026-11-25:* this was exit 2 `selection-failed`, which is now only a bundle or an answer that cannot be read.
2. **Seeds**: a declaration whose name is a whole word of the request (names of four bytes or more), one named in `--touch`, and every declaration of a file the request names (`src/x.cho`, or `x.cho`). None at all is exit 2 `selection-empty`: the request has to name something, or `--touch` has to.
3. **Near**: what a seed refers to and what refers to a seed, one step each way.
4. **Shown**: seeds and near declarations in full; every type in full; of every other function its signature and a `// body not shown: N lines` line; the text between declarations (imports, comments) as it is. A test file is shown in full when it is `tests/X_test.cho` of a `src/X.cho` with a seed or a near declaration, or when it names a seed; of another one, and of a file the compiler did not describe (one in a directory under `src/`), the `import` lines and the first line of each function.
5. **Level 1**, when that is still over the limit: a file of `src/` with no seed and nothing near is its `pub` signatures only. Still over the limit is exit 2 `bundle-too-large`.

The run says `[CHANGE_SELECTION]<TAB>seeds<TAB>bytes<TAB>level<TAB>by`, `by` being `compiler` or `text`. `WORKDIR/bundle.all` is the whole, `bundle.src` the selection, `bundle.hidden` the functions whose body was not shown (`path<TAB>name`).

**A function that was not shown may not be changed blind.** A change that replaces or removes a function of `bundle.hidden` is refused as `item-not-shown`, before the repository's checks run; the function is added to the names to show and the next attempt gets a new selection with it in full (if that no longer fits, the selection stays as it was and the refusal repeats). Adding a function is never refused by this rule.

**Measured once, with the stand-in agent** (no model): the 110 files of the cancho compiler as a repository, 4,239,113 bytes whole, and a request that names two functions and a file. The selection is 289,969 bytes at level 1 (15 seeds; 2,415 functions with their body not shown), and the copy, the compiler's answer (1.4 MB of JSON) and the selection take 3.7 seconds together. At level 0 it is over the limit: the signatures of 110 files are more than 400,000 bytes.

What it is not: there is no ranking (a name that is a common word selects more than it should, and the only answer to "too big" is to name less), one step is a fixed radius, a use of a static, a field or a variant is not an edge (`ids --edges` does not report them), and a compiler error at a line that was not shown does not widen the selection: only `item-not-shown` does.

## One attempt

Each attempt starts from a fresh copy of the base (`WORKDIR/tree`), so a retry never builds on a half-applied answer:

1. the agent answers; its exit code decides: 0 go on, 10/11/12 it gave up (`agent-gave-up`, the attempt is lost, the next one is told), anything else (or a timeout) is `provider_error`, exit 4;
2. **bounds** on the envelope, all reported together: no section (`envelope-empty`), more than `--max-files` (`too-many-files`), more than `--max-bytes` (`change-too-large`), a path that may not be written, the same path twice (`path-duplicate`). A path may be written only if it is relative, made of letters, digits and `_ - . /`, has no empty, `.`, `..` or hidden component (so no `.git`), lies under `src/` or `tests/` and ends in `.cho`: `path-absolute`, `path-dotdot`, `path-git`, `path-component`, `path-chars`, `path-length`, `path-outside`. Links cannot lead out: the repository is refused if it has one in `src/` or `tests/`, and a path is written only under those two directories. A path with a file where a directory is needed is `path-conflict`. **Nothing is written when one of these fails**;
3. the sections are applied to the tree (`splice`/`remove_items`; errors as above);
4. **`cancho fmt` runs on every file written** (the compiler's own formatter, nothing hand-rolled). A file `fmt` cannot read is `fmt-failed`, with its words;
5. **the gate**, cheap checks first:
   * **2000-line guard**: a written file that is over 2000 lines and longer than it was is `file-too-long` (a file that was already over and did not grow is not blamed);
   * **a test is required**: see below, `no-test-added`; for a feature the tests must call the new code (`test-not-exercising`); a test the change writes must be one the repository runs (`test-not-run`);
   * **the constraints**, when `--constraints` was given: see below, `constraint-*`;
   * the repo's own `cancho fmt --check src tests` (`fmt-check-failed`);
   * `cancho test --std tests/X_test.cho src/*.cho` for every `tests/*_test.cho` (`tests-failed`, the first lines of the compiler's or the runner's answer); no such test file at all is `no-tests`. In [a project](#a-project) these two are the project's own `cancho build` (`build-failed`) and `cancho test` instead;
   * for kind `bug`, the tests that were added or changed are run against the **base** and must fail there (`test-passes-on-base`);
6. **`change.patch`** is `diff -ruN base tree` run in the work directory (so the paths read `base/src/x.cho` and `tree/src/x.cho`; `patch -p1` applies it to a fresh copy of the checkout). A tree equal to the base is `empty-change`.

A refusal is printed as `[CHANGE_ATTEMPT]<TAB>N<TAB>refused<TAB>tag,tag` and its `[CHANGE_ERROR]<TAB>tag<TAB>path<TAB>detail` lines (or the `[SPLICE_ERROR]` lines), and the first 1400 bytes of them are the next attempt's feedback, so the model reads the tag. `[CHANGE_ATTEMPT]<TAB>N<TAB>passed` ends a good run. Everything goes to the console and to `WORKDIR/run.log`.

### A test is required

For kind `bug` or `feature` the change must **add or change at least one test function** (`fn test_...`) in a file under `tests/`: a `test_` item of a written `tests/` file that the base does not have, or has with other text (`splice.changed_tests`). If it adds none the result is `no-test-added` and the retry feedback says so and what to do ("add a test that fails without the change"). `refactor` and `rename` are exempt. This is the answer to the one logic bug of the measurement (M-1, F1 sample 1: a swapped tuple that compiled and passed every existing test). A test that exists is not yet a test that proves something (M-1b: one feature sample's two tests used inputs on which the right answer and the swapped one are equal), so two rules need no model and no mutation engine:

**A bug fix: the tests must fail on the base (`test-passes-on-base`).** After the repo's own checks pass, every `tests/NAME_test.cho` that has an added or changed test function is run against `src/*.cho` of the **base** (`WORKDIR/probe`: a copy of the base with that one test file from the tree put over it, run as the gate runs it). *Every* test function the change added or changed must fail there; the ones that pass are named, and the retry feedback says "a test for a bug must fail without the fix: use inputs on which the buggy code gives the wrong answer". A test that does not compile on the base (it calls something the fix adds) fails there and is accepted: the check is "does not pass on the base", not "fails for the right reason". Test files the gate does not run (not directly `tests/NAME_test.cho`) are not probed. An untouched older test does not have to fail. *(**Corrected:** a test was looked for in the tests' output as `MODULE.NAME ... ok` only. A test file with no `module` line prints `test NAME ... ok`; the real gateway's test files have none, so none of their tests was ever seen as passed and this rule could refuse nothing there. Both forms are read now.)*

**A test the change writes must run (`test-not-run`).** After the repository's tests pass, every test function the change added or changed is looked for in what they printed. One that is not there as passed never ran: its file is not a `tests/NAME_test.cho`, or in a project is in no `[[test]]` of `cancho.toml` (which a change cannot write). It is refused by name, for every kind, and the feedback says to put the test in a file the repository already runs. *(Measured on the real gateway through Forge: asked to change a value that lives under `generated/`, which a change can neither see nor write, `claude-haiku-5-5` added a new file `tests/connect_timeout_test.cho` asserting the new value. No `[[test]]` listed it, `cancho test` passed without it, and the verdict was `done` for a patch that changed nothing and carried a test that would fail. The limit of the rule: it is by name, so a test named like one that another test file runs and passes is taken as run.)*

**A feature: the tests must call the new code (`test-not-exercising`).** A feature cannot be run against the base (the new function does not compile there), so the check is the cheap deterministic part: among the text of the test functions the change adds or changes, some function the change added or replaced in `src/` and made `pub` must be *called* (its name as a whole word followed by `(`, so `mathx.quarter(9)` and `quarter (9)` count, `test_quarter(` and a mention in a comment of the item do not). The text looked at is the tests' own and that of the functions of the same test file they call, and of those they call: a test that reaches the new function through a helper of its file (`key_is(...)`, which calls it) does call it. *(**Corrected:** the helpers were not followed. Measured on the real gateway through Forge with `claude-haiku-5-5`: a correct feature in `ipkey.aggregate`, whose tests use the test file's existing helper `key_is` as every other test of that file does, was refused as `test-not-exercising` on three of four attempts and the run ended `stuck`; the tree it left built, passed the gateway's tests and passed a test of mine it had not seen. Only functions of the test's own file are followed, by name: a helper in another file is not.)* If the change adds or replaces no public function (a private helper, a struct) there is nothing a test could be asked to call and the rule does not apply. `bug`, `refactor` and `rename` are not asked.

Neither rule checks that the test is *good* (a mutation of the new code is a bigger piece); they close the two holes the real-model run showed: a test that cannot fail on the bug, and a test that never touches the new function.

### When the compiler does not answer

*Added 2026-11-25, after cancho-gateway with an error in it could be given to `--repo` only whole (836 KB), which a small model did not get through.*

`cancho ids --edges` describes one program that passes its check. Three kinds of repository are not that: a [project](#a-project) (several programs, a `main` beside the probes, a package only `cancho.toml` names), a repository with an error in it (the one a `bug` or a broken build is about), and any repository under a checker that has no `ids --edges`. For those, what the compiler said is kept in `WORKDIR/edges.err` and `WORKDIR/edges.json` is written from the text of `src/` instead (`src/textedges.cho`), in the same form, so everything above holds as it is. The line says `text`.

What the text says, and where it is less than the compiler:

* **A declaration** is a line that starts in the first column with `fn`, `struct`, `enum` or `static` (after `pub`, `res`, `val`), up to the line that ends it: the same line when it ends with `;` or `}`, the next line that starts with `}` otherwise. That is the layout `cancho fmt` writes. A file that is not formatted is described badly (a body may be cut short, or run into the next declaration), and nothing checks that it is formatted before the selection.
* **Refers** is a name of the declaration's own file used in it as a whole word, and `a.name` where an `import` line of the file calls a module of the repository `a` and that module declares `name`. Nothing is resolved by type: a local variable named like a function of its file is a reference to it, and so is the name in a string. A comment line refers to nothing.

**Measured once, against the compiler** (a 27-module cut of cancho-gateway that passes its check, 478 declarations): the same declarations, the same lines and the same signatures; the text finds all 585 references between them, and adds 18 the compiler does not have (a local called `key`, `kind` or `code` in a file with a function of that name). For a request that names one function the selection is the same 112,740 bytes either way, byte for byte, and so is the list of functions not shown. A reference the text adds only shows more.

**Measured once, on the repository that prompted it** (cancho-gateway at `d7ba5ff`, 837,629 bytes of `src/` and `tests/`, compiler release 0.1.1, which refuses it; the default `--max-bundle`):

* the selection is 330,944 bytes at level 0, by the text: 9 seeds (the request names `src/gateway.cho` and one function), 922 functions with their body not shown;
* with the stand-in agent and the known one-line fix: `done` in 61 seconds;
* with `claude-haiku-5-5`: `done` in one attempt and 72 seconds, 150,182 input tokens. Shown whole, the same model was `stuck` after four attempts at about 420,000 input tokens each ([A project](#a-project)). It is one run, and its patch also drops the two comment lines above the function it rewrites, which nothing here refuses.

## A project

*Added 2026-11-25, after cancho-gateway could not be given to `--repo`: its `src/` holds a `main`, which `cancho test tests/X_test.cho src/*.cho` refuses, and it imports a package that only `cancho.toml` names.*

A repository whose `cancho.toml` (at its root) has a line `[[bin]]` or a line `[[test]]` is a **project**, and its checks are the ones it declares, not a file-by-file run:

* the tree is copied to `WORKDIR/check` and the commands run there, so what a build writes (`build/`, the dependencies it installs) never reaches the tree the patch is made from;
* with a `[[bin]]`: `cancho build`, every binary. A failure is `build-failed` (path `cancho.toml`, the first 1000 bytes of the compiler's answer), and the tests are not run on a tree that does not build;
* with a `[[test]]`: `cancho test`, every set. A failure is `tests-failed` with the path `cancho.toml`. A project with no `[[test]]` is `no-tests`;
* for kind `bug`, the probe on the base runs `cancho test` in `WORKDIR/probe` and looks for the added or changed test names in what every set says;
* `--test-seconds` is the cap on each of the two commands, not on one test file.

Everything else is as for any repository: the model is shown and may write the project's sources and `tests/` only (so not `cancho.toml`), `cancho fmt --check` runs on them first, and a `cancho.toml` with neither table changes nothing. *Corrected 2026-11-26: this said `src/` and `tests/` only; see the next section.*

### The sources of a project

*Added 2026-11-26, after cancho-tools (code in `contract/` and `tools/`) and cancho-plot (`lib/`) could not be given to `--repo` at all: neither has a `src/`.*

A project says where its code is: every `[[bin]]` and `[[test]]` of `cancho.toml` has a `sources` line. The **area** of a project is what those lines name outside `tests/`, plus `tests/`; for any other repository it is `src/` and `tests/`, as before. The run works it out once, before anything is made, and writes it to `WORKDIR/area.src`.

* **What a source is**: a directory or a `.cho` file, a plain relative path (letters, digits, `_ - . /`; not absolute, no `..`, no hidden part) that is in the checkout, with no link in it, above it or under it. Anything else, or a project whose `sources` name nothing outside `tests/`, is `repo-invalid` (exit 2), and the agent is not run.
* **Shown**: every `.cho` file of the area. A directory the project does not name is not shown.
* **Written**: a `.cho` file under a source directory, a source file itself, or a file under `tests/`. Everything else is `path-outside`, and the refusal names the sources. `cancho.toml` still cannot be written, so a change cannot add a source.
* **Told apart from tests**: a source is what is not under `tests/`. The checks that said `src/` (the public functions a feature's test must call, the items and lines the constraints count, what the text selection reads) mean the sources.
* **`keep-names`**: its path must be about the area (under `tests/`, in or under a source, or a directory above one); otherwise exit 2, said once the sources are known and before the work directory is made.

**What it does not do.**

* **It reads `sources` lines only when the array is on one line** (`sources = ["a", "b"]`, the form every sibling repository writes). An array over several lines is not read, and a project with no source read this way is `repo-invalid`.
* **A generated directory that `cancho.toml` names is in the area** (cancho-tools names `generated/tally`): it is shown and may be written. Whoever runs the tool bounds that from outside (Forge's `publish_deny`); the tool has no such list.
* **The selection's two conveniences are for `src/` only**: a request that names a file as `x.cho` without its directory, and showing `tests/X_test.cho` because `src/X.cho` has a seed. In a project with other sources the request names functions, or the file by its whole path.
* **Tests are under `tests/`.** A project that keeps its test files elsewhere has them treated as sources: the test checks then find no test in the change.
* **A project with no `[[test]]` is still `no-tests`** (cancho-chain, cancho-opt and cancho-solve are checked by scripts, not by `cancho test`): this change does not reach them.

**Not measured:** no model has been run on a project of this shape, and neither cancho-tools nor cancho-plot has been given to it; the gate's cases are a small project with `lib/` and `tools/` and the stand-in agent.

What follows from running the project's own commands: the checker must be the compiler the project pins (`cancho build` refuses another; that refusal is the `build-failed` text), and a dependency named by a git address is fetched by the compiler into its cache, so **a project with dependencies needs the network** on the first run.

**Measured once, by hand** (macOS aarch64, compiler release 0.1.1, cancho-gateway at `d7ba5ff`, 836,029 bytes of `src/` and `tests/`, one TLS dependency, four binaries, 16 test sets; `--max-bundle 1000000` so it is shown whole):

* with the stand-in agent and the known one-line fix: `done` in 74 seconds, the patch one hunk of `src/gateway.cho`;
* with `claude-haiku-5-5`: `stuck` after four attempts, each `build-failed` with the same compiler error, about 420,000 input tokens an attempt. The same model fixed the same error in one attempt on a 237 KB cut of the repository, so the size of what is shown is what changed.

## Constraints on the shape of a change

`--constraints FILE` is a small closed file of bounds the gate can see, for requests like "keep the test names" or "change nothing but these functions", which the model reads in the task (the file is shown to it) and the command enforces mechanically on the written files. One constraint per line; blank lines and lines starting with `#` are skipped.

| line | meaning | refusal |
|---|---|---|
| `keep-names GLOB` | no `fn` of a file matching GLOB (a path of the sources or of `tests/`, with a `*` only at its end: `tests/*`, `src/diff.cho`) may be removed or renamed. A changed body is fine; a rename is a removal and an addition, so it is caught by the removal. May be given more than once | `constraint-keep-names` |
| `max-added-items N` | at most N items (fns, structs, enums) are *added* to the sources (`src/`, or a project's) (a replaced item is not an addition; items of `tests/` do not count) | `constraint-max-added-items` |
| `max-added-lines N` | at most N lines are added to the sources (the `+` lines of `diff -ruN` of each of them, base against tree; the new tests are not counted) | `constraint-max-added-lines` |
| `only-items a,b,c` | the only items of the sources that may be added, replaced or removed (tests may change freely) | `constraint-only-items` |

Item names are those of `splice.item_delta` (functions, structs, enums, one namespace). A violation is one `[CHANGE_ERROR]` line per constraint broken, with the names and counts in its words, reported together with the other refusals of the gate, and it is the retry feedback like any other. A line that is not one of these four, a number that is not a number, a second `max-added-items`, `max-added-lines` or `only-items`, a glob outside `src/` and `tests/` or with a `*` elsewhere than at its end, a file that cannot be read (or is over 16 KiB) or a relative path is a usage error: exit 2, nothing run, the line number in the message.

## The verdict, the exit code, the files

The last line is `[CHANGE_VERDICT]<TAB>done|stuck|provider_error`; with `done`, `[CHANGE_PATCH]<TAB>WORKDIR/change.patch` before it.

| exit | |
|---|---|
| 0 | `done`: the patch is written |
| 1 | `stuck`: every attempt refused |
| 2 | usage, or a repository that cannot be used or shown (`repo-invalid`, `repo-copy`, `repo-bundle`, `bundle-too-large`, `selection-failed`, `selection-empty`); nothing was run |
| 4 | `provider_error`: the agent could not be reached |

`WORKDIR/`: `base/` (the pristine copy), `tree/` (the last attempt's, the changed tree when `done`), `change.patch`, `bundle.src` (what the model is shown; with a selection also `bundle.all`, `bundle.hidden` and `edges.json`), `bundle.txt` and its `.task` and `.feedback`, `agent.log` (the agent's standard error), `usage.jsonl`, `run.log`.

## What it does not do (yet)

* **The selection is not measured with a model.** A repository over the limit is shown as [a selection](#a-selection), which the gate tests with the stand-in agent only: whether a model does as well on signatures as on whole files (share accepted, attempts) has not been run. The agent itself reads at most 1 MiB, so `--max-bundle` stops there. And this repository still cannot be given to `--repo`: its `src/` is several programs, not one that `cancho test tests/X_test.cho src/*.cho` builds.
* **The stale-base rule is Forge's.** The lifecycle doc has Forge apply the accepted patch to the *current* tip at publish and re-derive once (`patch-base-stale`). This command works on the working tree it is given and records no base revision.
* **The gate is the one the task named**: `fmt --check`, the line guard, and either `test` of `tests/*_test.cho` against `src/*.cho` or, in [a project](#a-project), its `cancho build` and `cancho test`. *Corrected 2026-11-25:* this said a repository with a `main` gets that from its own CI, not here; a project's binaries are now built. Other checks (examples, scripts, a doc build) are still the repository's CI's; and `fmt --check` runs on all of `src/` and `tests/`, so a base that is not formatted is refused until it is.
* **A selection from the text is the layout, not the program.** [When the compiler does not answer](#when-the-compiler-does-not-answer), declarations and references are read from formatted text: an unformatted file is described badly, a reference through a local of the same name is one too many, and a use the compiler would resolve by type is not seen. *Corrected 2026-11-25:* this said a project over the limit that does not compile cannot be shown and is `selection-failed`; it is now selected from the text.
* **The required test is not shown to be good.** A bug fix's tests must fail on the base and a feature's must call the new code, but nothing mutates the new code to see that the tests would notice a wrong one.
* **Renames of files, mode changes and binary files cannot be expressed**: the envelope names files to write, never to move or delete, so a whole file cannot be removed (an item can).
* It has none of `build`'s other machinery (effort tiers, memory, the journal, parallel units, resuming a killed run): this is the smallest slice.

## Where this differs from the lifecycle doc

`company-lifecycle.md` section 4.2 describes `repo.change` with a throw-away *git checkout* of `base` in `ev/base/`, an `ev/change.txt` and an `ev/scope.txt` (the allowed paths from `publish_allow` minus `publish_deny`), an output `ev/change.patch` bounded by Forge (`max_patch_files`, `max_patch_lines`, no rename/mode/binary), and a check program that applies it to a second copy and prints `TOTAL a/b`. Here:

* the copy is made with `tar` from a directory, not a git checkout, and carries no revision;
* the allowed set is fixed in the tool (`tests/**.cho`, and `src/**.cho` or [the sources of a project](#the-sources-of-a-project)), not read from `scope.txt`;
* the bounds are on the number of files and the bytes of the model's reply (`--max-files`, `--max-bytes`), enforced on the envelope **before** a patch exists, not on added lines of a patch;
* the gate is run by this command, not by a check program, and prints tags, not `TOTAL a/b`;
* the patch is `diff -ruN base tree`, with those prefixes.

The doc's refusal tags `patch-path-denied`, `patch-too-large` and `patch-kind-invalid` correspond to `path-*`, `too-many-files`/`change-too-large`; `patch-not-applicable` and `patch-base-stale` have no counterpart here.

## Gate

`scripts/test-repo-patch.sh` (the real compiler, a stand-in agent `tests/repochange/agent.sh` that answers from recipe files, a small repository `tests/repochange/repo/`): the pure functions one at a time (paths, kinds, envelopes, sections, removals, test counting), a feature over `src/` and `tests/` written on one line and made `fmt`-clean, `change.patch` applying to a fresh copy, the original untouched byte for byte (also read-only), a rename (the old function gone), a removal of a missing item and of an item the tests still call (both refused, the retry told), `no-test-added` for a feature and a bug and not for a refactor or a rename, a changed test counting, a bug fix whose tests pass on the buggy base (refused, named, the retry told), fail on it (accepted), or are one of each, a feature whose tests do not call the new function, the constraints one by one (a renamed test, too many items or lines, an item that was not allowed) and their usage errors, every bound and path refusal with nothing written outside, the 2000-line guard, `fmt-failed`, an agent that gives up and one that is away, and the usage errors. A project (a `cancho.toml` with a `[[bin]]` and a `[[test]]`, a `main` under `src/`): accepted, built on a copy with nothing of the build in the tree or the patch, `build-failed` for a change the tests pass and the program does not build with, `tests-failed` from a `[[test]]` set, `no-tests` without one, the base probe of a bug, and a `cancho.toml` with neither table checked file by file. A project whose sources are `lib/` and `tools/` with no `src/`: accepted, the area and the bundle, a write outside the area, the base probe, the call check and the line count on `lib/`, a `keep-names` path about nothing of the project, eight project files that are `repo-invalid`, and the text selection of a large one. No case has a dependency (the gate has no network). `sh scripts/test-repo-patch.sh --mutants` breaks one rule at a time in a copy of `src/` (the test probe on the base, the probe on the fix instead of the base, the call check, each of the four constraints, the usage check of the constraints, and others) and requires the gate to go red for each. `scripts/test-agent-native-ollama.sh` holds `--output change` against a stub model.
