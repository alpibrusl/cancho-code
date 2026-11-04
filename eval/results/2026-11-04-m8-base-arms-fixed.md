# M8 phase 0 re-run: the untuned Qwen2.5-1.5B-Instruct on the 13 hand-planned items, under the fixed harness (arms A and B)

Replaces `2026-11-03-m8-base-arms-prefix.md` as the baseline of experiment M8 (cancho-gpu `docs/roadmap-models.md` section 7). Same model, items, runs (13 x 5 per arm), settings and shim; what changed is the harness (cancho-code #113): a refusal in another file (the driver's `main.cho`) is named by its file instead of being shown over a line of `project.cho`; a reply with code and no `edition N;` line is `agent:gave-up:no-edition` (exit 13), and the next turn is told "your last reply had code in it but no `edition N;` line ...", where before it was the generic `no-program`. What counts as a verified program is unchanged. Written before any tuned result exists; the pre-registered rule is unchanged. Per-run numbers: `2026-11-04-m8-base-arms-fixed.json`.

A first attempt at this re-run was discarded: it used a `project` driver binary built before the fix (the driver did not know exit 13 and ended 16 runs `provider_error`). The driver and agent were rebuilt from `main` and everything was re-run; the discarded runs are not used.

## Result

| arm | runs | oracle pass fraction, mean (95% bootstrap CI, h) | units verified | first-attempt compile (units tried) | after the fix loop | pass@1 | verified within 4 attempts | attempts/run |
|---|---|---|---|---|---|---|---|---|
| A base + primer | 65 | 0.012 (0.003 to 0.024; h 0.011) | 18 of 315 | 0.191 (173) | 0.104 | 0.104 | 0.104 | 5.6 |
| B base | 65 | 0.000 (h 0) | 0 of 315 | 0.000 (165) | 0.000 | 0.000 | 0.000 | 5.3 |
| pre-fix A (for comparison) | 65 | 0.012 (0.003 to 0.024) | 20 of 315 | 0.213 | 0.118 | | | 5.7 |
| Haiku 5.5 (reference) | 39 | 0.99 | | | | | | |

All 130 runs ended `stuck`. Per-run first-attempt compile rate of A: 0.170 (h 0.061). Only tokenbucket (0.157) scores above 0 in A. Refusal tags, A: duplicate-declaration 144, type-mismatch 70, **no-edition 29**, acceptance 28, module-not-imported 22, not-a-function 17, cut-off 16 (the rest under 10). B: no-program 318, cut-off 24.

## Reading

* **The floor effect still applies and the baseline did not move**: S(A) = 0.012 < 0.02 and S(B) = 0, as before the fixes; the difference between the pre-fix and fixed A (0.012 both; 20 and 18 verified units, 0.213 and 0.191 compile) is inside run-to-run noise (temperature 0.2, 5 runs an item). Both pairs are floor-limited under the rule; tuned arms are read on first-attempt compile rate and tags too.
* The fixes did what they were for, but not enough to matter for this model. Of A's non-verified attempts 29 are now `no-edition` instead of the generic no-program (the pre-fix A had 83 no-program; the model, told what is missing, usually wrote an edition line next time: the dominant tag became `duplicate-declaration`, the model re-writing `fn main`, 144 times). B is untouched by the fix, as expected: its replies contain no code at all (the task text echoed in a fence), so they stay `no-program`.
* Serving: 1,530 requests; median request 3.5 s, mean 66.2 decode tokens a second over requests, maximum 121 s, 134 ended at the length bound. Wall time A 1.5 h, B 2.2 h (the machine was shared).
