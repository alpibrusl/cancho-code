# cancho-code

**An assistant for [cancho](https://github.com/alpibrusl/cancho) that proves its work.**

Most coding assistants hand you a transcript and ask you to read the diff.
cancho-code hands you a verdict: every task ends in a machine-readable result
produced by the type checker — not by what the model says about itself. A task
is driven by a loop bounded by contracts, and *done is a proof the gate
evaluates, never a status anyone sets*.

**Status: the loop is built and gated.** The decision module, the failure
signature, the subprocess checker, the snapshot ring, the composed driver with
its `[ISSUE_VERDICT]` lines, the Mistral provider over native HTTPS, the
Ollama agent, and the `fix` front door — all in cancho, all gated.

```sh
# Build the tool.
"$CANCHO" build tests/programs/fix.cho src/driver.cho src/checker.cho \
    src/signature.cho src/loop_check.cho src/snapshot.cho \
    --std --backend cranelift -o ./fix

# Fix a broken program with a local model (no key, no egress).
ollama pull qwen3.8:27b
export OLLAMA_MODEL=qwen3.8:27b
./fix "$CANCHO" demo/wordcount.cho "$(pwd)/scripts/agent-ollama.sh" 4
[ISSUE_VERDICT]	verified	attempts 2
```

The model edits the file; the real `cancho check --output json` is the only
oracle; a looping model stops at the same-signature rule, a struggling one
gets its full ceiling; a verified answer is checked *again* before it is
believed, then snapshotted. Exit 0 is a proof.

A cloud model works the same way — `scripts/test-provider.sh mistral` with
`MISTRAL_API_KEY` in the environment runs the end-to-end gate against the
real API, the checker still the oracle.

## Running the gates

```sh
cancho test tests/loop_check_test.cho tests/signature_test.cho src/loop_check.cho src/signature.cho --std --backend cranelift
CANCHO=<path> scripts/test-checker.sh
CANCHO=<path> scripts/test-snapshot.sh
CANCHO=<path> scripts/test-driver.sh
CANCHO=<path> CANCHO_PACKAGES=<compiler>/packages scripts/test-provider.sh build
```

Thirteen unit tests and three gate suites — each §4 contract with a case
where a stand-in loops forever and the assertion is that the loop stops,
named, in seconds rather than hours. All green without a network or a key.

## Why

The model it follows is
[lex-code](https://github.com/alpibrusl/lex-code) — and the failure it must
not repeat is lex-code's own, measured and documented there: runs that
continue for a long time without solving anything. Loop-safety is contracts
here, not tuning flags, and the gates found four silent false-passes in this
repository's own code on the way (each one recorded where it was fixed).

cancho-code is written in cancho and runs under the same capability grants it
enforces: the checker and the agent run under a narrowed `Exec` capability,
and the tool's authority report will name the one directory each may live in.

## Project page

[`docs/index.html`](docs/index.html), served at
`alpibrusl.github.io/cancho-code` once GitHub Pages is enabled for this
repository (Settings → Pages → Deploy from branch `main`, folder `/docs`).

## Contributing

Design before code, in [`docs/design.md`](docs/design.md), with claims
measured; a gate is fixed before the code it judges and must be able to fail;
a claim that turns out false is corrected in place. See the epic
([#8](https://github.com/alpibrusl/cancho-code/issues/8)) for the working
rules and the task list.

## Licence

EUPL-1.2, matching the rest of the ecosystem.
