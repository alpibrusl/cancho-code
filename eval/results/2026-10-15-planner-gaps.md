# Planner gaps: what the brief-only build lost, what was fixed, what is left

Starting point: `2026-10-20-one-command-build.md` and `2026-10-21-plain-briefs.md` (brief only, Claude Haiku 5.5, patch mode, review on, 2 runs per item: done 20/26, fully right 14/26, plan failed 2, stuck 3, provider error 1, $0.48).
Raw data: `2026-10-15-planner-gaps.json` (the 52 runs of the two rounds below). Everything here is **2 runs per cell, one model**: item-by-item differences are noise-prone; only the totals and the causes read from the logs carry weight.

## The six gaps, checked against the evidence

| # | what the evidence shows | real? | change |
|---|---|---|---|
| 1 | `[CASES_ERROR] ... give tests instead` named no action; the model flip-flopped between `cases` and `tests` (ini 2: three rounds, three different rejections) | yes | the three "give tests instead" reports now say what to write (delete this unit's `cases`, write `tests`, keep one `examples` entry calling the unit's function, or change to a type `cases` can express, listing them); guide section "When `cases` cannot express a signature" with a worked `tests` unit that `test-planner.sh` compiles, runs and flips |
| 1b | found in the new runs: the model's own `tests` were the next failure. csv (round 1, both runs): a bare `\n` in the JSON text of a test becomes a real line break inside a cancho string, which cannot span lines (the unit could never verify); ini 2 (round 2): `Ok(_)` on a `Buffer` payload ("cannot be discarded") | yes | plan check `bad-test` refuses both with the exact fix (decoded source scanned for a line break inside a string literal; `Ok(_)`/`Some(_)` on the unit's own call when its result owns memory); guide says it. Checked on about 130 generated plans from earlier runs: only the failing ones are flagged |
| 2 | `[REVIEW_ERROR] N-1 answers for N cases` rejected the whole plan and cost a planning round (in the contract-arm and first brief-arm logs; none in the plain-brief runs, but 7 of the 52 runs below) | yes | a miscounted or malformed answer is the reviewer's slip: retried once with the errors in the prompt; if the second answer is also unusable the plan is KEPT, unreviewed, with `the plan stands unreviewed` on stderr (plan.log), `[PLAN_REVIEW] unreviewed` in run.log and `"review":"unreviewed"` in build.json. "Agreed with none of a unit's cases" stays a verdict on the plan |
| 3 | the rounds' feedback showed the rule and the unit, but the message was one generic sentence (`unit-field`) or did not name the function (`no-example`, `example-own`, `example-callee`) | partly | the messages name the missing field and its form, the function the example must call (whole name, prefix included), the callee nobody declares; `tests/plans/messages.txt` pins them. Not a single plain-brief run ended on one of these three rules |
| 4 | see below | mostly not what it looked like | guide section "Cover everything the task states" (unmeasured in isolation) |
| 5 | the unit agent's stderr was dropped (`Stdio::Null`) | yes | `agent-<id>.log` per unit, per attempt (`=== attempt N: exit C after M ms`, last 4096 bytes), `project.cho.agent.err/.log` beside the trail, `[AGENT_LOG]` line in run.log for a unit that did not verify; docs/project.md, docs/build.md |
| 6 | semver (contract arm): three rounds, each 16000 tokens of thinking, no JSON; the feedback said "write a SHORTER plan" | yes | a cut-off round is asked again with the bound doubled (at most 32000); an empty reply is told its thinking used the bound. The same for the unit agent's patch (new, see below) |

