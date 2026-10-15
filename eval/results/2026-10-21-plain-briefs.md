# Plain-language briefs: the brief-only build again

The first brief-only run (`2026-10-20-one-command-build.md`) lost 4 of its 9 plan failures to the briefs themselves: they were lex-code's, written in Lex (`Str`, `x :: Int`, "a Lex library package"), and the planner asked which language to write.
The 13 eval briefs and the 4 service briefs are now plain language (the public names kept as `- name(args) : what it does`, types in words, no other language named), and `scripts/test-briefs.sh` fails on the word Lex,
on `Str`/`Int`/` :: `/`List[` notation in a brief, a guide or a prompt string (it is red on the old briefs, and red when contamination is injected into a brief, a guide or a source prompt literal). The prompts, guides and primer had no Lex content already.

Same experiment, same setup (Claude Haiku 5.5, patch mode, review on, brief only, 2 runs per item). Raw data: `2026-10-21-plain-briefs.json`.

| brief-only arm | build `done` | audit 100% | plan failed | stuck | provider error | output tokens | cost |
|---|---|---|---|---|---|---|---|
| Lex-flavoured briefs | 13/26 | 9/26 | 9 | 3 | 1 | 707,134 | $0.424 |
| **plain briefs** | **20/26** | **14/26** | **2** | 3 | 1 | 800,668 | $0.481 |
| (with the signatures, for reference) | 20/26 | 19/26 | 3 | 2 | 1 | 858,493 | $0.512 |

- No run asks a question instead of planning. The 2 plan failures: `basics` 2 (the plan dropped `clamp`: the brief-name check refused it) and `ini` 2 (cases cannot express an `Option` type and a unit with no example of its own function).
- More plans now reach the build, so more builds can be wrong: of the 20 `done` builds, 14 are fully right on the hidden audit; the others score from 35/50 (`csv`) to 382/385 (`expr`). The plan's own examples held and the audit found what they did not cover - the planner writes thinner examples than the hand plans.
  With the signatures given, 19 of the 20 `done` are fully right, so the remaining gap is mostly the API: the planner picks signatures the audit does not call (it is graded against the hand plan's signatures), not logic.
- Caveats: 2 runs per cell, one model; the plain briefs were written by the same hand that wrote the previous ones, and the audits are unchanged.
