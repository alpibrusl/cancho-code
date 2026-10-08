# cancho-code: design

**Status: drafted, waiting for the maintainer.** Everything below with a
number in it is a proposal, not a measurement; each one is marked *proposed*
and becomes a claim only when a run measures it.

An assistant for [cancho](https://github.com/alpibrusl/cancho) that proves its
work: every task ends in a machine-readable verdict produced by the type
checker, examples and an acceptance gate — not by what the model says about
itself. The cancho counterpart of
[lex-code](https://github.com/alpibrusl/lex-code), carrying forward what worked
there (typed issues, projects, verdict lines) and closing, as first-class
contracts, what did not: runs that continue for a long time without solving
anything.

The working rules are the ecosystem's: design before code, with claims
measured; a gate is fixed before the code it judges and must be able to fail;
a claim that turns out false is corrected in place; losses reported as plainly
as wins.

---

## 1. What exists and what does not

**What exists in cancho today:** a typechecker (`cancho check`), the authority
report (`cancho authority --output json`), a canonical content-addressed AST
with `SigId`/`BodyId` and a round-trip-tested printer (`cancho print`), the
introspectable CLI (`cancho introspect`, `cancho skill`), and `cancho test`.

**What does not, and what this tool waits on** — stated as dependencies on
filed cancho work, not assumptions:

| Prerequisite | Why the loop needs it | Status |
|---|---|---|
| [cancho#401](https://github.com/alpibrusl/cancho/issues/401) — `rule_tag` + `{rule_tag, position, facts}` in `check --output json`, plural | refusals a program can parse; the same-signature stop rule (§4) is built on it | filed, not built |
| [cancho#411](https://github.com/alpibrusl/cancho/issues/411) — JSON → canonical AST → `.cho` | the generation path that bypasses token-level syntax hallucinations | filed, not built |
| [cancho#406](https://github.com/alpibrusl/cancho/issues/406) — `cancho satisfy` | what a typed issue's acceptance checks against | filed, not built |
| [cancho#403](https://github.com/alpibrusl/cancho/issues/403) — the vcs store | issue → intent → ops → attestation provenance; content-addressed issues | filed, not built |

**What cancho-code builds without them, in the meantime:** the model (issue
shapes, plan validation, verdict vocabulary) can be specified and its defects
found with the prose diagnostics that exist today — at the cost of the
regression this design exists to prevent, so no *unattended* run is built
before #401 lands. The honest order is: #401, then the loop's stop rules; #411,
then the generation path; #406/#403, then provenance.

**What is deliberately not copied from lex-code:** the repair/attestation
graph (`lex repair`), the dashboard, and the overnight supervisor. The
dashboard and the supervisor are stage-2 conveniences; the loop-safety
contracts of §4 are not. `cancho repair` stays out for the same reason
`docs/agent-errors.md` §2 keeps it out of cancho: no op log to record against
until #403, and a repair hint recorded nowhere is a suggestion, not a gate.

---

## 2. Typed issues and projects

After [lex-lang#949](https://github.com/alpibrusl/lex-lang/issues/949): an
issue is a **typed intent with a declared oracle**; *done is a proof the gate
evaluates at HEAD*, never a status anyone sets.

An `Issue` is a typed record, content-addressed in the store (#403):

| field | meaning |
|---|---|
| `title`, `body` | free text is allowed; it is not the acceptance |
| `shape` | one of the oracle kinds below |
| `acceptance` | the declared oracle |
| `base` | the head the delta is declared against |
| `deps` | issue → issue edges (blocking) |
| `project` | optional membership |

**Shapes:**

1. **typed_delta** — signatures to add/change/remove, plus the examples that
   decide whether it holds. Machine-closable: the acceptance is what
   `cancho satisfy` (#406) checks.
2. **failing_example** — a bug is one reproducible failing example at HEAD;
   fixed = it passes. No "cannot reproduce."
3. **free_form** — human-closed. The explicit exception, kept small, never
   the default.

**Definition of done** at the current head: the declared oracle holds, the
required attestations are present, and provenance links back (the realizing
ops carry the issue's intent). Done is *evaluated*, never *declared*.

A **project** is a graph of issues with `dep` edges, built in stages that can
each be stopped at — plan (files nothing) → check → file → build → gate — each
ending in a machine-readable line. Boards are derived from the op-log and the
issue graph; nobody drags a card: `open`, `in progress`, `verified`, `blocked`.

**Filing is deterministic on purpose.** The plan is JSON, and it is checked
before anything is filed, after lex-code's validation rules: every example
must call a declared function; an example is a bare call; an invariant that can
never fail checks nothing; no cycles; a pure function needs an example; a
function is declared by exactly one unit. An LLM does not get to decide,
unreviewed, what "done" means.

---

## 3. The driver loop

`issue next` → run one issue → verify → **re-verify everything that had
verified**. The last step is the point: an agent turn that rewrites a file can
silently drop another issue's function, and nothing else would notice. A
regressed issue comes back on the board.

---

## 4. Loop-safety as contracts

lex-code's own documentation names the failure this tool must not repeat:
runs that continue for a long time without solving anything. Each mitigation
below is a **contract with a default and a way to observe it fired**, not a
tuning flag; defaults marked *proposed* become measured claims when the
harness of §7 runs.

| Contract | Rule | Default |
|---|---|---|
| **Attempt ceiling** | attempts per issue before it is given up on; the run names it and carries on with every unit that does not depend on it | 4, *proposed* (lex-code's) |
| **Plan defects are not retried** | if the store says the rejection is the issue's own immutable acceptance, no edit can fix it: report `plan defect`, use up the budget, carry on. Classification is from what the store says, never from how the failure looks — a padding bug and a miscounted example print the same expected-versus-got | always on |
| **Whole-run budget** | a ceiling on turns for the entire run; the run ends `budget`, never a hang | 40, *proposed* (lex-code's) |
| **Same-signature stop** *(new; the gap lex-code left open)* | if K consecutive attempts on one issue fail with the same normalised failure signature — `rule_tag` + facts from `cancho check --output json` (#401), names and numbers normalised out, the same normalisation lex-code's `--lessons` uses to group — stop the issue at once and spend the budget elsewhere. lex-code groups failures this way to *report*; it does not use the grouping to *stop* | K = 2, *proposed* |
| **Progress, not activity** | a round counts only if more units verified or more acceptance scenarios hold; N rounds without progress stop the run | N = 2, *proposed* (lex-code's `--stall-rounds`) |
| **Snapshot and restore** | the shared source file is snapshotted on an interval and on each verified unit; a file that no longer type-checks after a kill or a mid-edit attempt is restored from the newest copy that did; the broken file is kept beside it | interval 2 min, *proposed* (lex-code's) |
| **Plan contradictions are skipped, not enforced** | an invariant that fails on every probed input is the plan disagreeing with itself — reported as a contradiction, skipped, and the run goes on; such a run can end `done` only if the real program passed acceptance | always on |
| **Provider outages are waits, not failures** | a provider that returns nothing (rate limit, rejected key) stops the run with the provider named, attempts preserved; backoff, never burned attempts | always on |

Every stop is a named verdict (§6). There is no state in which the tool
runs silently without either making progress or naming its stop.

---

## 5. Providers

Any backend, including none — local-first, matching the autonomy posture of
the ecosystem. `--ollama` (local, no key) is the default path and must work
end-to-end; OpenAI-compatible servers and cloud providers are flags, keys
from the environment, never on the command line and never in a file the tool
writes. One provider abstraction: every provider returns the same event shape
to the loop, so the §4 contracts are provider-independent.
`--fallback=TAG --switch-after=N` hands a stuck issue to another provider,
named in the report. Usage is reported where the provider reports it; "not
reported," never zero, where it does not.

---

## 6. Verdicts, exit codes, the report

Verdict lines follow lex-code's shape, adapted:

```
[ISSUE_VERDICT]    <verified|failed|inconclusive|unavailable>  <id>
[PROJECT_VERDICT]  <done|built|gate_failed|stuck|budget|error|provider_error|no_plan>
[PLAN]             <valid|invalid|contradiction>
[ACCEPTANCE]       <pass|fail|none|skipped>
```

`done` means every unit verified **and** the assembled file type-checks **and**
the acceptance gate ran and passed. `built` = every unit verified but the gate
could not run; `gate_failed` = it ran and failed. Neither is finished.
Verified is necessary, not sufficient — an issue's examples are a finite list
— which is why the run ends by running the real program.

The **acceptance gate**: black-box scenarios taken from the brief's own
requirements and written before the units, replayed against the real program
started on a free loopback port with a fresh temp dir, loopback only, then
stopped. Coverage rules checked at plan time: a route called with a query
string must also be called without one and expect a 2xx; a numbered resource
needs a twin with the other token expecting 404, so a handler that forgets an
ownership check cannot pass.

Exit codes (*proposed*, after lex-code's overnight supervisor): 0 done,
1 stopped without finishing, 2 usage, 3 no plan, 4 provider stayed down.

The **report** is one Markdown page: the verdict, per-unit attempts and tokens
(read from the store, so a resumed build is counted correctly), the last
acceptance result, what was set aside (skipped invariants, plan defects), and
what each round did — where the time and the tokens went.

---

## 7. Gates, fixed before the code they judge

1. **The loop-safety harness** — a stand-in test in lex-code's
   `scripts/test-overnight.sh` style: a fake agent that loops, a fake checker
   that refuses, a fake provider that goes away. Each §4 contract has a
   scenario where the stand-in loops forever, and the harness asserts the loop
   stops, with the named verdict, in seconds rather than hours. This harness
   is the first code in the repository; the driver it judges does not exist
   yet, and that is the order the working rules require.
2. **The round-trip** — every verdict reachable by a fixture; the report from
   a resumed build matches the one from the uninterrupted run.
3. **The authority pin** — the tool's own `cancho authority` report committed
   and pinned in CI; drift fails the build. The pin must be shown to fail: one
   deliberate capability drift (a stray effect added) that fails it.

---

## 8. The authority row of the tool itself

cancho-code is written in cancho, and runs under the same capability grants it
enforces — the assistant is itself an authority-report subject. The report
will name: `net_out` (the model provider endpoint — a host that is an
argument, which the report cannot bound; said plainly, as hooks-mcp's report
does, and covered by tests instead), `fs_read`/`fs_write` under explicit grant
(the project directory, the snapshot store), `args`, `clock`, and whatever
`cancho test` needs. No foreign code, if the language can build this tool
without any; if it cannot (a provider needs TLS today), the foreign function
count is stated as a number and not hidden.

**A session runs under an explicit capability grant enforced by the
language, not by a prompt.** The agent cannot use an effect it was not
granted, whatever its prompt says.

---

## 9. What is not in v1

The dashboard and the overnight supervisor (stage-2 conveniences; the §4
contracts are not conveniences). `cancho repair` (no op log to record against
until #403). Parallel multi-agent building (after the single loop is provably
bounded). Any form of self-approval: nothing in this tool can mark a
`free_form` issue closed, and no verdict is ever produced by the model.
