# The extended expander: any byte, lists and vecs of text, integer error payloads

Same experiment again (13 items x 3 plans, each built once, Claude Haiku 5.5, same builder and audits). Changes since `2026-10-16-plan-generator-cases.md`: `src/cases.cho` also expresses any byte
in a text (`{"bytes": [...]}`), lists and vecs of text, integer error payloads (`{"err": 3}`), Option/Result-of-Option and `Box[[byte]]`; the guide tells the model to leave out a case whose
result needs heavy arithmetic. Raw data: `2026-10-16-plan-generator-extended-cases.json`.

| plans | plan check passes | rounds per plan | builds `done` | audit points | plan cost | build cost |
|---|---|---|---|---|---|---|
| hand-written | 13/13 | - | 38/39 | 7505/7581 (99%) | - | $0.372 |
| model, test code (round 1) | 36/39 | 1.72 | 12/39 | 4176/7581 (55%) | $0.369 | $0.380 |
| model, `cases` | 31/39 | 1.95 | 18/39 | 5542/7581 (73%) | $0.423 | $0.297 |
| **model, extended `cases`** | **39/39** | 1.51 | **29/39** | **6375/7581 (84%)** | $0.329 | $0.452 |

Per item (done of 3, audit points of the maximum): basics 3/3 full, base64 3/3 full, tokenbucket 3/3 full, duration 3/3 full, editdistance 3/3 full, semver 3/3 full, roman 2/3 (1070/1317),
sortedmap 2/3 (248/372), csv 2/3 (115/150), expr 2/3 (770/1155), jsonptr 1/3 (392/480), glob 1/3 (86/261), ini 1/3 (76/228; the hand plan: 2/3, 152/228).
Plans for `ini` and `csv`, which were never valid before, now pass the plan check 3/3 each.

What is still short of the hand-written plans: 10 builds that do not finish and 1206 audit points. Where, from the earlier analysis (same method, `2026-10-16-plan-generator-cases.md`): wrong
expected values in some cases, descriptions that state fewer edge rules than the hand-written ones, finer decomposition with helper contracts nothing checks. glob (1/3) and expr (2/3) are the two where
the model-written plans regressed against the previous round, which with 3 samples per cell may be noise.

Caveats: 3 samples per cell; the guide and expander were shaped on these 13 items (not held out); one model.
