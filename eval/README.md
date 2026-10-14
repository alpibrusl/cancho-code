# eval: the audit side of the lex-code backlog (cancho-code#9)

What a built item is judged by, kept apart from the tool that builds it.

- `audit_tokenbucket.py` grades a `07-tokenbucket` build against the backlog's oracle (46 cases, `tokenbucket/oracle.py`, vendored from
  `lex-code/backlog/items/07-tokenbucket/`), by function group, in the brief's shapes and, separately, leniently. `tokenbucket/reference.cho`
  scores 46/46; `scripts/test-eval.sh` pins that, a mutation, and a real model output (`tokenbucket/fixtures/model-int-shapes.cho`) whose
  arithmetic is right and whose shapes are not.
- `reference/<item>/` holds hand-checked implementations of the other seven libraries, written by Claude subagents (not by cancho-code),
  with test files generated from each item's oracle, every case kept. They show an item is expressible in cancho today and are the benchmark
  a cancho-code build is compared with. `scripts/test-reference-ports.sh` pins each suite's pass count. The generators are not included
  (they hard-code scratch paths); the test files are the generated output.

Not here yet: audits for the other items (a build of `01-semver` is not graded by anything in this directory), and the four services.
A reference port is not an audit of a build: the audit must be written before the run and never shown to the builder.


## Runs, metrics, and the task list (this section is newer than the text above)

- `tasks.json`: every item with a difficulty level 1-5 and the rubric behind it. The levels are a hypothesis, assigned after the first runs had started
  and with their (near-universal) success in view; they are not independent of the baseline. 09-12 (services) are not runnable until P7; `bank` is the
  decomposition case (`docs/decomposition.md`).
- Items now with a plan, a hidden oracle, a reference that scores full marks and mutations the audit rejects: `basics` (1), `tokenbucket`, `roman`,
  `base64` (2), `duration`, `editdistance`, `sortedmap`, `jsonptr` (3), `expr`, `glob`, `semver`, `ini`, `csv` (4). `<item>/facts.json` has the sizes.
- `run_item.py <item> --provider ... --model ... --runs N --label L --out DIR` builds an item through `project` with `scripts/cancho-agent.sh`,
  audits it, and writes per run `usage.jsonl` (one line per API call), `raw.txt`, `audit.txt` and `result.json`.
- `metrics.py` defines the numbers (tokens, cost from `prices.json`, `efficiency_calls`, `efficiency`); `report.py DIR [--catalog tasks.json]` tabulates;
  `reanalyze.py DIR` re-reads old runs after a definition changes. Gate: `scripts/test-metrics.sh`, numbers computed on paper.
- `plan_item.py <item> ...` asks a model to PLAN an item from its brief and the signatures of its public functions (`docs/plan-guide.md`), `run_item.py --plan`
  builds that plan, `plan_vs_reference.py` runs a plan's tests against the item's reference, `probe_planner.py` sends vague and huge requests.
  Results and the analysis: `results/2026-10-15-plan-generator.md`.
