# Multi-file projects (#75): status of the branch `multi-file` (WIP hand-over)

## Done (committed)
- Plan check (src/plan.cho): `file` per unit, `files` per plan, rules files-field, file-name, unknown-file, file-duplicate, file-import, file-cycle, empty-file; fixtures in tests/plans (scripts/test-plan.sh).
- Splice (src/splice.cho + tests/reference/splice_ref.py): a `module NAME;` line is a header line; `public_items` lists the pub surface of a file.
- Driver (src/project.cho, src/trail.cho): scaffolds per file, per-file task/trail/before/snapshots, workspaces with every file, per-file integration/sweep/final gate, module tests run on module files without project.cho, pub check, std imports from signatures; build.cho leaves root scaffold to the driver.
- Journal: `file` on unit_start and (non-root) attempts. Board: `file` per unit (src/board.cho, board_ref.py, tests/board/multi-file, docs/board.html).
- Eval item eval/multi (brief, plan, reference/, oracle, audit_multi.py, mutants.json, facts); gate section in scripts/test-eval.sh; eval/run_item.py --jobs; plan_vs_reference for multi-file items.
- Gate scripts/test-multi-file.sh (+ tests/multifile, golden-single from origin/main), CI line, docs (multi-file.md, plan.md, project.md, build.md, journal.md, dashboard.md, reference.md, parallel.md, plan-guide.md).
- cancho gap repro: tests/multifile/gaps/runner-import (cancho test runner re-imports a module the root already imports).

## Gates
All green under sh and dash (plan, splice, project, multi-file, board, eval, parallel, build, journal, planner, briefs, page, cases, review, ...), nine authority pins unchanged. `services` is flaky under machine load (kvstore/jobs attack off by one), also on origin/main.
Mutations (dash, copies of the tree): all 16 RED (wrong splice file x2, workspace copy, imports, plan rules x3, sweep, integration x2, journal x2, pub-not-checked, module-tests-with-root, task-siblings, splice-module-line).

## Half-done / next
1. Finish mutation run (script lives outside the tree: scratchpad/mfmut.py).
2. (done) INSTRUCTIONS text with `module_name.function_name(...)`: test-multi-file green under sh and dash.
3. Measurement not started: 3 runs --jobs 1 and 3 runs --jobs 4 of eval/multi with Haiku 5.5, then 2 model-written plans via eval/run_build.py; write eval/results/<date>-multi-file.md|json; decide on a primer section for modules (not edited in cancho repo).
4. Push; no PR, no merge.

## Rebuild and rerun
export CANCHO=<cancho>/target/release/cancho CANCHO_PACKAGES=<cancho>/packages; PATH with a working node (here a wrapper setting DYLD_FALLBACK_LIBRARY_PATH for llhttp).
sh scripts/test-multi-file.sh; dash scripts/test-multi-file.sh; sh scripts/test-plan.sh; sh scripts/test-splice.sh; sh scripts/test-board.sh [--mutants]; sh scripts/test-eval.sh; sh scripts/test-project.sh; sh scripts/test-parallel.sh
Golden regeneration: MULTIFILE_GOLDEN=write PROJECT_SRC=<src of origin/main> sh scripts/test-multi-file.sh
Tools: sh scripts/build-agent.sh; sh scripts/build-cancho-build.sh; project exe from tests/programs/project.cho + src files (see the gate).
Measure: python3 eval/run_item.py multi --provider anthropic --model claude-haiku-5-5 --key-file ~/.config/cancho-code/anthropic.key --workspace wrkspc_01NnYYkfhp6fKLUr8B6UXnfX --primer <primer-main.md> --patch --runs 3 --jobs 1|4 --label j1|j4 --out <dir> --tools <dir with project>

## Only on this machine (scratchpad /private/tmp/claude-502/-Users-alfonso-Workspace-alpibrusl-lexsys/4f089fa1-e2fa-4158-b38c-f84f2540b341/scratchpad)
mfmut.py / mfmut.out (mutation runner and results), mfgates.sh, gl-sh/ gl-dash/ (gate logs), red-multifile.log (RED run of the gate on origin/main driver), analyze_runs.py, analyze_plan.py (result analysers), primer-main.md, evaltools-mf/project, nodebin/node wrapper, mfmain/ (origin/main src for golden), wt/main-check (worktree of origin/main).

## Cancho gap
Filed as alpibrusl/cancho#528 (runner import already bound).

## Still open
The measurement (item 3 above) needs an Anthropic key; not run. No claim about model success on eval/multi is made by this branch.
