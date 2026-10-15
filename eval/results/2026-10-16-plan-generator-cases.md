# The planner writes test DATA (`cases`), a program writes the test code

Same experiment as `2026-10-15-plan-generator.md` (13 items x 3 plans, each built once, Claude Haiku 5.5, same builder, same hidden audits). What changed: the model writes
`cases` (arguments and expected values) instead of test code, `src/cases.cho` generates the tests from each unit's signature, and the agent expands them before the plan
check (docs/plan.md, "cases"). Raw data: `2026-10-16-plan-generator-cases.json`.

| plans | plan check passes | rounds per plan | builds `done` | audit points | plan cost | build cost |
|---|---|---|---|---|---|---|
| hand-written | 13/13 | - | 38/39 | 7505/7581 (99%) | - | $0.372 |
| model, test code (round 1) | 36/39 | 1.72 | 12/39 | 4176/7581 (55%) | $0.369 | $0.380 |
| model, test code (round 3, last of that line) | 31/39 | 2.38 | 12/39 | 3891/7581 (51%) | $0.535 | $0.321 |
| **model, `cases`** | 31/39 | 1.95 | **18/39** | **5542/7581 (73%)** | $0.423 | $0.297 |

Per item (done of 3 / audit points): basics 1/579 of 663, roman 1/685 of 1317, base64 **2/924 of 987**, tokenbucket 2/114 of 138, duration 1/128 of 192, editdistance 0/135 of 162,
sortedmap **3/3 full**, jsonptr 0/98 of 480, expr 2/770 of 1155, glob **3/3 full**, semver **3/3 full**, ini 0/0, csv 0/0.

## What is left
The three items whose plans are still not valid or not buildable are exactly the ones whose signatures use types `cases` cannot express yet:
- **csv** and **jsonptr** pass and return lists of text (`list.List[Box[Box[[byte]]]]`); the model falls back to writing test code, often leaving both `cases` and `tests` on a unit
  (refused: "give cases OR tests"), or gives a unit no example once its expansion failed.
- **ini** uses CRLF in its inputs; a carriage return is refused as "cannot be written in a cancho string literal" (the expander supports `\n` and `\t` only).
- **editdistance** passes a `vec.Vec` of text to `closest`.
So the next steps are mechanical and gated the same way: more escapes in literals, lists of text and vecs of text as arguments and results.

Caveats: 3 samples per cell; the guide and the expander were shaped on these 13 items; one model.
