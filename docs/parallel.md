# Parallel units

`build` and `project` build the units of a plan that do not need each other **at the same time**: `--jobs N` is how many at most. `--jobs 1` is the driver as it always was, one unit after another, the same output and the same files. `build` takes 4 unless told otherwise; `project`, the lower tool, takes 1.

A unit is "ready" when every unit it depends on is verified. A plan of eight independent functions and one that uses them all builds the eight together and then the last. What the plan's shape allows is the limit (see the end).

## How it works

The driver stays one program with one loop. It is still the **only writer** of `project.cho`, `state.txt`, the trails, `run.log` and the journal. What changes is who works on a unit:

```
            project.cho  (the driver's, as verified so far)
                 |
   copy as of dispatch (every dependency verified)
        |                 |                  |
 units/a/project.cho  units/b/project.cho  units/c/project.cho      <- a workspace each
   + tests, task, .feedback, .call/, journal/
        |                 |                  |
     worker a          worker b           worker c                  <- the same program, started again:
   (agent, checker,   (agent, checker,   (agent, checker,              `<self> --unit-worker ...`
    unit's tests)      unit's tests)      unit's tests)
        \                 |                  /
         \_____ the driver waits for any of them on one poller ______/
                          |
          a unit verified in its workspace: INTEGRATE
```

