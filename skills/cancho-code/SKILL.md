---
name: cancho-code
description: Build, check and continue small programs in the cancho language with cancho-code, a loop where the compiler (not the model) decides when each piece is done. Use when the user wants cancho code written or fixed with a proof (a verdict, a journal, a board), wants to install cancho-code, to look at what a run did, or to retry or patch a unit that got stuck.
---

# cancho-code

cancho-code builds a program from a brief unit by unit. The compiler and each unit's own examples decide when a unit is done; a run ends in one verdict line and leaves a journal. Use it when you need that proof. For one quick edit to a cancho file, just edit it and run `cancho check`.

## Rules (always)

- Never read, print, copy or log an API key file. Ask the user for the **path** of a key file (mode 600) and pass the path (`--key-file <path>`); the tool reads it. Never put a key in a command line or an environment variable.
- Never use `sudo`. Do not install system packages without asking.
- Paths that go into a shell command may hold only letters, digits and `. _ / + : = @ % , -`: no spaces, no `..`. Use absolute paths for the compiler and the work directory.
- A run costs money on a cloud model (a few cents for a small library). Say what you are about to run and wait for the user's go before the first real run. The install and the test gate cost nothing.
- Do not retry a failing run in a loop and do not edit the repositories to make a run pass. Report what failed, with the exact error.

## 1. Install (once)

Follow `docs/agent-prompt.md` in the cancho-code repository: clone `cancho-code` and `cancho` side by side, check out the compiler at the commit in `cancho-code/.cancho-rev`, build it with `cargo build --release -p cancho`, export `CANCHO` (the binary) and `CANCHO_PACKAGES` (the compiler's `packages` directory), then in `cancho-code` run `sh scripts/build-agent.sh && sh scripts/build-cancho-build.sh` and prove it with `sh scripts/test-build.sh` (it must end with `build gate: ok`; `Killed: 9` and `ld: warning` lines in it are expected). Then `"$CANCHO" agent-guidelines > guidelines.md`: the language's own page, which the model is given.

## 2. Build from a brief

Write the brief in plain language: what the package is called, the public functions as `- name(args) : what it does` lines (these names are kept exactly), the edge cases and a few worked examples. Then, from the `cancho-code` directory and with a new work directory:

```
mkdir -p work/NAME
build/cancho-build "$CANCHO" "$PWD/brief.txt" "$PWD/work/NAME" \
  "$PWD/scripts/cancho-agent.sh --key-file KEY_FILE --primer $PWD/guidelines.md --max-tokens 16000 --output patch" \
  --provider anthropic --model claude-haiku-5-5 --guide "$PWD/docs/plan-guide.md" \
  --review on --review-guide "$PWD/docs/review-guide.md" --attempts 6 --agent-seconds 300
```

For a local model: `--provider ollama --model NAME`, no `--key-file`, no `--output patch` (the model must be pulled and the server running). There is no default provider or model; the user chooses.

The last line says what happened: `[BUILD_VERDICT] done | stuck | plan_failed | provider_error | gate_failed`. Exit codes: 0 done, 1 stuck or gate failed, 2 usage, 3 plan_failed, 4 provider_error. `done` means the compiler and the plan's own examples hold, not that your brief is fully covered: check the result against the brief yourself (read `work/NAME/project.cho`).

## 3. See what a run did

Everything is in the work directory: `build.json` (stage, units verified of total, verdict, seconds), `run.log`, `plan.json`, `project.cho` (the program), `usage.jsonl` (tokens per call) and `journal/` (every model call, every attempt of every unit: the prompt, the reply, the code, the compiler's full refusal, the diff to the previous attempt). For a person, make the board: `sh scripts/cancho-board.sh work/NAME`, then `python3 -m http.server -d docs 8000` and open `/board.html` (Board, Graph, Story, Timeline; click a unit for its whole story). Read `docs/journal.md` before digging into the journal files yourself.

## 4. A unit got stuck

Read the unit's attempts in the journal (or the board) first. The refusal text says what is wrong. Then continue, without redoing the rest:

- Retry with a hint (your words about that unit; the compiler and tests still decide): add `--retry UNIT --hint "TEXT"` to the same `build` command (same work directory).
- Replace the unit with code you wrote: `--patch UNIT FILE` (the unit's function and what it needs, as complete top-level items). No model is called; it is verified by the same checker and the unit's tests, and a refused patch is restored.

`--retry` and `--patch` do not go together. A unit whose own **tests file** is what is wrong (not its code) cannot be fixed by either: say so to the user; it is a plan problem.

## More

`docs/build.md` (every option), `docs/journal.md`, `docs/dashboard.md`, `docs/project.md` (the contracts), `docs/reference.md`.
