# Services built from a decomposed plan (integration unit)

Companion to [2026-10-15-services.md](2026-10-15-services.md) (whole service in one file). Raw numbers per run: [2026-10-15-services-decomposed.json](2026-10-15-services-decomposed.json) (generated from `result.json` of each run by `eval/run_service_plan.py`; the run directories are not committed).

## What was built

- **Plan field `integration`** (docs/plan.md): the id of the application unit. It needs no example, depends on every other unit, and is accepted by the service's acceptance scenarios instead of tests. The project driver takes the acceptance command and lib files as arguments 7 and 8 (docs/project.md, "Services"). The scenario output is the next attempt's feedback (the existing `run_issue` acceptance path), the attempt ceiling and same-signature stop apply as for any unit.
- **Why this is the smallest change:** the pure units need no skeleton (`cancho test` works on them), so the only blocker was the import list: `project.cho` must import what it uses, and the skeleton imports the same modules (an import twice is an error). Fix: `eval/services/skeleton/main_bare.cho` = `main.cho` minus its import lines (pinned by `scripts/test-services.sh`), and `project.cho` starts with those imports (`eval/services/bare.sh --header`).
- **Hand plans** `eval/services/{webhooks,jobs,invoices,kvstore}/plan.json`: one unit per pure function the briefs name (13, 7, 8, 10) plus the application unit. Tests are raw `tests`; every case a test checks is also an `example` (shown to the builder). `scripts/test-service-plans.sh` builds each plan with a stand-in agent (`pieces.txt`: which top-level items of the reference belong to which unit) and grades the finished project with the hidden attack: webhooks 129/129, jobs 188/188, invoices 165/165, kvstore 225/225.
- Gates: `test-plan.sh` (7 new fixtures), `test-project.sh` (case `service`), `test-services.sh` (bare skeleton), `test-service-plans.sh`. Authority pins unchanged (all seven `check-authority.sh` variants green).
- Gate evidence: the plan fixtures and the `service` case of `test-project.sh` were written and run RED before the implementation (against the old `src/plan.cho` and `src/project.cho`), then green. Mutations of the implementation, each turned the gate RED: plan check - `no-example` not waived, `needs-tests` not waived, no order check, unknown id accepted, order check on direct dependencies only (caught only after adding the chain fixture `valid-integration-chain`); driver - final gate without libs, integration acceptance replaced by the unit tests, integration task written as a normal task, check command without libs, final gate runs a tests file the integration unit does not have, recheck ignoring the integration unit, no usage error without a command, tests command without libs (8/8 red); service plans - a helper dropped from `pieces.txt`, a wrong expected value in a plan test, a wrong status in the reference application, `integration` removed from the plan (4/4 red).

## Conditions (Claude Haiku 5.5, `--output patch`, 2 runs per cell, `build/cancho-agent` and `project` built from this branch)

| label | guide / plan | `--max-tokens` | per-unit effort |
|---|---|---|---|
| d16 | guide v1, plan v1 (as specified) | 16000 | tiered: description under 500 characters low, else medium; application low |
| d48 | same | 48000 | same |
| g2 | guide v2: header names are lowercase; plan v2: examples carry the cases the tests check | 48000 | same |
| g3 | guide v3 = v2 + a `region` holds one 64 KiB chunk (invoices, kvstore only) | 48000 | same |
| g4 | guide v4 = v3 + extra header lines end in CRLF (kvstore only) | 48000 | same |

g2 to g4 are NOT independent of the hidden attack: each guide line was written after reading the failure of the previous round (v2 from acceptance output the builder also saw; v3 and v4 from attack output). Read g3/g4 as "what the pipeline reaches when the guide states the three language facts the models got wrong", not as a blind result.

## Results

