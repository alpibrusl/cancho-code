# cancho-code

**An assistant for [cancho](https://github.com/alpibrusl/cancho) that proves its work.**

Most coding assistants hand you a transcript and ask you to read the diff.
cancho-code hands you a verdict: every task ends in a machine-readable result
produced by the type checker and by examples written *before* the code, not by
what the model says about itself. A task is a **typed issue** — a contract
with a declared oracle — and *done is a proof the gate evaluates, never a
status anyone sets*.

**Status: design stage; the first code is the loop-safety harness.** The
decision module [`src/loop_check.cho`](src/loop_check.cho) and its gates
([`tests/loop_check_test.cho`](tests/loop_check_test.cho) — 9 tests, all
passing under `cancho test`) are built: every loop-safety contract of the
design has a test where a stand-in loops and the assertion is that the loop
stops, named. The plan and its tasks are in the
epic, [cancho-code#8](https://github.com/alpibrusl/cancho-code/issues/8); the
design, [`docs/design.md`](docs/design.md), is drafted: the typed issue and
project model, the loop-safety contracts with their proposed defaults, the
verdict vocabulary, the gates fixed before the code they judge, and the
authority row of the tool itself. Its prerequisites in the compiler are
stated as dependencies on filed work
([cancho#401](https://github.com/alpibrusl/cancho/issues/401),
[cancho#411](https://github.com/alpibrusl/cancho/issues/411),
[cancho#406](https://github.com/alpibrusl/cancho/issues/406),
[cancho#403](https://github.com/alpibrusl/cancho/issues/403)), not assumptions.

## Why

The model it follows is
[lex-code](https://github.com/alpibrusl/lex-code) — and the failure it must
not repeat is lex-code's own, measured and documented there: runs that
continue for a long time without solving anything. This repository treats
loop-safety as first-class contracts with defaults justified by measurement —
attempt ceilings, a same-signature stop rule, progress-not-activity rounds,
snapshot and restore — each with a test where a stand-in loops forever and
the harness asserts the loop stops, in seconds rather than hours.

cancho-code will be written in cancho, and will run under the same capability
grants it enforces: no effect the session was not granted, whatever the prompt
says, and an authority report pinned in CI.

## Running the gates

```sh
cancho test tests/loop_check_test.cho src/loop_check.cho --std --backend cranelift
```

Nine tests: the looping agent stops at the same-signature stop; the
struggling agent gets its full ceiling; a plan defect is never retried; a
provider outage stops the run with the attempts preserved; verified beats
the ceiling; a round without new units or scenarios is not progress; two
stagnant rounds stop the run.

## Contributing

Design before code, in [`docs/design.md`](docs/design.md), with claims
measured; a gate is fixed before the code it judges and must be able to fail;
a claim that turns out false is corrected in place. See the epic for the
working rules and the task list.

## Licence

EUPL-1.2, matching the rest of the ecosystem.
