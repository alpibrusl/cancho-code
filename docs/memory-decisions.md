# Memory decisions

**Status: design. Nothing here is built.** The one number below that was measured is marked as such; everything else is a decision or a requirement for the gate.

[memory.md](memory.md) says memory is mined from journals and never written by the model. Today the last step is manual: `scripts/cancho-lessons.sh --memory <dir> --promote` prints the lessons worth a hint (at least 5 occurrences in 3 runs, a fix, the next attempt verified in 70% of the cases) and "writes nothing". A person reads the text, copies it into `facts.txt` or into AGENTS.md upstream, and **nothing records that they did, or that they decided not to.** The consequences:

- a lesson they rejected is printed again at the next `--promote`;
- a lesson they accepted is still printed, because the lesson is still active;
- the journal can say which `F<n>` fact an attempt carried, but not where that fact came from.

This document adds the missing step: **a person accepts or rejects a proposal, and the decision is a fact on disk.** It is the same pattern as a2p's memory proposals (an agent suggests, the user approves) and the approval events planned in cancho-forge's M4 (`approval.requested`, `approval.granted`), narrowed to what cancho-code has: one person, one machine, two plain files.

## The decisions

| | decision | why |
|---|---|---|
| What a proposal is | a lesson that `--promote` would print today. **It is computed, not stored.** | `lessons.jsonl` is rewritten from the journals each time; a stored proposal would go stale or be lost on the next mining |
| What is stored | `<memory dir>/decisions.jsonl`, append-only, one object per line: `t_ms`, `id` (the lesson's), `decision` (`accept`, `reject`), `target` (`fact`, `upstream`; accept only), `text` (what was written, accept only), `count` and `runs` (the lesson's evidence when decided), `reason` (reject only, at most 160 bytes) | the decision is separate from `lessons.jsonl` so re-mining cannot erase it, and separate from `ignore.txt`, which means something else (never recall this lesson) |
| Who decides | a person, by running the tool. The tool refuses to run an accept or a reject without a terminal on standard input (`decision-no-tty`) | the agent and the build driver run the tool's siblings without a terminal; nothing the model produced can be what accepts. See "The agent cannot decide" |
| What the text of a `fact` is | the person's. The tool prints a candidate (the lesson's class and its best fix, cut to 160 bytes) and the person types the line, or presses return to take the candidate. Never a model's | `--remember` already takes only a person's text; this keeps that |
| Accepting as a `fact` | appends to `facts.txt` the line, preceded by a comment `# L1234abcd accepted <date>`. Refused with `facts-full` when the file already has ten facts | a fact goes into **every** prompt of a run, so the ten-fact limit of memory.md applies unchanged, and a full file is the person's to prune |
| Accepting as `upstream` | writes `<memory dir>/upstream/<id>.md` with the lesson, its fix and its evidence references, for the person to put into AGENTS.md. The tool does not edit any repository | this is what `--promote` prints now, kept as a file and recorded |
| What a decision does to the lesson | an accepted lesson is no longer proposed. It stays active and is still recalled for its own refusal: a fact says it for every prompt, the lesson says it with a fix when the refusal appears. A rejected lesson is no longer proposed **unless its evidence has doubled** (`count` at least twice the decision's) | a rejection is not forever, but it is not asked again for one more occurrence |
| What the journal records | nothing new. A fact is already an `F<n>` entry in the attempt's `memory` field. The line's comment in `facts.txt` and the entry in `decisions.jsonl` connect it to the lesson and the evidence | the journal is the record of a run; a decision is not part of any run |
| Without any of it | `--promote` prints what it printed, and `--memory` behaves as before | no new flag changes a run that does not use it |

## The commands

All on `scripts/cancho-lessons.sh --memory <dir>`, like `--promote`:

```
--proposals                  list the pending proposals: id, class, count, runs, next_verified, best fix (read only)
--accept L<8 hex> [--as upstream]   show the candidate, ask for the line, write it
--reject L<8 hex> [--reason "text"]
--decisions                  list decisions.jsonl, newest last (read only)
```

`--promote` stays as it is (print, write nothing), so existing uses and `test-lessons.sh` do not change.

## Refusals

Each has a name the tool prints and a test that reaches it, per the way the rest of the repository reports refusals.

| rule | when |
|---|---|
| `decision-no-tty` | `--accept` or `--reject` with no terminal on standard input |
| `decision-unknown-lesson` | the id is not in `lessons.jsonl` |
| `decision-not-proposed` | the lesson is `insufficient` or `superseded`, has no fix, or was already decided and its evidence has not doubled |
| `facts-full` | an accepted `fact` would be the eleventh |
| `fact-too-long` | the line is over 160 bytes or has a newline (the rule `--remember` already has) |
| `decisions-full` | `decisions.jsonl` is at 16 KiB |
| `decisions-corrupt` | a complete line of `decisions.jsonl` does not parse. Nothing is written. A torn last line is cut and counted, the way the journal handles it |

## The agent cannot decide

This is the property the design exists to keep, so it is a gate requirement and not a hope.

- The agent reads the memory directory and the build driver passes it `--memory <dir>`. **Neither is to be given write access to it.** The authority of the unit agent is pinned in `docs/authority-agent.json`; the gate must show that pin has no `fs_write` that reaches the memory directory, before this is called done. (I have not checked what the pin allows today; `authority-lessons.json` has `fs_write`, which it needs to write `lessons.jsonl`.)
- The tool that writes decisions is a mode of the lessons tool, whose pin already allows file writes and **no network and no process**. Adding `--accept` must not widen it, and `scripts/check-authority.sh --lessons` must still pass without a change to the pin.
- `decision-no-tty` is a second line, not the first: it stops a script by accident, not an agent that can allocate a terminal. The first line is authority.

## Safety

- **No secret enters.** The candidate text and the `upstream` file are built from the same bounded, redacted fields the miner already copies (a signature to 200 bytes, a fix to 14 lines and 600 bytes, key-like words replaced by `[redacted]`). The person's typed line is theirs, and is checked for the same key-like words and refused if one is in it.
- **Bounded.** 160 bytes per fact, ten facts, 16 KiB for `decisions.jsonl` (a full file refuses the next decision with `decisions-full`; it is a person's file and they can archive it), 4 KiB for an `upstream` file.
- **Whole lines.** A decision is written by building the new file and renaming it over `decisions.jsonl`, the way the journal is written, so a kill leaves the file as of the last whole line.
- **Nothing the model wrote is trusted.** The diff in a candidate is code the model produced in an earlier run; it is shown to the person as data, as in the prompt, and the person's line is what is stored.

## Not built, and not in this document

- **Categories of facts** (constraints, preferences, project facts), each with its own limit and its own place in the prompt. `facts.txt` stays one flat list. It is the other half of what a2p's scopes would give, and it is a separate decision because it changes the prompt, which the prompt gate pins.
- **A shared mechanism with cancho-forge.** Forge's M4 approvals are journal events in Forge's journal; these decisions are a file in a memory directory. They have the same shape (a request, a person's decision, a record that survives restarts) and no code in common. If Forge ever runs cancho-code workers, mapping a proposal to an `approval.requested` is the place to look; I have read Forge's roadmap line for M4, not its design, so this is not claimed to fit.
- **A board view.** The board could list `decisions.jsonl` as one more plain file, as memory.md says of `lessons.jsonl`; `src/board.cho` is not touched.
- **Anything remote.** No profile server, no identity, no signing. The a2p comparison is for the idea of a human-approved proposal, not the protocol.

## Gate

To be added to `scripts/test-lessons.sh`, with the same `--mutants` discipline as the rest (each broken copy must turn the gate red). The first four are the ones that matter:

1. **The agent cannot write the memory directory:** the authority pin of the unit agent, checked by `scripts/check-authority.sh`.
2. **An accept without a terminal writes nothing:** standard input from `/dev/null`, `facts.txt` and `decisions.jsonl` byte for byte as before, exit code, rule `decision-no-tty` printed.
3. **A rejected lesson is not proposed again, and is proposed when its evidence has doubled** (an accepted one never).
4. **The eleventh fact is refused** and the file is unchanged.
5. A torn last line of `decisions.jsonl` is cut and counted; a corrupt complete line refuses and changes nothing.
6. A stand-in key in a lesson's fix and in the typed line appears nowhere in the memory directory.
7. A path-shaped or oversize id is refused.
8. `--promote` output is byte for byte what it was.
9. Mutants (proposed list): a reject that does not write; an accept that skips the `facts-full` check; the doubling test off by one; the terminal check removed; a decision written without the rename; the redaction skipped on the candidate; an accepted lesson still proposed.

## What to measure before building more

The reason to build this at all is that the manual step loses information. That is a claim, so it gets a number first: **over the memory directories and runs that exist, how many lessons does `--promote` print, and for how many of them is there a line in some `facts.txt` or a hint in AGENTS.md that says the same thing?** If a person has already been copying every proposal by hand without trouble, the decision log adds bookkeeping and little else, and this document should say so and stop. That count has not been taken.
