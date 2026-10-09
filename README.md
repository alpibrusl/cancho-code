# cancho-code

**An assistant for [cancho](https://github.com/alpibrusl/cancho) that proves its work.**

Most coding assistants hand you a transcript and ask you to read the diff.
cancho-code hands you a verdict: every task ends in a machine-readable result
produced by the type checker and by examples written *before* the code, not by
what the model says about itself. A task is a **typed issue** — a contract
with a declared oracle — and *done is a proof the gate evaluates, never a
status anyone sets*.

**Status: design stage; the loop-safety harness and the subprocess driver are built.**

- [`src/loop_check.cho`](src/loop_check.cho) — the §4 loop-safety contracts as pure functions, with their gates in [`tests/loop_check_test.cho`](tests/loop_check_test.cho).
- [`src/signature.cho`](src/signature.cho) — the failure signature built from real `cancho check --output json`, with its gates in [`tests/signature_test.cho`](tests/signature_test.cho).
- [`src/checker.cho`](src/checker.cho) — the subprocess slice: run the real `cancho check` under a narrowed `Exec` capability, capture its answer, map it to the loop's vocabulary. Gated by [`tests/programs/checker_gate.cho`](tests/programs/checker_gate.cho), driven by [`scripts/test-checker.sh`](scripts/test-checker.sh).

The plan and its tasks are in the epic,
[cancho-code#8](https://github.com/alpibrusl/cancho-code/issues/8); the design,
[`docs/design.md`](docs/design.md), is drafted. Its prerequisites in the
compiler are stated as dependencies on filed work
([cancho#401](https://github.com/alpibrusl/cancho/issues/401),
[cancho#411](https://github.com/alpibrusl/cancho/issues/411),
[cancho#406](https://github.com/alpibrusl/cancho/issues/406),
[cancho#403](https://github.com/alpibrusl/cancho/issues/403)), not assumptions —
and one is already measured as mostly built: `cancho check --output json`
answers `rule`/`message`/`position`, plural, today.

## Why

The model it follows is
[lex-code](https://github.com/alpibrusl/lex-code) — and the failure it must
not repeat is lex-code's own, measured and documented there: runs that
continue for a long time without solving anything. This repository treats
loop-safety as first-class contracts with defaults justified by measurement —
attempt ceilings, a same-signature stop rule, progress-not-activity rounds,
snapshot and restore — each with a test where a stand-in loops forever and
the harness asserts the loop stops, in seconds rather than hours.

cancho-code is written in cancho, and runs under the same capability grants it
enforces: the checker itself is started under a narrowed `Exec` capability,
so the tool's own authority report will name the one program it may run.

## Running the gates

```sh
cancho test tests/loop_check_test.cho tests/signature_test.cho src/loop_check.cho src/signature.cho --std --backend cranelift
CANCHO=<path-to-cancho> scripts/test-checker.sh
```

Thirteen unit tests (the loop-safety contracts; the signature and its
normalisation — same failure twice signs identically, reversed direction
signs differently, numbers collapse, a clean check wires as verified) and
three checker cases: a clean file answers `verified`, a refused file answers
`retryable signed`, a checker that never answers answers `provider_outage` —
a wait, not a failure.

## Contributing

Design before code, in [`docs/design.md`](docs/design.md), with claims
measured; a gate is fixed before the code it judges and must be able to fail;
a claim that turns out false is corrected in place. See the epic for the
working rules and the task list.

## Licence

EUPL-1.2, matching the rest of the ecosystem.