| round | service | verdict | pure units verified | attack | calls | out tokens | cost | seconds |
|---|---|---|---|---|---|---|---|---|
| d16 | webhooks | provider_error x2 | 13/13, 13/13 | no application | 16, 17 | 52.8k, 56.4k | $0.034, $0.037 | 282, 299 |
| d16 | jobs | provider_error x2 | 7/7, 7/7 | no application | 13, 13 | 67.9k, 65.2k | $0.041, $0.039 | 317, 305 |
| d16 | invoices | provider_error; stuck | 8/8; 6/8 | no application | 15; 11 | 68.9k; 20.2k | $0.043; $0.015 | 329; 103 |
| d16 | kvstore | provider_error x2 | 10/10, 10/10 | no application | 14, 16 | 66.6k, 66.7k | $0.041, $0.042 | 330, 326 |
| d48 | webhooks | stuck; **done** | 13/13, 13/13 | none; **129/129** | 15, 15 | 26.7k, 33.9k | $0.020, $0.024 | 145, 197 |
| d48 | jobs | stuck x2 | 7/7, 7/7 | no application | 12, 11 | 47.2k, 56.7k | $0.031, $0.034 | 215, 248 |
| d48 | invoices | stuck x2 | 8/8; 6/8 | no application | 11, 9 | 49.8k, 16.9k | $0.031, $0.012 | 232, 92 |
| d48 | kvstore | stuck x2 | 10/10, 10/10 | no application | 19, 16 | 61.7k, 51.7k | $0.046, $0.038 | 298, 254 |
| g2 | webhooks | done x2 | 13/13 | **129/129, 129/129** | 15, 16 | 36.6k, 34.6k | $0.026, $0.026 | 203, 197 |
| g2 | jobs | done x2 | 7/7 | **188/188, 188/188** | 11, 12 | 52.2k, 43.9k | $0.033, $0.030 | 239, 208 |
| g2 | invoices | done x2 | 8/8 | 145/165, 145/165 | 12, 12 | 42.9k, 45.0k | $0.028, $0.029 | 205, 222 |
| g2 | kvstore | done x2 | 10/10 | 110/225, 111/225 | 13, 15 | 42.9k, 51.5k | $0.027, $0.034 | 220, 253 |
| g3 | invoices | done x2 | 8/8 | 163/165, 163/165 | 10, 11 | 49.3k, 47.6k | $0.031, $0.030 | 233, 231 |
| g3 | kvstore | done x2 | 10/10 | 21/225, 21/225 | 14, 13 | 52.8k, 48.2k | $0.035, $0.031 | 255, 236 |
| g4 | kvstore | done x2 | 10/10 | 224/225, **225/225** | 14, 15 | 56.3k, 47.0k | $0.038, $0.033 | 270, 231 |

