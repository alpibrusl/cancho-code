# Several files: a plan that says which file each unit belongs to

Until now every unit was a function added to ONE file, `project.cho`. A real project has several files, each a cancho module, and one module uses another. The plan can now say so, and the same loop builds it: the same agent, the same checker, the same sweep, the same `--jobs`.

A plan names its **files** (each with its module and what it imports) and each unit names its **file**:

```json
{
  "name": "widths",
  "files": [
    { "file": "tokens.cho", "module": "tokens", "imports": ["std.buffer"] },
    { "file": "parser.cho", "module": "parser", "imports": ["tokens"] },
    { "file": "store.cho",  "module": "store",  "imports": ["parser"] },
    { "file": "project.cho",                    "imports": ["store"] }
  ],
  "units": [
    { "id": "digits", "file": "tokens.cho", "signature": "fn tok_digits(n: int) -> [] int",
      "examples": ["tok_digits(12) == 2", "tok_digits(0) == 1"], "deps": [] },
    { "id": "width",  "file": "parser.cho", "signature": "fn parse_width(n: int) -> [] int",
      "examples": ["parse_width(12) == 3"], "deps": ["digits"] },
    { "id": "cost",   "file": "store.cho",  "signature": "fn store_cost(n: int) -> [] int",
      "examples": ["store_cost(12) == 6"], "deps": ["width"] },
    { "id": "total",  "signature": "fn app_total(n: int) -> [] int",
      "examples": ["app_total(12) == 7"], "deps": ["cost"] }
  ]
}
```

A unit with no `file` is in `project.cho`, so every plan written before this still means what it meant. A plan with no `files` has one file. This example is `tests/multifile/plan.json`.

## What the plan says

- **`files`** (optional, an array): one entry per file, `{"file": "store.cho", "module": "store", "imports": [...]}`. `file` is a plain name: letters, digits, `_`, `.` and `-`, ending in `.cho`, no `/`, no `..`, and not `main.cho` or `tests-...` (the driver's own). `module` is one identifier (not `std`, not `test`); it is what the other files write after `import`. `imports` lists what the file needs: `std.NAME` modules and the `module` of other files in the plan. `project.cho` is the **root file**: it may be listed (to give it imports) but has no `module`, and no other file can import it (cancho cannot import the root).
- **`file`** (on a unit): the file the unit's function goes in. It has to be in `files`, or be `project.cho`.

From this the driver **writes each file's start itself**, so the imports are not left to the model: `edition 7;`, the `module` line, one `import` line per entry of `imports`, and the standard modules the signatures of the file's own units name (`result.`, `buffer.`, `option.`). A file that is already there (a run being continued) is kept as it is.

## How a unit is built

- **The unit's file is what the agent edits.** The agent is given `<workdir>/<file>` (its splice target is that file, `--output patch` or not), and its `.task`, trail, snapshots, `.before` copy and agent log are named after it (`store.cho.task`, `store.cho.trail.jsonl`, ...; for `project.cho` they are the names they always were).
- **The task says where it is.** After the unit's signature the task has `FILE:`, `MODULE:`, the imports already at the top of the file, and for every file this file imports the **public items** of that file as they are now (a `pub fn` as its signature line, a `pub` type whole), with how to call them (`tokens.NAME(...)`). The files it does not import are named, and marked as not to be used. The instruction for a module file says: declare the function `pub fn`, call another module's function with the module name in front, write only this file.
- **Every check sees every file.** The checker compiles `project.cho`, all the other files and `main.cho` together. The unit's tests are `tests-<id>.cho`: for a unit of a module, in that module (`module store;` at the top, so the examples call the function as the file does, and a raw `tests` entry sees the file's imports); for a unit of `project.cho`, in the root. A unit of a module is tested with the module files and WITHOUT `project.cho`: `cancho test` makes a root runner that imports the module under test, and a `project.cho` that imports it as well is refused (see "What cancho does", below). No module can import `project.cho`, so nothing of the module's depends on it. The final gate runs every unit's tests that way and checks everything together.
- **`pub` is checked.** A unit of a module whose function is not `pub fn` is refused with the reason (`error: NAME is not declared pub fn in store.cho`), as the acceptance of the unit: its own tests, in its own module, would pass on a private function, and the next unit, in another module, could not call it.
- **The sweep** after every unit runs the tests of the units that had verified, in every file. A unit of one file that changes what a unit of another file stands on makes that unit regress, with a note that names the unit that broke it; it is built again.
- **`--jobs N`**: the unit's workspace, `units/<id>/`, holds copies of ALL the project's files as they were when it was dispatched (the dependencies are verified by then), its own `.task`, tests and journal. The agent patches only its own file. When the unit verifies, a unit whose file has not changed meanwhile is integrated by copying that file (`fast`); otherwise the unit's items are merged into the file as it is now, by item name, as `splice.merge3` does for one file (`merge`): a clash is the unit's next note and the unit is built again. Units of other files never meet. Everything else is [parallel.md](parallel.md). `--jobs 1` of a plan with no files is, byte for byte, what it was (the gate pins it).
- **`--retry` and `--patch`** work per unit and per file: a patch is spliced into the unit's file.

