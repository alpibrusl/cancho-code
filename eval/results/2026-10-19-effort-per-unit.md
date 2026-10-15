# Thinking budget per unit (`effort` in the plan)

Same experiment as the patch baseline (13 hand-planned items x 3 runs, Claude Haiku 5.5, `--output patch`, same primer and hidden audits); only the plan differs: `eval/effort_policy.py` writes an `effort` into every unit.
Policies: `low` (every unit), `medium` (every unit), `tiered` (description under 500 characters -> low, under 900 -> medium, longer or list/vec result or three or more deps -> the model's default).
Tiers came from the measured thinking per unit (thinking tracks description length, r = 0.72), not from outcomes.

| policy | builds `done` | audit points | output tokens | thinking share | cost | seconds |
|---|---|---|---|---|---|---|
| none (patch baseline) | 38/39 | 7478/7581 | 469,146 | 82% | $0.298 | 2301 |
| **low** | 37/39 | 7322/7581 | **350,146 (-25%)** | 75% | **$0.237 (-20%)** | 1919 (-17%) |
| medium | 38/39 | 7505/7581 | 512,674 (+9%) | 83% | $0.315 (+6%) | 2561 |
| tiered | 38/39 | 7505/7581 | 447,276 (-5%) | 80% | $0.282 (-5%) | 2301 |

Reading:
- `low` is the only policy that moves the cost, and it costs quality: two builds stuck (`roman` run 1 on `from_roman`, `tokenbucket` run 1 on `allow`; both failed signature twice, a signature error not a logic error) and 156 fewer audit points (-2%). The baseline's one miss is `ini` run 1.
- `medium` saves nothing (+9% output tokens): at this level the adaptive default was already thinking about as much.
- `tiered` keeps the baseline's 38/39 and 7505 points and saves 5%: the gain is small because the tiers cover only the short units and the long ones, where most thinking is, keep the default.
- Per item `low` ranges from -56% (`sortedmap`) to +9% (`roman`); `basics` (-53%) and `glob` (-47%) gain most.

Caveats: 3 runs per cell, one model, one set of items that the tiers were read from; one failed run moves a policy by one of 39 builds, so 37/38/38 do not separate the policies on correctness, only the token and cost columns do.
An earlier pass of this experiment was discarded and rerun: the tools used had been built before the feature, so no task carried an `EFFORT:` line and all three arms were the baseline again.
Raw per-run results are in `runs/eff-*` (not committed); aggregate: `2026-10-19-effort-per-unit.json`.
