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

## Hand-written plans against the generated ones: where the generated ones go wrong (gen4, 36 valid plans)

Method: (a) each generated plan's cases were expanded and run against the item's hand-checked `reference.cho` for the units the reference defines (`eval/plan_vs_reference.py`); (b) the
14 units that failed to build in the 18-of-39 evaluation were classified by running the unit's generated tests against the builder's last written code; (c) sizes were compared.

| where it goes wrong | evidence |
|---|---|
| **Wrong expected values in the cases** (the model asserts a result it cannot compute) | 9 of 93 judged public units have at least one case the reference contradicts (10 of 858 tests, 1.2%); each makes its unit unsatisfiable. Concentrated in arithmetic: `tokenbucket` 5 units (6 tests), `basics` 2 (e.g. `pow_mod(2, 2^62, 3000000000) == 1`; the true value is 2631894016), `base64` 1, `duration` 1. |
| **Types `cases` cannot express yet** | 7 judged units have a test file that does not build (editdistance 3, jsonptr 2, sortedmap 1, tokenbucket 1); `csv` and `ini` produced no valid plan in any of 3 tries. Being fixed by the expander extension (bytes, lists, vecs, integer error payloads). |
| **Thinner descriptions** | Generated descriptions are 40-50% shorter than the hand-written ones for the rule-heavy items (roman 549 vs 698 chars per unit, base64 531 vs 986, duration 536 vs 719, expr 424 vs 839, glob 413 vs 649, semver 305 vs 710): fewer stated edge rules for the builder. This is the likeliest cause of the failures where the cases are right and the builder still fails (duration `parse_from`, base64 `encode`), but it is inferred, not isolated: helper units are not in the references, so their cases cannot be judged. |
| **Finer decomposition** | 5-10 units where the hand plans use 2-6 (duration 6.3 vs 2, semver 10.3 vs 6, base64 6.0 vs 2): more units to get right and more helper contracts that nothing checks. Not shown to be harmful by itself: `sortedmap`, `glob` and `semver` build 3/3 at full marks with it. |

Of the 14 failed units: 9 failed one of their own generated tests on the builder's last code (wrong case or a builder that lacked the rule), 5 did not compile their test file (editdistance 3, jsonptr 1, roman 1).
So the failure is no longer "the test code does not compile" (23 of 26 before) but "the expected values or the rules in the description are wrong or missing".

## What would fix each
- wrong values: have the model give the *derivation* only where the value is simple, and let a program compute expected values it cannot (a reference implementation, when one exists, or no case: a missing case is
  a smaller loss than a wrong one); re-check each generated case against the unit's own description in a second model pass; never accept cases whose result needs big-number arithmetic.
- thin descriptions: a rule-coverage check against the brief (every rule sentence of the brief must be traceable to a description sentence and a case), as a second pass that lists uncovered rules.
- unexpressible types: the expander extension in progress.
