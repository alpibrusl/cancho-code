# The agent giving up is not a provider error; the brief-name check inside the plan rounds

Two changes (branch `agent-exit-brief-names`), measured on the brief-only arm (13 items x 2 runs, Claude Haiku 5.5, patch mode, review on, the same primer and guide as `2026-10-15-planner-gaps.md`). Raw data: `2026-10-16-agent-exit-brief-names.json`. **2 runs per cell, one model: item-by-item differences are noise; only the totals and the causes read from the logs carry weight.**

## What changed
- **A. The agent's exit codes** ([docs/project.md](../../docs/project.md#the-agents-exit-codes)). The unit agent exits 10, 11 or 12 when it reached the model and every sample was cut off by the bound, held no program, or could not be spliced. The driver counts that as a failed attempt with the signature `agent:gave-up:cut-off|no-program|splice`: the attempt ceiling and the same-signature stop apply, the unit ends `stuck` (verdict `stuck`, exit 1), the journal outcome stays `agent_failed` and carries the signature, `run.log` has `[UNIT_WHY]`. Any other non-zero exit (1 = unreachable / HTTP error, a third-party agent's codes, a timeout, a signal) keeps its meaning: `unavailable agent`, `provider_error`, exit 4.
- **B. `brief-name` in the plan agent's rounds.** `plan.brief_report` (moved from `src/build.cho` to `src/plan.cho`) runs after `plan.check` in each round of `cancho-agent --mode plan`; the report lists every missing name with the action (declare `fn <name>` with exactly this name; the brief states it). `build` keeps the check as the backstop for a reused `plan.json`.

## Measurement ($0.66 of about $1)
| brief-only arm | build `done` | audit 100% | plan failed | stuck | provider error | output tokens | cost |
|---|---|---|---|---|---|---|---|
| baseline (plain briefs) | 20/26 | 14/26 | 2 | 3 | 1 | 800,668 | $0.481 |
| round 2 of the planner gaps (before) | 22/26 | 15/26 | 0 | 4 | 0 | 1,075,602 | $0.636 |
| this branch | 21/26 | 16/26 | 0 | 5 | 0 | 1,108,415 | $0.659 |

Per item (verdict and audit points, run 1 / run 2): base64 done 329/329 x2; basics done 221/221 x2; csv done 35/50 x2; duration done 64/64 x2; editdistance done 0/54, stuck 0/54; expr done 385/385 x2; glob done 87/87 x2; ini stuck 0/76, done 0/76; jsonptr done 141/160, stuck 79/160; roman done 439/439 x2; semver done 492/492 x2; sortedmap stuck 75/124, stuck 99/124; tokenbucket done 46/46 x2.

## What the logs say about the two changes
- **Brief-name inside a round: 1 of 26 runs** (tokenbucket run 2): round 1 renamed `retry_after_ms`, the check refused it in the round with the exact action, round 2 declared it, the build was `done` 46/46. Before, that plan would have been refused by `build` after the agent finished (`plan_failed`, exit 3). The previous round had no `brief-name` failure in its 26 runs (it had two in earlier rounds: roman and basics), so one occurrence in 26 is what to expect; the check is a safety net whose rate is low, not a lever on these totals.
- **Agent gave up: 0 of 26 runs.** All 182 unit-agent turns exited 0 (`agent-<id>.log` headers), none exited non-zero, so this sample says nothing about the new mapping; what shows it works is the gates (below). The previous round's `provider_error` were already gone after the bound-growth fix; the five `stuck` here are acceptance failures that the same-signature stop ended (`editdistance` 2, `ini` 1, `jsonptr` 2, `sortedmap` 1, 2).
- The totals (21 vs 22 done, 16 vs 15 right) are inside what 2 runs per cell can move. `editdistance` 0/54 (the baseline had 45/54) is the interface-shape gap again (`edit_distance takes 3 arguments, but 2 were given`: the planner chose a heap parameter the audit does not pass), not a result of these changes.

## Gates
Red against origin/main's src, green now: `test-agent` (gave up: three codes, signature, outcome, ceiling with alternating reasons, a gave-up turn then a fix verifies, plain exits 1 2 3 4 9 13 127 still `unavailable`), `test-project`, `test-build`, `test-journal` (gave up; plain failure unchanged), `test-planner` (round 1 renames, round 2 fixes, both rounds in the journal; both missing names reported at once), `test-agent-native` and `-ollama` (exit 10 / 11 for the all-cut-off and the no-program cases, exit 1 for an unreachable server or an HTTP error), `test-board` (a new fixture `stuck-agent`: a unit that ended stuck on `agent:gave-up:cut-off` renders in the Stuck column and the independent oracle agrees). Mutations, each red: gave-up code mapped back to unavailable (10), signature empty, reasons collapsed (ceiling case red), journal name lost, `[UNIT_WHY]` lost, the native agent exiting 1 for a give-up, trail outcome `refused`; the in-round check removed, the report not fed back, only the first missing name, the action text lost, the build backstop removed. All gates also run green under `dash`. Authority pins unchanged (all seven variants).

## Reproduce
```
CANCHO=... CANCHO_PACKAGES=... sh scripts/build-agent.sh && sh scripts/build-cancho-build.sh
CANCHO=... python3 eval/run_build.py <item> --provider anthropic --model claude-haiku-5-5 --key-file <path> --workspace <ws> --primer <AGENTS.md> --runs 2 --label ae-brief --out <dir>
```
