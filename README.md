# cancho-code

**An AI coding assistant that proves its work.**

Most assistants hand you a transcript and ask you to read the diff. cancho-code
hands you a verdict. The [cancho](https://github.com/alpibrusl/cancho) compiler
checks every piece the model writes, and a task is *done* only when the
compiler and the task's own examples say so — never because the model says so.

```
[UNIT]            char_count   building
  attempt 0  refused   expected an expression, found `if`    <- the compiler's answer goes back to the model
  attempt 1  verified
[ISSUE_VERDICT]   verified     attempts 2
[PROJECT_VERDICT] done
```

- **Describe it, get a plan, get a build.** A brief becomes a plan of small
  units, each with a signature and examples; each unit is built and checked on
  its own.
- **Loops stop.** Attempt ceilings and a same-refusal stop rule end a stuck
  run, named, instead of burning money.
- **Any model.** Claude (API key) or a local model through Ollama. You choose
  the provider and the model every time; there is no default.
- **Measured.** On 13 library tasks × 3 runs with Claude Haiku 5.5: 38 of 39
  builds finished and passed the hidden audits, for $0.30 in total.
  Conditions and caveats are in [`eval/results`](eval/results).

**[Project page](https://alpibrusl.github.io/cancho-code)** ·
[Guide: run it end to end](docs/guide.html) ·
[Reference: every flag, contract and gate](docs/reference.md)

## Try it

```sh
git clone https://github.com/alpibrusl/cancho-code.git && cd cancho-code
export CANCHO=<path-to-the-cancho-binary>      # the commit named in .cancho-rev
scripts/build-agent.sh                         # the agent is itself a cancho program
```

Then follow the [guide](docs/guide.html) (a local model, no key) or the
[Claude section of the reference](docs/reference.md#a-claude-agent).

## More

[Design](docs/design.md) · [Plans](docs/plan.md) · [Projects](docs/project.md) ·
[Epic and working rules](https://github.com/alpibrusl/cancho-code/issues/8)

EUPL-1.2.
