# PRE-FIX: M8 phase 0: the untuned Qwen2.5-1.5B-Instruct on the 13 hand-planned items (arms A and B)

Experiment M8 of cancho-gpu (`docs/roadmap-models.md` section 7): does a small local model fine-tuned on cancho do cancho-code's job better than the same model untuned? This file is the untuned half: arm A (the standard primer in context) and arm B (no primer). The tuned arms C and D are a later phase; the decision rule is pre-registered in that document. Raw numbers: `2026-11-03-m8-base-arms.json` (per run); the run directories (journals, prompts, replies) are kept outside git.

> **Pre-fix baseline, kept for the record.** Run before the two harness defects below were fixed (the refusal excerpt from the wrong file; the generic `no-program` for code without an `edition N;` line). Because the fixes change the feedback the model sees, arms A and B were re-run from scratch: see `2026-11-03-m8-base-arms-fixed.md`. Both files precede any tuned result.

## Conditions

* Model: Qwen2.5-1.5B-Instruct, f16 weights on the Metal GPU, served by `cancho-gpu/examples/qwen/serve_ollama.py` (an Ollama-API endpoint, port 11435; the agent's `--provider ollama --port 11435`). Chat template of Qwen2.5 around the prompt as one user turn; temperature 0.2 (sent by the agent), top-k 20, top-p 0.8, no repetition penalty; seed = request number (logged). One process, one model, both arms.
* Harness: `eval/m8_arm.py` -> `eval/run_item.py <item> --plan eval/<item>/plan.json`, 13 items x 5 runs per arm (65 runs each). cancho-code defaults: complete-file replies, 6 attempts a unit, same-signature stop, one unit at a time, 300 s a call; `--num-ctx 16384`, `--max-tokens 2048`.
* Primer (arm A): `cancho agent-guidelines` of the local compiler (`cancho 0.0.0 rev a49ea779-dirty`; cancho-code pins f4ead82): 37,983 bytes, 10,666 Qwen tokens (sha256 799c4cd3...ecced). Arm B: none.
* Judge: the hidden oracle of each item (`eval/audit_<item>.py`), 0 when the run did not build. Reference: Claude Haiku 5.5 on the same items (`2026-10-14-haiku-5-5.txt`): 38 of 39 builds finished, 7505/7581 oracle points. Claude was not re-run.

## Result

| arm | runs | oracle pass fraction, mean (95% bootstrap CI, h) | units verified | first-attempt compile (units) | after the fix loop | pass@1 | verified within 4 attempts | attempts/run |
|---|---|---|---|---|---|---|---|---|
| A base + primer | 65 | 0.012 (0.003 to 0.024; h 0.011) | 20 of 315 | 0.213 (178 units tried) | 0.118 | 0.112 | 0.118 | 5.7 |
| B base | 65 | 0.000 (h 0) | 0 of 315 | 0.000 (165 units tried) | 0.000 | 0.000 | 0.000 | 5.1 |
| Haiku 5.5 (reference, 3 runs/item) | 39 | 0.99 | | | | | | |

All 130 runs ended `stuck`. Only two items scored above 0 in A: tokenbucket 0.117 and sortedmap 0.040 (per item table in the JSON). Per-run first-attempt compile rate of A: 0.193 (h 0.061).

## Reading

* **The floor effect applies.** S(A) = 0.012 < 0.02 and S(B) = 0: the pre-registered rule declares both pairs floor-limited, so the tuned arms will be judged on the secondary measures (first-attempt compile rate, refusal tags) as well. "Pass fraction" cannot separate arms here; "units verified" (20 against 0) and "first-attempt compile" (0.213 against 0) can, and the primer clearly helps: it is the difference between "no program" and "a program the compiler reads".
* **Why B is exactly zero: format, not language.** cancho-code takes a reply as a program only if a line starts `edition N;`. Arm B's 312 non-verified attempts are all `agent:gave-up:no-program` (plus 20 `cut-off`): the model repeats the task text in a ```csharp / ```cpp fence (example: `B-roman-1`) and never writes code. In A the top tags are `no-program` 83, `type-mismatch` 82, `duplicate-declaration` 75 (the model re-writes `fn main`, which the driver already has), `acceptance` 35, `module-not-imported` 28, `cut-off` 20. So a tuned model that learns the reply format alone would move B off zero; the experiment's compile-rate measure is what shows whether it learned the language.
* Where A verified units, they are the shortest ones (tokenbucket, sortedmap, some of expr/ini/editdistance); no item was finished.

## Serving numbers (measured, `requests-AB.jsonl`, 1,635 requests, machine shared with other jobs)

Prompts of 10.9 to 11.1 k tokens in A, short in B. Prefill of the primer: 5.8 s once (maximum), then the cached prefix is reused (median prefill 0.014 s). Decode: mean 61.7 tokens a second over requests (short replies; about 12 to 25 tok/s on a long context in the pilot, 20 to 80 on a short one, noisy under load), median request 3.7 s, maximum 169 s; 116 requests ended at the length bound. Wall time: A 2.0 h, B 1.8 h. Greedy output of the shim equals transformers' on the same f16 weights (4 prompts of 32 to 96 new tokens, with and without the 10.7 k-token primer and prefix reuse: identical), `examples/qwen/check_serve.py`.

## Caveats and defects found

* One model, one machine, temperature 0.2 so runs differ; 5 runs an item. The compiler is a local dirty build, not the pinned rev. The model is served as f16 transformers, not a quantised Ollama build.
* A harness defect, unfixed here (eval only): the refusal text shown to the model quotes the source line from `project.cho` using the line number of the file the compiler named (`main.cho`), so the caret points at an unrelated line (`A-basics-1`, unit `leap`: "line 3 ... function `main` is defined twice" shows `import std.math;`). It misleads exactly the refusals that name another file.
* The agent treats a reply with no `edition N;` line as "no program" even when code is present; small models are exposed to this more than Claude.
* Unit-level "pass@4" is not available as independent samples; "verified within 4 attempts" is reported instead (the loop feeds the refusal back).
