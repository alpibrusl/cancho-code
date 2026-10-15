# A blind second pass over the cases (`--review on`)

Same experiment (13 items x 3 model-written plans, each built once, Claude Haiku 5.5, same builder and audits). New: after a plan passes the plan check, a second call shows the reviewer only each unit's signature,
description and the ARGUMENTS of its cases (never an expected value, never the examples) and asks for the results; `src/review.cho` keeps a case only if the reviewer's value equals the planner's
(a mismatch or a `skip` drops it). A unit that loses all its cases sends the plan back to the planner. Raw data: `2026-10-17-plan-review.json`.

| plans | plan check passes | rounds per plan | builds `done` | audit points | plan cost | build cost |
|---|---|---|---|---|---|---|
| hand-written | 13/13 | - | 38/39 | 7505/7581 (99%) | - | $0.372 |
| model, extended `cases` | 39/39 | 1.51 | 29/39 | 6375/7581 (84%) | $0.329 | $0.452 |
| **model, extended `cases` + blind review** | 36/39 | 2.56 | **33/39** | **7040/7581 (93%)** | $0.395 | $0.418 |

The review dropped 18 of 2,023 cases (0.9%), which matches the 1.2% wrong-value rate measured against the references. Items that went to 3/3 at full marks with it: roman, jsonptr, expr, glob (glob was 1/3, 86/261).
Items that got worse: `sortedmap` (1/3, 124/372; was 2/3), `ini` (1/3, 0/228; the plans for ini passed the plan check only 2 of 3 times), `csv` (1/3; plans valid 2 of 3). With 3 samples per cell, and plans valid 36/39 instead of 39/39,
I cannot say whether those are noise, a review that rejects a plan the planner cannot repair in its three rounds (rounds rose from 1.51 to 2.56), or a reviewer error.

Total cost of planning plus building is about the same (plan $0.395 + build $0.418 = $0.81 against $0.78) while finishing 4 more builds.

Caveats: 3 samples per cell; the guides, expander and reviewer were shaped on these 13 items (not held out); one model, the same model as reviewer and planner (a stronger reviewer is untested).
