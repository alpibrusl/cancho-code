# Using an existing library: the `users` service (cancho-web + cancho-schema)

Raw numbers per run: [2026-10-16-library-users.json](2026-10-16-library-users.json) (made by `eval/report_libs.py` from each run's `result.json`, `raw.txt` and trail; the run directories are not committed). Claude Haiku 5.5, `eval/run_service_plan.py users` (the project driver and `cancho-agent --output patch`), 48000 max tokens, compiler `.cancho-rev` (2e72479).

## The question

The model's usual context is the language page. Can it build a small JSON API with a library whose API it only sees in the documents we give it?

## What was built

- **The item** `eval/services/users/`: `brief.txt` (plain language, checked by `scripts/test-briefs.sh`), `reference/project.cho` (cancho-web's `examples/users` adapted to the skeleton's `app_handle` interface: fixed-size store, at most 200 users, body = name 1-40 code points + age 0-150), `accept.py` (33 scenarios the builder sees), `attack.py` (147 hidden checks), `plan.json` (two pure units, `json_type_ok` and `has_room`, plus the integration unit), `pieces.txt`, `facts.json`, `demo.json`, `launch.json`, `libs.txt`, `mutants.json`.
- **The libraries** are vendored, unmodified, under `eval/libs/` (121 KB: `cancho-web/src/web.cho` 79 KB, `cancho-schema/src/schema.cho` 42 KB, each with the upstream EUPL-1.2 `LICENSE` and `NOTICE`; EUPL-1.2 is this repository's licence). `eval/libs/UPSTREAM.txt` records the upstream commits (cancho-web 5f404a7, cancho-schema a7eaad6, whose `schema.cho` is byte for byte the one at 59a7028 that cancho-web's CI pins) and the sha256 of every file; `scripts/test-users.sh libs` checks them. They reach the build the way `http-server` does: `eval/services/users/libs.txt` is read by `eval/service_run.py` (`service_libs`), by `eval/demo.py` and by `eval/run_service_plan.py` (the driver's 8th argument, space separated). Fetching would have been the choice for a large library; at 121 KB there is no reason to depend on the network in CI.
- **Compiler revision:** the libraries' CI builds with cancho a4572ea, this repository with 2e72479. Nothing breaks: both files compile with ours, cancho-schema's own tests (29) and cancho-web's (22) pass with ours, and cancho-web's `examples/users` builds and serves. No gap here.
- **Mutation evidence** (`eval/mutate_users.py`, `mutants.json`): 13 deliberate one-change mutants of the reference, each caught by the attack check it names: total not the live count, ids reused after a delete, 422 as `application/json`, no `Location`, name limit 64, no 415, capacity 201 (the store then overruns and the service dies), no default limit, limit ignored, delete keeps the user, dangling `Problem` reference, only the first fault reported, last user unreadable. The stub fails both accept (3/33) and attack (9/147).

## Gates (RED first, then green; sh and dash)

- RED before the pieces existed (the item, the libs and the mutation tool moved away): `test-users.sh` FAILED (no UPSTREAM.txt, no `eval/primer-libs.md`, mutants 0 caught), `test-services.sh` FAILED for users (accept and attack exit 1, no result line), `test-service-plans.sh users` FAILED (driver exit 2, no verdict).
- Green: `scripts/test-users.sh` (libs hashes and licences, briefs, docs primer bound and content, 13 mutants), `scripts/test-services.sh` (now also `users`: reference passes accept 33/33 and attack 147/147, stub fails both), `scripts/test-service-plans.sh` (default list now five services; `users` plancheck valid, built unit by unit with the stand-in agent from the reference's pieces, 3/3 units, attack 147/147). All green under `sh` (macOS) and `/bin/dash`. CI runs `test-users.sh` and `test-service-plans.sh users` after `test-services.sh`.
- The gates can fail: one byte appended to `web.cho`, a deleted `LICENSE`, a `libs.txt` line naming an unrecorded file, a docs primer that mentions the attack, a brief that names the other language, a mutant whose named check does not exist, and a pieces file that loses a unit each turned the right gate red (7 of 7).

## The two arms, exactly

All arms get the same task text (the plan's application unit: the brief plus the skeleton interface), the service guide (`eval/services/service-guide.md`), the scaffold `project.cho` (the skeleton's imports plus `import schema; import web;`), and the acceptance output as feedback. The agent is a single-shot patch writer: **it cannot read the library files**, so "the signatures it can see" are only what is put in its page.

| arm | page | library information |
|---|---|---|
| A | language page (`primer-main.md`) + service guide | the brief names the two libraries and lists their entry points by name (`web.operation`, `web.dispatch`, `schema.validate` ...) in one sentence; no signatures, no prose |
| B | A + `eval/primer-libs.md` (14 KB, about 4000 tokens, written from the two libraries' documentation) | the API in prose: how to declare a schema, an operation, dispatch, the validate/problem protocol, ownership of `Schema` and `Api`, and one complete small example application (a different API: notes). No attack details. |
| C (extra) | A + the 106 public signatures of both libraries (`eval/libsigs.py`) | signatures only, as declared, no comments |
| D (extra control) | B without the one sentence on decoding a JSON string (`json.string_length`/`json.string_into`) | B's sentence is std.json knowledge, not library API; D asks whether the gain is that sentence |

In every arm the compiler's refusals are the only other source of information, as in the earlier service runs. Nothing in `primer-libs.md` is hidden-attack content, but note one thing it does say, because it is also the library's own documentation: `web.respond_problem` points at a component named `Problem` and the generated document is only complete if one is declared.

## Results (2 pilot runs per arm with brief v1, then 4 per arm with brief v2)

| arm | runs | built (all units, accept) | hidden attack | calls (mean) | out tokens (mean) | cost per run |
|---|---|---|---|---|---|---|
| A | 4 | 0 of 4 (stuck on the application) | no application | 8.0 | 30.2k | $0.023 |
| B | 4 | 4 of 4 | 147/147 in all four | 4.0 | 31.4k | $0.019 |
| C | 4 | 0 of 4 | no application | 7.2 | 44.0k | $0.030 |
| D | 4 | 3 of 4 | 147/147 three times; the fourth stuck | 6.8 | 38.6k | $0.026 |
| pilot A | 2 | 0 of 2 | no application | 8.0 | 42.1k | $0.029 |
| pilot B | 2 | 2 of 2 | 141/146, 139/146 | 3.0 | 27.4k | $0.016 |

Total spend $0.48 (20 builds); each build cost $0.01-0.04. "Built" means every unit's tests and the acceptance scenarios hold; the attack is the separate grade. Thinking is 52-80% of the output tokens (per run). **Four runs per arm is still noise** (one model, one item, one primer wording): read A and C against B as "0 of 8 against 4 of 4", not as a rate, and D as "the sentence on strings is not the cause". The pilot was run with brief v1 and an older docs example; its B runs scored 141/146 and 139/146 only because the document they served listed responses without bodies (`web.respond_empty` copied from the example), which brief v1 did not ask for. I then tightened the brief (responses carry their bodies, one shared problem document, no dangling reference), added the matching checks, and changed the docs example to `respond` and `respond_problem`. **The B and D results are therefore not blind to that failure**: the later 147/147 are with a brief and a primer both fixed after reading the pilot. A and C were not changed by the primer edit (only by the brief).

## What the model got wrong (read from the raw replies and trails)

- **Arm A ignored the libraries (4 of 4 and 2 of 2).** No application reply in any A run calls `web.operation`, `web.dispatch`, `schema.validate` or `schema.problem` (the one pilot run that touched them, A-2, called `schema.new_*`, `schema.add_field`, `schema.validate`, `web.openapi` and never `operation` or `dispatch`, and the compiler refused it six times with arity and type errors: `new_object` takes 3 arguments, `expected Schema, found (Schema, int)`). The others hand-rolled the router, the query parsing, the validation, the problem documents and three of four wrote the OpenAPI document as a string literal ("not generated by `web`"), against the brief that says to use the libraries. No name was invented: the brief supplies the names. The runs then died on the language, not on the libraries: decoding a JSON string (`to_string`, `string_value`, `to_text`, `text`, `JSON_STRING_DECODE`, none exists), regions (`c is not a region in scope`), `Box` versus slice. The acceptance scenarios cannot tell hand-rolled from library code (they are black-box), so an A build that passed would have passed unnoticed.
- **Arm C used the libraries, with the right names and the wrong shapes (4 of 4).** Every library name it used was real (0 invented); the model declared the schema and the API and called `web.dispatch` and `schema.validate` in every run. What it got wrong is what a signature does not say: `borrow app.sc as ...` (a field path is not borrowable: `expected as, found .`), `expected &Schema, found Schema`, `expected [int], found Box[[int]]` (forgot `contents`), and then the same JSON string decoding as A (`to_text`, `to_string`, `decode`, `name_of`, `unescape_into`). All four ended `stuck` on the application unit after 4-9 calls.
- **Arm B built it in 3-5 calls (4 of 4).** The code follows the example's structure (App with `Schema`, `Api`, tables; `dispatch` first; `schema.validate` then `schema.problem`; `web.openapi` once). The errors it did make were small and language-level (`r is not a region in scope`, a missing `App` field) and at most two refusals per run before the build verified. No hallucinated library function in any arm (0 invented across 20 builds). The pilot's two documents lacked response bodies because the model copied `respond_empty` from the example; fixed above.
- **Arm D**: without the string-decoding sentence three of four still built it (they found `json.string_into` through the compiler's refusals: `to_string`, `to_text`, `decode_string`, `unescape_into` are refused first), one did not. So the library documentation, not the std.json sentence, is what separated B from A/C; the sentence saved some attempts (B 4.0 calls, D 6.8).

## Findings about the libraries and this repository (gaps, with repros)

1. **cancho-web: a dangling `$ref` in a served document, silently.** `web.respond_problem` writes `#/components/responses/Problem`, but `components.responses.Problem` exists only if a component named `Problem` was declared (`web.component(heap, api, "Problem", node)`); `web.openapi` does not refuse or complain. Repro: delete the line `api = web.component(heap, api, "Problem", problem);` from `eval/services/users/reference/project.cho` (this is mutant `dangling-problem-ref`): the served `/openapi.json` has `"$ref":"#/components/responses/Problem"` on every error response and no `components.responses`; `python3 eval/service_run.py attack users <that file>` reports `every $ref of the document resolves ... dangling: ['#/components/responses/Problem']`. Found while writing the reference; the attack checks it. A validator that resolved refs in `web.openapi`, or a default `Problem`, would remove it.
2. **cancho-schema: U+0000 is accepted in a string unless `schema.forbid_nul` is called**; `POST {"name":"a\u0000b",...}` is a 201 on the reference. A library choice (documented in its docs); the brief does not say and the attack does not test it.
3. **web.dispatch: `limit=007` and `limit=%31` are accepted** (leading zeros, percent-decoding), unlike the strict "plain digits" of the webhooks service. Not in the brief, not tested.
4. **This repository:** `eval/services/webhooks/plan.json` and `kvstore/plan.json` still carry the text "the Lex original" in the application unit's description (the plain-brief cleanup changed `brief.txt` but `scripts/test-briefs.sh` does not read `plan.json`). Not touched here.
5. **Pipeline:** nothing needed from the driver or the tool for a multi-source project: the libraries go in through the driver's existing `lib-files` argument (space separated, so a path with a space would break it). I did not edit `src/`.

## Reproduce

```
export CANCHO=<pinned cancho> CANCHO_PACKAGES=<its packages>
sh scripts/test-users.sh; sh scripts/test-services.sh; sh scripts/test-service-plans.sh users
sh scripts/build-agent.sh; mkdir -p /tmp/evaltools && $CANCHO build tests/programs/project.cho src/project.cho src/plan.cho src/driver.cho src/checker.cho \
    src/signature.cho src/loop_check.cho src/snapshot.cho src/trail.cho src/acceptance.cho src/splice.cho --std --backend cranelift -o /tmp/evaltools/project
cat <language page> eval/primer-libs.md > primer-B.md             # arm B; arm C: eval/libsigs.py instead of primer-libs.md
python3 eval/run_service_plan.py users --provider anthropic --model claude-haiku-5-5 --key-file <path> --workspace <id> \
    --primer primer-B.md --label B --out <dir> --runs 4 --max-tokens 48000 --tools /tmp/evaltools
python3 eval/report_libs.py <dir> A B C D
```
