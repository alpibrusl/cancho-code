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