## What the logs said once the stderr was kept (gap 5)
The four `provider_error` of round 1 (csv 2, ini 1, ini 2, tokenbucket 1) are **not** provider errors: the unit agent exited 1 after its three samples, either all cut off by the 16000-token bound (the model's thinking used it: ini 2, tokenbucket 1, `a sample was cut off ...` x3, 231-233 s) or all prose (`a sample has no code in it`: ini 1; csv 2, where the model rightly said that the generated test had a line break in a string literal and it could not fix a test). The baseline `ini` run 1 (228 s, no log kept) fits the first pattern; that is an inference. The driver maps any agent exit but 0 to `unavailable agent`, i.e. `provider_error`.
Fix made: the bound grows after a cut-off patch too (round 2: no `provider_error` at all). **Not changed, and worth a decision:** an agent that gives up after its rounds (exit 1) is still reported as `provider_error`; it is a failed unit, and `stuck` would say so.

## Gap 4: the thin examples are not why builds that end `done` score below 100%
Counted on the generated `plan.json` files: hand plans carry 21.7 examples per plan (4.8 units), the model's plans 10.9 (baseline, 25 plans), 11.0 (round 1), 10.7 (round 2) over 6.2-6.7 units; asserts in the generated tests per plan: 59.6, 72.2, 68.7 (the hand plans use examples as tests for many units, so 36.0 is not comparable). With the "cover everything" wording the plans have +15..21% more asserts (26 plans per round: could be noise).
But the score losses of `done` builds are interface shapes, read from the audit's per-function lines (not its cases): `csv_format_line: 0/15 does not build ... is not a borrowed Box`; `closest: 0/9 ... expected List[...], found Vec[...]`; `ptr_parent: 0/19 ... takes 2 arguments, but 1 was given`; `from_roman: 0/246 ... takes 2 arguments, but 1 was given`; `ini_*: 0/76 ... expected &static [byte], found int` (error type). The planner picks a heap parameter or a container type that the audit's caller does not use, and the brief ("name(args)" in words) does not fix it. That is why the signatures arm is at 19/20: the names were never the issue, the parameter lists and types are. A planner rule cannot know them without the oracle; the brief (or the contract) has to state them. The audit files were not used to write any guide text. Auto-extracting the brief's worked examples into cases was not built: with the loss being the call shape and not the coverage, it would not have moved the totals, and the value grammar (`Ok([...])`, `Err`, `..`) is not simple.

## Measurement (budget: $1.25 of 2)
| brief-only arm | build `done` | audit 100% | plan failed | stuck | provider error | output tokens | cost |
|---|---|---|---|---|---|---|---|
| baseline (plain briefs) | 20/26 | 14/26 | 2 | 3 | 1 | 800,668 | $0.481 |
| round 1 (gaps 1-3, 5, 6 as first committed) | 19/26 | 11/26 | 1 | 2 | 4 | 1,035,880 | $0.617 |
| round 2 (+ test rules in the plan check, bound growth for patches) | 22/26 | 15/26 | 0 | 4 | 0 | 1,075,602 | $0.636 |

Round 2 differs from the final branch by one rule (`Ok(_)`/`Some(_)` in tests), added after the measurement: **not measured**. The tokens are about 30% up in both rounds (longer guide, more cases per plan, bigger bounds); cost +30%.

Per item (verdict and audit points, run 1 / run 2):

| item | baseline | round 1 | round 2 |
|---|---|---|---|
| base64 | done 329/329, done 329/329 | same | same |
| basics | done 221/221, plan failed | done, done (221/221) | done, done (221/221) |
| csv | done 35/50, stuck 35/50 | stuck 0/50, provider error 35/50 | done 35/50, stuck 0/50 |
| duration | done, done (64/64) | stuck 22/64, done | done, done |
| editdistance | done 45/54 x2 | same | same |
| expr | done 382/385, 376/385 | 385/385, 373/385 | 385/385, 383/385 |
| glob | done 87/87 x2 | 84/87, 86/87 | 87/87 x2 |
| ini | provider error 0/76, plan failed | provider error 0/76 x2 | done 0/76, stuck 0/76 |
| jsonptr | done 141/160, stuck 104/160 | done 141/160 x2 | stuck 90/160, done 141/160 |
| roman | done 439/439 x2 | plan failed, done 439/439 | done 192/439, done 439/439 |
| semver | done 492/492 x2 | 490/492, 492/492 | 492/492 x2 |
| sortedmap | stuck 75/124, done 124/124 | done 124/124 x2 | done 124/124 x2 |
| tokenbucket | done 46/46 x2 | provider error 22/46, done | done 46/46, stuck 22/46 |

Read honestly: round 2 has no plan failure and no `provider_error`, and the cases-fallback failures of the baseline (csv, sortedmap, ini planning) did not recur; the totals (22 vs 20 done, 15 vs 14 right) are inside what 2 runs per cell can move. The review miscount happened in 7 of the 52 runs (expr x3, glob x2, base64, roman: `N+-1 answers for N cases`, never a wrong answer): the retry gave a usable review 4 times, and 3 plans stand unreviewed (expr round 1 run 2, glob round 2 run 2, base64 round 2 run 1: all built `done`, 373/385, 87/87, 329/329; run.log and build.json say `unreviewed`). Before the change each of the 7 would have rejected a valid plan and cost a planning round.

## What still fails (read from the logs of the failing runs)
- **API shape vs the audit** (csv format, closest, ptr_parent, from_roman, ini x all): above. The largest remaining loss: 6 of the 7 `done` runs of round 2 below 100% (the seventh, expr 383/385, is not diagnosed). Needs the brief or `--contract`.
- **A wrong planner case that the reviewer agreed with**: tokenbucket round 2 run 2, unit `retry`: `retry_after_ms(9999, 1, 1, 10) == 1`, but by the unit's own description the answer is 0 (tokens already suffice); the blind review kept it, the unit trapped on it, `stuck`. One wrong case makes its unit unsatisfiable (docs/plan.md: about 1 in 80).
- **The model's own `tests` for signatures `cases` cannot express**: ini round 2 run 2 (`Ok(_)` discard: now a plan-check error, unmeasured), csv round 2 run 2 (`parse_from`: its test traps for both attempts; not diagnosed), jsonptr round 2 run 1 (`parse`: refused twice with the same signature, not diagnosed further). Making `cases` express an `Option` of a `Box` and a `Result` of a list would remove the need for the fallback in the common cases (a change of `cases.cho` and its Python reference, not made).
- `roman` round 2 run 1: `from_roman` takes 2 arguments (heap) where the audit passes 1.
- Provider/unit-agent exit 1 reported as `provider_error` (above).
- **`brief-name` is now the main cause of plan failures**: roman round 1 run 1 (`to_roman`/`from_roman` not declared by name; the review had passed it), and in the baseline basics run 2 (`clamp`). The check runs in `src/build.cho` after the plan agent has finished, so the model is never told and no round is spent on it. Running the same check inside the agent's rounds (it has `--brief`) would turn these into a corrected plan; not done here (a new gate and an authority look), recommended.

## Gates (all in scripts/, each shown red against origin/main's src and green now)
`test-project` (agent log: per attempt, exit code, bound, unit that fails), `test-build` (`[AGENT_LOG]`, `[PLAN_REVIEW]`, `build.json` `review`), `test-planner` (fallback instruction and the guide's tests unit compiled/run/flipped, review miscount retried/kept unreviewed, cut-off bound), `test-plan` (messages, newline in a string, `Ok(_)` on an owning payload, with valid twins), `test-cases` (the hint text, two new fixtures; differential against `tests/reference/cases_ref.py`), `test-agent-native` (edit-mode bound). Mutations (2-4 per gap) were all killed except weak ones listed in the PR notes. Authority pins unchanged (all seven `check-authority` variants and their `--prove`).

## Reproduce
```
CANCHO=... CANCHO_PACKAGES=... sh scripts/build-agent.sh && sh scripts/build-cancho-build.sh
CANCHO=... python3 eval/run_build.py <item> --provider anthropic --model claude-haiku-5-5 --key-file <path> --workspace <ws> --primer <AGENTS.md> --runs 2 --label pg-brief --out <dir>
```
