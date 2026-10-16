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
- **See everything.** Every run keeps a journal (each prompt, reply, the
  compiler's full refusal, the diff between attempts, the plan stage). A
  read-only board shows every unit (waiting, building, verified, stuck); click
  one to read its whole story.
- **Loops stop.** Attempt ceilings and a same-refusal stop rule end a stuck
  run, named, instead of burning money.
- **Any model.** Claude (API key) or a local model through Ollama. You choose
  the provider and the model every time; there is no default.
- **Measured** (Claude Haiku 5.5; hidden tests the model never sees):
  13 small libraries from hand-written plans finish 38 of 39 for $0.30 in total;
  from a plain-language brief alone, with the model writing the plan, 20 of 26
  builds finish and 14 are fully right. Four small web services were built unit
  by unit; their final scores came after the guide was fixed on the failures it
  showed, so they show what is reachable, not a blind result.
  Conditions and caveats: [`eval/results`](eval/results).

**[Project page](https://alpibrusl.github.io/cancho-code)** ·
[Guide: run it end to end](docs/guide.html) ·
[Reference: every flag, contract and gate](docs/reference.md)

## Try it

**Claude Code skill:** copy [`skills/cancho-code`](skills/cancho-code/SKILL.md) into `~/.claude/skills/` (or your project's `.claude/skills/`) and the agent knows how to install cancho-code, run a build, read what happened and continue a stuck unit, with the key rules built in. Other agents can read the same file as plain instructions.

**Or ask your coding agent to do it:** paste [`docs/agent-prompt.md`](docs/agent-prompt.md) into Claude Code, Codex or similar. It installs everything, proves the install with a test that needs no key, and only then asks which model to use.

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
[`docs/journal.md`](docs/journal.md) what a run records,
[`docs/dashboard.md`](docs/dashboard.md) the board. For a local model with no
key, follow the [guide](docs/guide.html).

## More

[Build command](docs/build.md) · [Dashboard](docs/dashboard.md) · [Design](docs/design.md) · [Plans](docs/plan.md) · [Projects](docs/project.md) ·
[Epic and working rules](https://github.com/alpibrusl/cancho-code/issues/8)

EUPL-1.2.
