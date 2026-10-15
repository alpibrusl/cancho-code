# The one-command build on the 13 items, from the brief alone and with the signatures

`build/cancho-build` (PR #53) run by `eval/run_build.py` on each item's `brief.txt`: plan (model-written, with the review pass), plan check, build unit by unit, hidden audit. Claude Haiku 5.5, patch mode, 2 runs per item, 26 runs per arm.
**brief**: the planner sees the brief only (what a user gives). **contract**: it also gets the required public signatures (`--contract`, what `eval/plan_item.py` gives it). Raw data: `2026-10-20-one-command-build.json`.

| arm | build ends `done` | audit 100% | plan failed | stuck | provider error | audit points | output tokens | cost |
|---|---|---|---|---|---|---|---|---|
| brief | 13/26 | 9/26 | 9 | 3 | 1 | 3007/3710 | 707,134 | $0.424 |
| contract | 20/26 | 19/26 | 3 | 2 | 1 | 3804/3956 | 858,493 | $0.512 |

Audit points are summed over the runs that produced a program (the planless runs score nothing and are not in the denominator), so compare the "audit 100%" column, not the points.

## Where the brief arm loses (9 plan failures, none of them a failed build)
- **4 x the model asks instead of planning** (`duration` 1, `editdistance` 2, `ini` 2, `tokenbucket` 1; see `plan.json.questions.json` in the run): the briefs are lex-code's, written in Lex (`Str`, `Int`, `::`, `std.str`), and the planner, which builds cancho,
  asks whether it should write Lex or cancho, or whether a function may return a tuple/record. The refusal is reasonable for these briefs; it is a problem with the eval briefs, not with the planner.
- **2 x `cases` cannot express a type** (`csv` 2: `list.List[Box[Box[[byte]]]]`; `sortedmap` 2: `&k [int]`): the planner should have given `tests`, as the plan guide says.
- 3 x plan format slips (a unit missing its fields, `expr` with a unit without an example, `expr` 1: the reviewer gave one answer fewer than cases).
With the contract the failures are 3: `basics` 2 (the new brief-name check refused a plan that lacked `clamp` and `lcm`), `expr` 1 (the reviewer answer count), `semver` 2 (a sample cut off by the bound).

## What the plan's quality does to the audit
A build that is `done` is not always right: `roman` run 2 (brief) is `done` and scores 192/439, `editdistance` 1 45/54, `tokenbucket` 2 34/46, `glob` 1 86/87: the plan's examples held and the audit still found cases they did not cover. With the contract: 19 of 20 `done` builds score 100%.
`ini` run 1 (both arms) ends `provider_error`: the agent for the unit `parse` exited after 228 s (the cause is not in the logs; the unit agent's stderr is not kept - a gap).

## Reading
- From the brief alone, half the builds finish and 9 of 26 are fully right, at $0.016 per run; the largest single loss is the briefs themselves being Lex. With the signatures given, 20 of 26 finish and 19 are fully right.
- The brief-name check (PR #53) holds: no run built under a renamed API; it also cost one run (`basics` 2 contract: the plan dropped `clamp` and `lcm`).
- Caveats: 2 runs per cell; one model; the briefs are Lex-flavoured; the ratios between arms are not separable from this noise item by item, only in aggregate.
