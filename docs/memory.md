# Memory

What cancho-code remembers between runs, and how: **mined from the journals of past runs, never written by the model.**

The journal ([journal.md](journal.md)) already records every attempt of every unit: the refusal, the diff to the attempt before, what became of it. A memory that had the model write notes about itself would add a thing that can be wrong, can be poisoned by one bad run and cannot be traced to anything. This one is a plain file computed from the journals, every line of it carries the references to the evidence it came from, and a person can read it, edit it, or delete a line.

```
runs (journals) --scripts/cancho-lessons.sh--> <memory dir>/lessons.jsonl --\
                                                                              +--> unit agent --memory <dir> --> prompt (+ journal: `memory`)
a person's own constraints ------------------> <memory dir>/facts.txt -------/
```

No database, no service: two plain files in a directory.

## The decisions

| | decision | why |
|---|---|---|
| Who writes | a cancho tool (`cancho-lessons`, `src/lessons.cho`) reads the `attempt` events and the diff blobs of the journals it is named. It never reads a prompt or a reply. | the journal never holds the key, and the miner does not copy what it does not read |
| What a lesson is | a **class of refusal**: the rule and the message with the names, types and numbers taken out (below). One line of `lessons.jsonl` per class. | the same mistake never has the same names twice |
| What it records | occurrences, in how many runs and units; for the attempt that followed: how often it verified; up to three diffs that fixed it (changed lines only, at most 600 bytes each); first and last time seen; up to twelve evidence references (run, unit, attempt) | every lesson can be traced to the journal |
| When it is recalled | at least 3 occurrences in at least 2 runs (`--min-count`, `--min-runs`), status `active`, **and a fix to show** | a count without a remedy gives the model nothing to act on |
| When it stops being recalled | a lesson that was injected (the attempt's `memory` field names it) and whose attempt was refused with the same class again is *contradicted*; contradicted at least twice and more often than confirmed (injected and then verified) it is `superseded`: kept with its history, never recalled | decided by the data: a newer fact supersedes an older one in a store of facts; here the later attempts do, and no model is in the loop |
| What a prompt gets | for the refusal the unit just got (the first one in `<project>.feedback`, the one the stop rule compares): the lesson of exactly that class, as a `Known pitfalls` block of at most 24 lines and 1,600 bytes with its numbers and at most two fixes | a bounded, explainable addition |
| Opt-in | `--memory <dir>` on the agent. Without it the agent is byte for byte what it was (the prompt gate is unchanged). `build --memory <dir>` hands it to the unit agent (not to the plan agent) | no memory, today's behaviour |
| The person's own facts | `facts.txt`, one line each (`#` for a comment), added to **every** prompt of a run given `--memory`, attempt 0 included. `build ... --memory <dir> --remember "text"` appends a line. At most ten facts of 160 bytes. | constraints a person knows and a journal cannot (`no network`, `public names are lowercase_with_underscores`) |
| Explainable | every injected lesson and fact is recorded on the attempt event in the journal, field `memory` (`[{"id","text"}]`), and the prompt blob shows the same text | a run stays reproducible |
| Promotion | `scripts/cancho-lessons.sh --memory <dir> --promote` prints, for lessons with at least 5 occurrences in 3 runs, a fix, and the next attempt verified in 70% of the cases, a text a person can review and paste into AGENTS.md upstream. It writes nothing. | this is how the `Buffer` vs `&[byte]` hint was found: by reading the journals |

**Changed from the first sketch**, with the reasons:

- *The first sketch recalled any lesson over the threshold.* A lesson without a fix is recalled never (a statistic is not advice). Lessons mined from old runs that left no journal ("legacy", below) therefore count and rank but are not injected; they are evidence for a person, and for `--promote` once a run with a journal repeats them.
- *Matching the function-signature shape for attempt 0 is not built.* The refusal match came first; the evidence below says there is too little to match on yet.
- *`--remember` also refuses a text over 160 bytes*, because the prompt would cut it anyway and a silent cut is a surprise.
- *The `fix` front door (`fix <checker> <file> <agent>`) takes `--memory` the same way* (it is the agent's flag), since the driver is the same.

## The class of a refusal

The refusal's signature is what the loop already compares (`src/signature.cho`: the rule, a colon, the message with every number outside backticks turned into `#`). The class (`src/memory.cho`) takes the names out of it too:

| in a backticked span | becomes |
|---|---|
| a word of the language or of the library (`int`, `fn`, `Option`, `Buffer`, ...: a closed list), or one to three punctuation marks (`[`, `{`, `->`) | itself |
| a name (`empty`, `sm_get`, `std.option`) | `N` |
| a type or anything with a bracket, a `&` or a space (`&l List[byte]`) | `T` |
| a character outside ASCII | `C` |

Outside backticks a number is `#`, a path (a word starting `/` after a colon or a space) is `PATH`, and in an acceptance failure the test's name, `test test_take_2 ... FAILED`, is `test N ... FAILED`. At most 240 bytes. Direction survives: "expected `int`, found `bool`" and "expected `bool`, found `int`" are two classes. So `` `empty` is not a function `` and `` `nil` is not a function `` are one, and the `Buffer` lesson is `type-mismatch:expected `T`, found `Buffer``. The id of a lesson is `L` and eight hex digits of the 32-bit hash `h = h * 33 + byte` (from 5381) of the class. `tests/memory_test.cho` pins every case, and an independent Python oracle (`tests/reference/lessons_ref.py`) must give the same `lessons.jsonl` as the tool on every fixture.

## The files

`lessons.jsonl`, one object per line, most evidence first (active, then superseded, then insufficient): `id`, `rule`, `class`, `example` (the first signature seen), `status` (`active`, `insufficient`, `superseded`), `count`, `runs`, `units`, `next_seen`, `next_verified`, `first`, `last` (Unix ms from the journal; 0 for legacy), `contradicted`, `confirmed`, `source` (`journal`, `legacy`, `mixed`), `fixes` [{`run`, `unit`, `attempt`, `diff`}], `evidence` [{`run`, `unit`, `attempt`}]. A run is named by its directory's name.

The file is **rewritten from the journals each time** (that is what makes it reproducible): to remove a lesson for good, put its id on a line of `ignore.txt` in the same directory. Deleting a line from `lessons.jsonl` removes it from what the agent recalls until the next mining. Files are plain text; nothing else is kept.

```sh
scripts/cancho-lessons.sh --memory ~/cancho-memory runs/            # every run under runs/ with a journal
scripts/cancho-lessons.sh --memory ~/cancho-memory --legacy runs/   # ... and, for older runs without one, their trails (statistics, no fixes)
scripts/cancho-lessons.sh --memory ~/cancho-memory --promote        # what is worth a hint upstream
build/cancho-build "$CANCHO" brief.txt run "$AGENT" --provider ... --model ... --memory ~/cancho-memory --remember "no network"
```

## Safety

- **No secret enters.** The miner reads, from a journal, only the `unit`, `n`, `outcome`, `signature`, `memory` and `diff` fields of the attempts and the diff blobs they name; prompts, replies, stderr and feedback are not opened. What it copies is bounded (a signature to 200 bytes, a fix to 14 lines and 600 bytes) and any word that looks like a key (20 or more letters, digits, `-` and `_` with a letter and a digit and either a `-` or no `_`) is replaced by `[redacted]`. The gate puts a stand-in key in a prompt, a reply, a diff and a signature of a mined journal and requires it nowhere in the memory directory or the output.
- **A blob named outside the blobs directory is not read** (a hostile journal naming `../../x`): only plain file names, no `..`, no `/`.
- **Bounded.** 64 KiB per journal line, 512 classes, 256 KiB for `lessons.jsonl` (what does not fit is counted and left out, the least evidence last), 24 lines and 1,600 bytes injected, ten facts.
- **The authority of the tool is pinned** (`docs/authority-lessons.json`, `scripts/check-authority.sh --lessons`): it reads and writes files; no network, no process, no foreign code. The agent's pin is unchanged.
- **A killed or half-written journal** mines what is whole; a line that does not parse is skipped and counted.
- **Nothing the model wrote is trusted.** The one thing in the journal that comes from the model's side is the code in the diff; it is quoted as data in a prompt that says it may or may not apply, and the compiler and the tests still decide.

## Legacy mode

Before the journal, a run left `trail-<unit>.jsonl` (the signature and the outcome of each attempt) but no code. `--legacy` reads those: counts, runs, units and the success of the next attempt, never a fix. Raw replies (`raw.txt`) are not matched to attempts: it would be a guess.

## What the board can show later

`src/board.cho` and `docs/board.html` are not touched by this work. The contract is the `memory` field of the `attempt` events ([journal.md](journal.md)): a unit's attempts that carried a lesson, with its id and text. `lessons.jsonl` is one more plain file the board could list.

## Gate

`scripts/test-lessons.sh` (and `--mutants`), plus the memory cases of `scripts/test-agent-native-ollama.sh` (the agent: the pitfalls block in the request, nothing without `--memory`, `memory.json` beside the project), `scripts/test-journal.sh` (the `memory` field) and `scripts/test-build.sh` (`--memory`, `--remember`).

## Measured

Details, the top classes and the A/B: [eval/results/2026-10-16-memory.md](../eval/results/2026-10-16-memory.md). In short:

- **The evidence base.** Over every run kept so far (77 with a journal, 3,748 trails without): 957 refusals in 75 classes, 37 with enough evidence, **8 with a fix** (only a journal has diffs). The early journal runs hold 2 refusals in 55 attempts. The class `` expected `T`, found `Buffer` `` (the pitfall behind the AGENTS.md hint) comes out of the old trails on its own: 30 occurrences in 21 runs, the next attempt verified 6 times in 25. Counts are exact: an independent count over the raw trails gives the same numbers.
- **The A/B** (13 items x 2 runs, brief only, haiku, lessons mined from the other items' journals only): the memory recalled one lesson, the missing import, on 4 retries of 26 runs; 3 of the 4 verified; the same refusal in the arm without memory was fixed 2 times of 2 by the model reading the message. Done 22 against 23, fully right 14 against 17, attempts per unit 1.073 against 1.077. **This is noise, not an effect**: 2 runs per cell cannot separate them, and the memory had one recallable lesson per item. What it shows is that the whole path works on the real API.
- Next steps with evidence behind them: more journals (every run now leaves one), then `--promote` for what recurs and does not fix itself.
