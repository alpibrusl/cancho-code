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

- **Describe it, get a plan, get a build — in one command.** A brief becomes a
  plan of small units, each with a signature and examples; each unit is built
  and checked on its own. The functions your brief names keep their names.
- **See it.** A read-only board shows every unit (waiting, building, verified,
  stuck) with its attempts, refusals, tokens and cost.
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
scripts/build-agent.sh && scripts/build-cancho-build.sh

# one brief in, a verified build out (Claude; the key is read from a file)
build/cancho-build "$CANCHO" brief.txt "$PWD/work" \
  "$PWD/scripts/cancho-agent.sh --key-file $HOME/.config/cancho-code/anthropic.key --primer $PWD/guidelines.md --max-tokens 16000" \
  --provider anthropic --model claude-haiku-5-5 --guide "$PWD/docs/plan-guide.md" --review on --review-guide "$PWD/docs/review-guide.md"

# watch or review it as a board
scripts/cancho-board.sh work && python3 -m http.server -d docs 8000     # then open /board.html
```

[`docs/build.md`](docs/build.md) explains the command and the run directory,
[`docs/dashboard.md`](docs/dashboard.md) the board. For a local model with no
key, follow the [guide](docs/guide.html).

## More

[Build command](docs/build.md) · [Dashboard](docs/dashboard.md) · [Design](docs/design.md) · [Plans](docs/plan.md) · [Projects](docs/project.md) ·
[Epic and working rules](https://github.com/alpibrusl/cancho-code/issues/8)

EUPL-1.2.
