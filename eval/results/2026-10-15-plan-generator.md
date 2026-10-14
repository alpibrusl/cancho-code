# Model-written plans vs hand-written plans (Claude Haiku 5.5, 13 items, 3 plans per item, each built once)

The planner (`cancho-agent --mode plan`, guide `docs/plan-guide.md`) saw only each item's `brief.txt` and the signatures of its public functions. It never saw
the hand plan's descriptions, examples, tests or decomposition, nor the oracle. The built project is graded by the same hidden audit as the hand plan.
Same builder, same model, same language page. Raw data: `2026-10-15-plan-generator.json`.

| plans | plan check passes | rounds per plan | builds `done` | audit points | plan cost | build cost |
|---|---|---|---|---|---|---|
| hand-written (baseline) | 13/13 | - | 38/39 | 7505/7581 | - | $0.372 |
| round 1: guide + plan check | 36/39 | 1.72 | 12/39 | 4176/7581 | $0.369 | $0.380 |
| round 2: + rule `needs-tests` | 37/39 | 2.23 | 13/39 | 3644/7581 | $0.486 | $0.402 |
| round 3: + rule `bad-test`, guide shows the heap-test form | 31/39 | 2.38 | 12/39 | 3891/7581 | $0.535 | $0.321 |

What moved between rounds (3 samples per cell, so small differences are noise): `expr` and `glob` went to 3/3 in round 3; `sortedmap`, `tokenbucket`
and `semver` got worse; `ini` was 0/3 every round (the hand plan was 2/3).

## Why builds fail

Rounds 1-2, 26 failed units checked by running each unit's test file against the project: 23 had a model-written test file that cannot be built
(a test taking `World` and calling `split`: 13; other compile errors: 10). The plan check cannot see that. Rounds 2-3 added two rules for the
shapes seen (`needs-tests`, `bad-test`); the first kind then disappeared (13 -> 0), and the remaining failures (round 3, 21 units, classified on the
builder's last written code) are still test files that do not compile against the unit's own signature: wrong argument count, wrong type, a name
that does not exist, an import clash. Only 1 of 21 was a test that built and failed.

Conclusion: **decomposition is not what fails; the plan's tests are.** A model writes test code against signatures it chose, nothing compiles it before
the build, and the builder then burns its attempts on an unsatisfiable unit. The fix is to compile the plan's tests against stubs of its own
signatures before the plan is accepted (feeding the compiler's errors back like the plan check's). `cancho` has no way to declare a function without
a body: a stub must return a value of any type and keep its effect row exact, which a diverging body does not do (`can finish without returning`,
`declares heap but never performs it`). That is the missing piece, not a prompt.

## Probes (`eval/probe_planner.py`, 3 runs each)

| request | outcome |
|---|---|
| "Create the software for a bank." | `too_big`, 6-10 modules (accounts, ledger, storage, auth, api, audit...), 3/3 |
| lex-code 12-kvstore brief (a service with storage and a network API) | `too_big`, 5-7 modules, 3/3 |
| "Write some text utilities." | `unclear`, 4 specific questions each time, 3/3 |
| "Return the larger of two integers..." | a plan of 1 unit, 3/3 |

The request-classification half works; the plan-writing half does not yet.