("no application": the project has no `app_handle`, so there is nothing to attack. `done` means every unit's tests and the acceptance scenarios held; the attack is the separate, hidden grade.) Thinking is 70-95% of the output tokens in every run (`thinking_tokens` in the JSON; 0.75-0.95 in d16, 0.70-0.83 in the others).
Spend: $1.05 in total for 34 builds (the 30 above plus four pilots (webhooks d16 once, thinking disabled once for webhooks and jobs, one application-only resume at 48k, which verified).

Against the whole-file builds ([2026-10-15-services.md](2026-10-15-services.md), one run each): jobs, invoices, kvstore never produced an answer at 16k or 48k with thinking on (the whole bound spent thinking); webhooks verified once with effort low at 48k (129/129, 43.9k output tokens, $0.023, 174 s). Decomposed (g2, 48k): all four services are built and `done` in all 8 runs; webhooks 129/129 twice at $0.026 and 35k output tokens.

## What fails and why (read from the trails and raw replies)

1. **At 16000 output tokens the application unit never gets an answer.** In 7 of the 8 d16 runs the application unit's three calls were `cut_off` with `thinking` = 16000 (the eighth, invoices run 2, stopped earlier, point 3): the model spends the whole bound thinking, exactly the whole-file failure. The pure units are fine at 16k (they take 300-1700 output tokens each). The applications that did get through at 48k thought 16-28k tokens before answering (`app_thinking_tokens` in the JSON), so a 16k bound cannot work for a unit of this size; per-unit effort `low` did not shrink it. Thinking disabled (pilot): the model answers in seconds with a stub that references fields it never defined (webhooks) and the pure unit `validate_create` fails on an undefined helper (jobs).
2. **d48, no application is built in 7 of 8 runs (6 applications fail, one run never reaches it), mostly one cause: `http.header` with a mixed-case name** (the service guide said `"Name"`; `std/http.cho` says the name is written lowercase, otherwise the call answers the empty slice). Four applications (jobs run 1, invoices run 1, kvstore x2) answered 401 to every request and the acceptance output ("status 401, expected 201" for all scenarios) did not let the model find it; the same-signature stop ended the unit after two identical outputs. The other two: a type error `Box[[byte]]` where a slice was needed that the repair did not fix (webhooks), a parse error (jobs run 2). The one success (webhooks run 2) wrote lowercase names after the webhooks brief spelled them lowercase.
3. **d16/d48 invoices run 2: the pure unit `path_id` failed twice** (`test_path_id_4`, `path_id("0") == -1`): the model allowed "0". The feedback named only the test; the plan's examples did not include that case. Plan v2 puts every tested case in the examples; no pure unit failed in g2-g4 (8 + 8 + 4 builds).
4. **Defects the acceptance scenarios do not see but the hidden attack does** (g2): both invoices builds and both kvstore builds allocate the JSON tape with `region r { alloc_slice[r](json.tape_len(body), 0) }`. A region is one 64 KiB chunk; for a 4096-byte body the tape is about 96 KB, so the request traps and the service dies (invoices: "body of exactly 4096 bytes is accepted" -> disconnect, then the other 19 failures are connection refused; kvstore: "1000 four-byte characters" -> disconnect, then the other 113 failures are connection refused). Minimal repro: `region r { let t = alloc_slice[r](12000, 0); }` traps under `cancho test`, 8000 passes. kvstore also answers 404 instead of 400 for `PUT /kv/` (the 224/225 in g4 run 1).
5. **g3 kvstore 21/225 twice:** after the region sentence was added both builds answer the 405 case with `server.reply_with(.., "Allow: GET")`; an `extra` that is not whole `Name: value\r\n` lines TRAPS (std/http.cho `valid_extra`), so the first POST kills the service. The guide did not say so (g4 adds it: 224/225 and 225/225). **Gap to consider in cancho:** a malformed header string traps the process instead of returning an error value; for a server that is a one-request denial of service the type system gives no hint of.
6. **g3 invoices 163/165 twice:** the store holds 982 invoices where the brief needs 1000+ ("only 982 were accepted"), a capacity the model chose.
7. Not a decomposition effect: `scripts/test-services.sh` is flaky for kvstore's reference attack under heavy load (224/225, "body of 200000 bytes -> 413: connection reset by peer", a race between the server closing and the client still sending). The machine load average was 50-90 (other experiments).

## Caveats

- Haiku 5.5 only, 2 runs per cell one machine under load. A cell of two cannot separate near-equal outcomes; the sharp contrasts (d16 vs d48 vs g2) are the claim, not small differences.
- The hand plans were written with knowledge of the references and the attacks (the briefs name the pure functions); a generated plan (`--mode plan`) for a service was not tried. The stand-in gate proves the plans are satisfiable, not that they are good.
- g2-g4 changed the guide after seeing failures (see Conditions). The d16/d48 numbers are the unmodified experiment.
- `--max-tokens 16000` was the instruction; 48000 is a deliberate second condition because the first cannot work (point 1). Effort per unit is a judgment from [2026-10-19-effort-per-unit.md](2026-10-19-effort-per-unit.md), not tuned here.
- Pure units could also have been built with thinking disabled; that was only piloted (webhooks, jobs), not measured.

## Reproduce

```
export CANCHO=<pinned cancho> CANCHO_PACKAGES=<its packages>
sh scripts/build-agent.sh                       # build/cancho-agent
mkdir -p /tmp/evaltools && $CANCHO build tests/programs/project.cho src/project.cho src/plan.cho src/driver.cho src/checker.cho \
    src/signature.cho src/loop_check.cho src/snapshot.cho src/trail.cho src/acceptance.cho --std --backend cranelift -o /tmp/evaltools/project
python3 eval/run_service_plan.py <service> --provider anthropic --model claude-haiku-5-5 --key-file <path> --workspace <id> \
    --primer <language page> --label g2 --out <dir> --runs 2 --max-tokens 48000 --tools /tmp/evaltools
sh scripts/test-service-plans.sh [service ...]  # the stand-in build + hidden attack, no model
```
