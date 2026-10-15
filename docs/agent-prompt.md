Install cancho-code and try it on one small task. Work in a new empty directory, keep every path free of spaces, and never use sudo. Run steps 2 to 4 in one shell session (or repeat the two `export` lines in every command): `export` and `cd` do not survive a fresh shell.

1. Check that `git`, `cargo` (Rust, stable, via rustup), a C compiler (`cc`) and `sh` exist. If one is missing, stop and tell me which; do not install system packages on your own.

2. Get the two repositories side by side, both cloned into the new empty directory (call it the parent):
   git clone https://github.com/alpibrusl/cancho-code.git
   git clone https://github.com/alpibrusl/cancho.git
   git -C cancho checkout "$(cat cancho-code/.cancho-rev)"

3. Build the compiler (a few minutes) and point at it:
   (cd cancho && cargo build --release -p cancho)
   export CANCHO="$PWD/cancho/target/release/cancho"
   export CANCHO_PACKAGES="$PWD/cancho/packages"

4. Build the two tools and prove the install works. This needs no network, no key and no model. Start from the parent directory:
   cd cancho-code
   sh scripts/build-agent.sh && sh scripts/build-cancho-build.sh
   sh scripts/test-build.sh        # must end with: build gate: ok
   "$CANCHO" agent-guidelines > guidelines.md
   Lines such as `ld: warning: no platform load command ...` and `Killed: 9` during these commands are expected (the gate kills a run on purpose to test resuming); only the final `build gate: ok` line matters.

5. A real build needs a model. Ask me which one I want to use, and wait:
   - Claude: ask me for the PATH of a file that holds my Anthropic API key (mode 600). Never read, print, copy or log that file, and never put the key in a command line or an environment variable; the tool takes the path.
   - Ollama (local): ask me for the model name; it must already be pulled and the server running on localhost:11434.
   If I do not want a real run, stop after step 4 and report.

6. Build the example "roman" library from its brief alone (about 2 minutes, a few cents on Claude), with the model I chose (for Claude use claude-haiku-5-5):
   mkdir -p runs/roman
   build/cancho-build "$CANCHO" "$PWD/eval/roman/brief.txt" "$PWD/runs/roman" \
     "$PWD/scripts/cancho-agent.sh --key-file <KEY_FILE> --primer $PWD/guidelines.md --max-tokens 16000 --output patch" \
     --provider anthropic --model claude-haiku-5-5 --guide "$PWD/docs/plan-guide.md" \
     --review on --review-guide "$PWD/docs/review-guide.md" --attempts 6 --agent-seconds 300
   (For Ollama: drop --key-file and --output patch, use --provider ollama and my model name.)

7. Look at the result and tell me, honestly and briefly:
   - the last line it printed ([BUILD_VERDICT] done, stuck, plan_failed, provider_error), and the exit code;
   - runs/roman/build.json (units verified of total, seconds) and, if usage.jsonl is there, the total output tokens;
   - whether runs/roman/project.cho exists, and what the hidden checks said if you can run them (python3 eval/audit_roman.py runs/roman/project.cho);
   - anything that failed, with the exact error. Do not retry in a loop and do not edit the repositories to make it pass.
   To see the run as a board: sh scripts/cancho-board.sh runs/roman, then serve docs/ (python3 -m http.server -d docs 8000) and open /board.html.

Docs: docs/build.md (the command), docs/dashboard.md (the board), docs/reference.md (every flag).