- **A workspace** is `<workdir>/units/<unit>/`: a copy of `project.cho` as it was when the unit was dispatched (and of every other file of a plan that has files; the unit changes only its own file, and what follows is per file: [multi-file.md](multi-file.md)), the unit's tests and task, the agent's sidecars (`.call/`, `.agent.err`), and a journal of its own. The worker runs the same `fix` loop as ever (`driver.run_issue_journal`) in it: the agent edits the copy, the checker and the unit's examples judge the copy. **Nothing shared is written by a unit.** A workspace is scratch: it is deleted when its unit is done, and a killed run's are deleted at the start of the next run.
- **Integration** is what the driver does when a worker says its unit verified. If `project.cho` is still byte for byte what the unit started from, the unit's file simply becomes `project.cho` (the checker had just judged exactly that file, so it is not run again), and the units that had verified are checked again, as always (unless the unit only ADDED items: then nothing that was there can behave differently, and a clashing name or a file that does not compile is refused by the merge and the combined check; `splice.rewrites` says which; the final gate runs everything once either way). If other units were integrated meanwhile, the unit's own items (new functions, helpers, types, imports, and the items it rewrote, found by name as `src/splice.cho` finds them) are merged into the current `project.cho` (`splice.merge3`: the unit's file, the file it started from, and the file now). Then the driver checks the **combined** file: it must compile, the unit's examples must hold on it, and, when the unit rewrote something that was there, so must every unit that had verified.
- **A unit that does not integrate** is **requeued**. The same name defined twice with different bodies, an import alias taken by another module, a function another unit also changed, an effect row that only shows combined: whatever it is, `project.cho` is put back to what it was before the merge, the failure is the unit's next `NOTE:` (its feedback), and the unit is built again from the project file as it is now. It counts toward the ceiling: more than `attempts` requeues, or the same failure twice in a row, and the unit is `failed` like any that never gets right.
- **Order.** Units that end within `--settle` milliseconds of each other (300 by default) are integrated in **plan order**, whatever order they ended in; one that ends alone is integrated when it ends. Each integration is in the journal (`integrate`, with its `order`).

## When units start

- At most `--jobs` at once. A unit starts when it is open and every dependency is verified. The application unit of a service (`integration`, [project.md](project.md)) runs alone: its acceptance starts a server.
- **The first call is made alone.** The language primer is thirteen thousand tokens and is cached by the provider after the first call that carries it; two first calls at once pay for writing the cache twice. So when no model call has been made in this run, ONE unit is started, and the others when its first call has come back: the agent leaves `project.cho.call/meta.json` when a call returns (docs/journal.md), and the driver looks for it. An agent that never leaves one gets the others when the first unit has ended. `build` knows the plan stage has already made calls (the primer is cached by then) and starts as many as `--jobs` allows from the first moment; `project` does not know, and starts one.
- **A busy API is waited for.** The native agent used to give up on any answer that was not 200. Parallel units make 429 (too many requests) and 529 (overloaded) likely, and they are not the unit's fault, so `cancho-agent` waits and asks again: at most six times, `--backoff-ms` (2000), twice that, four times, ... at most 60 seconds each. The pauses are the same every time (nothing random), each is a line on the agent's standard error (so in the unit's `agent-<id>.log` and the journal's `stderr` blob) and a row of the usage log (`outcome: rate_limited`, `ms`: the pause). A wait is not an attempt; after the sixth the agent gives up as it did before (the unit is `unavailable`).

## When something goes wrong

- **One unit's agent fails** (it exits, times out, crashes, the provider is away): the other workers carry on and their units are integrated and kept, but nothing new is started, and the run ends `provider_error` (exit 4) with the failed unit named, as before. The next run builds what is left.
- **A unit that never gets right** fails alone (`[UNIT] x failed`, its trail kept); the units that do not need it are built; the ones that do are `skipped`. `stuck`, exit 1, as before.
- **A killed run** (even `kill -9`): what `state.txt` says verified stays verified. The workspaces of the units in flight are discarded, and the processes still working in them are killed, at the start of the next run (`pkill -f` on the `units/` path), which then rebuilds those units. The journal is whole lines: it is only ever written to a temporary name and renamed over.
- **Exit codes and the verdict** are those of [project.md](project.md) and [build.md](build.md).

## What is written

A unit's own free-standing comments (ones that belong to no item, i.e. not directly above a function or type) are trivia to the merge, as to `splice`, and are not carried into `project.cho` when the unit is merged rather than copied; comments directly above an item are.

Everything of a unit's story is moved into the driver's files when the unit ends, so `run.log` and the console never interleave two units' lines.

- `run.log` and the console: `[UNIT]` lines exactly as before. The loop's own `[ACCEPTANCE]` and `[ISSUE_VERDICT]` lines of a unit come as a block when it ends (console only, as before). New, and only with `--jobs` above 1: `[INTEGRATE]<TAB><unit><TAB>fast|merge` when a unit's work went into `project.cho`, and `[INTEGRATE]<TAB><unit><TAB>requeued|failed<TAB><first line of why>` when it did not.
- The journal ([journal.md](journal.md)): the unit's events (`unit_start`, the `attempt`s, `unit_end`) carry its `lane` (0 to jobs-1: the lowest free one when it was dispatched), `unit_end` its `ms` (dispatch to end), and the attempts their `ms` and `t_ms` as ever. A unit's attempt events are put into `events.jsonl` in order of `t_ms` when it ends, so the file never goes back in time. New events: `integrate` (`unit`, `mode` fast or merge, `ok`, `order`, `why`); a requeued unit's `unit_end` has `state` `requeued`.
- **The board's Timeline needs nothing more.** It draws an attempt from `t_ms - ms` to `t_ms` and a unit from its `unit_start` to its `unit_end`, per unit; overlap is what those numbers already say.

## What the probe found

The first thing written was `tests/programs/pool_probe.cho`, before any of the above: could one cancho program hold several children at once? It could. A `res struct` with a `Child`, the `Pipe` for its output and a `Buffer` goes in a `std.list.List` (the only collection that holds resources); the children and their pipes are all on **one** `Poller` (`poller_add_child`: a `pidfd` on Linux, `EVFILT_PROC` on macOS), each under a token of its own; `poller_wait` names the ones that are ready; each pipe is read without blocking into a buffer of its own; `child_kill(child, 256)` kills one (the signal is a bit of `std.signals`, 256 is KILL; 9 is something else); `child_wait` reaps. Four `sleep 1; echo` took 1.03 s together. There is no limit but descriptors (a live child holds two). Nothing was missing, so nothing is done with shell backgrounding, which would lose control of each child. `src/pool.cho` is that, made into a module; `scripts/test-parallel.sh` runs it with seven children (exit codes, output cap, a kill).

One thing to know, from `std/process.cho`: on macOS a child's exit is reported **once** by the poller, so the pool remembers it (`gone`) instead of asking again.

## What limits the speedup

Time that can overlap is the agents' time on independent units. The driver spends its own time (checks, the combined check, the sweep) one thing at a time, and a plan has a longest chain of units that each need the one before: **no number of jobs makes a run shorter than that chain**. The bound is computed from the plan and the journal (the board's Timeline note says it): the sum of all agent turns divided by the longest dependency chain weighed by the agent time of each unit. Measured on thirteen hand plans of libraries it was at most 1.37x overall. The service plans are wide (webhooks `[9,3,1,1]`, kvstore `[8,1,1,1]`: units per layer) but the last unit, the application, is by far the longest and nothing can start beside it. What really happened ([the measurements](../eval/results/2026-10-16-parallel.md), Haiku 5.5, two runs per cell): webhooks and kvstore 1.13x to 1.35x faster at `--jobs 4` for the same cost and the same attack score; a library plan (ini, a chain of six layers) none. The application unit is half of a service run, and the final sweep and gate are as long as before. A first version that re-ran every verified unit's tests at every merge was slower than one at a time (0.85x): the checks, not the model, were the long part of the pure units, and one driver does them one at a time.

## The gate

`scripts/test-parallel.sh`: stand-in agents that sleep and then write a recipe's code (no model, no network), the real compiler; the timing is read from the journal with a second of slack. The pool with seven children; the merge on its own; independent units overlap and a dependent never starts before the units it needs have ended; `--jobs 2` never has three; `--jobs 1` byte for byte as no option; the first call alone (and a silent agent); a clash, and a combined file that does not compile, each requeued with the failure in the next task; units ending together integrated in plan order; one agent failing while others finish; a stuck unit blocking only its dependents; no unit's work in `project.cho` while it is in flight; `kill -9` and the rerun; the usage errors; `build` (the plan call has warmed the cache); the agent waiting out 429 and 529.