## Where the files are

For a plan with files, `<workdir>/` holds `project.cho` and every file of the plan beside it (`tokens.cho`, `parser.cho`, ...), `main.cho`, `tests-<id>.cho`, `state.txt`, `trail-<id>.jsonl`, `agent-<id>.log`, `plan.json` and `journal/`, and the sidecars of each file (`tokens.cho.task`, `.trail.jsonl`, `.before`, `.snap0.cho`...). The project is the set of those `.cho` files; `build` and `project` write nothing else of the project. A plan with no files: `project.cho` and what it always had.

## What the plan check refuses

Every rule has a fixture in `tests/plans/` and a line in the table of [plan.md](plan.md):

| rule | refused when |
|---|---|
| `files-field` | an entry of `files` is not `{file, module, imports}`, has no usable `module`, names a module twice, imports something that is neither `std.NAME` nor the module of another file, imports itself or lists an import twice |
| `file-name` | a file name has other characters than letters, digits, `_`, `.`, `-`, ends other than in `.cho`, has `..`, or is one of the driver's own |
| `unknown-file` | a unit's `file` is not declared in `files` (and is not `project.cho`) |
| `file-duplicate` | two units in different files declare a function of the same name |
| `file-import` | a unit depends on a unit of another file that its file does not import, or on a unit of `project.cho` from a module file |
| `file-cycle` | the files need each other in a circle: the declared imports plus the dependencies between units of different files must form no cycle |
| `empty-file` | a file in `files` (other than `project.cho`) has no unit |

## What cancho does (found building this)

- `cancho test` makes a root program that imports each module that has tests, by its last name. If the project's own root (`project.cho`) imports that module too, the compile is refused: ``store` is already bound to another import here`. The minimal case is `tests/multifile/gaps/runner-import/`. The driver works round it (a module's tests run without `project.cho`); a runner that skipped a module the root already binds would let the tests run with the root, as the sweep of a root unit does.
- A module's imports are, per the module notes, the union of what its files import; in the compiler an import written twice in two files of the same module is an error. The generated tests of a module do not repeat the file's imports for that reason.

## Measured

[eval/results/2026-10-16-multi-file.md](../eval/results/2026-10-16-multi-file.md): the item `eval/multi/` (a calculator in three modules: a tokenizer, a parser over its tokens, an evaluator with a store built on both), built by Claude Haiku 5.5 at `--jobs 1` and `--jobs 4`, and a plan the model wrote for the same brief.

## The gate

`scripts/test-multi-file.sh`: stand-in agents, the real compiler. A four-file plan built at `--jobs 1` and at `--jobs 4` (the functions are in their files only; the scaffolds; the task; the workspaces hold every file; the journal), units of two files at once with a clash inside one file, a function that is not `pub`, a call without the module name, a sweep across files, `--patch`, a resume, a plan the check refuses, and a plan without files whose console, files and journal (times masked) are byte for byte what the driver wrote before (`tests/multifile/golden-single`, written from the commit before). The seven plan rules are in `scripts/test-plan.sh`; the splice of a file that has a `module` line in `scripts/test-splice.sh`; the board's `file` in `scripts/test-board.sh`; the item `multi` in `scripts/test-eval.sh`.
