# A request that is too big: break it down, don't refuse it, don't build it blind

Status: the acceptance checks are built (`treecheck`, [hierarchical.md](hierarchical.md)); the planner that proposes a tree, the tree build and the evaluation are not yet. `docs/parity.md` already lists "plan *generation* by a model" as missing; this says how it should behave.

"Create software for a bank" has no signature, no examples and no oracle. The two easy answers are both wrong: refusing helps nobody, and building it
produces code nobody can say is right. What fits cancho-code is the shape it already has: **the model proposes, a deterministic check disposes, and
only checked plans are built.**

## The recursion

A node is a request with an acceptance. Every node is **classified** and then either built or split.

| class | meaning | action |
|---|---|---|
| `unit` | one function with a signature and examples a person can check | build it (`fix`) |
| `module` | a set of units whose interfaces can be fixed up front | write a plan (`plan.json`), check it (`plancheck`), build it (`project`) |
| `system` | several modules, or effects (storage, network, clock), or no way to say what "done" means | split into modules **and** interfaces; do not build |
| `unclear` | decisions only the requester can make (currency? one ledger or many? who calls it?) | list the decisions as assumptions and stop for a yes |

Splitting is a model's job; **accepting a split is not**. A split is accepted only when deterministic checks pass (the same philosophy as
`plancheck`: "an LLM does not get to decide, unreviewed, what done means"):

1. every child has a signature with an effect row, examples, and acyclic dependencies (what `plancheck` already does);
2. **coverage**: every requirement of the parent is claimed by at least one child, by id; no child claims nothing;
3. **interfaces first**: types and signatures shared by two children are written once, before either child is built;
4. **authority**: each node states the capabilities it needs (`fs_write`, `net_out`, ...). The sum must be inside what the requester allowed. This is
   where cancho helps: a bank that "just needs a database" asks for authority the report can show.
5. **bounds**: depth, fan-out and total units have ceilings; a split that exceeds them is sent back, not built.

The recursion ends at `unit`. If a node cannot be made a unit or a module within the ceilings, the answer is **"this is too large; here is the
breakdown I would need confirmed"**, which is a result, not a refusal.

## What to ask the human, and when

Once, at the top: the list of assumptions and the acceptance scenarios for the whole ("a transfer between two accounts either moves the money or
changes nothing"). Lower levels do not ask; they inherit. The human's yes is the only oracle a general request ever has, so it is the one gate
that cannot be automated, and the breakdown exists to make that yes cheap.

## How it would be evaluated (so it is not taken on faith)

The existing eval items are the test bed: give the decomposer only each item's `brief.txt` and score, against the hand-written plans:

- the plan is valid (`plancheck`), and covers the brief's requirements;
- built with the same agent and model, the audit score and the cost compared with the hand-written plan's (the baseline in `eval/`);
- a deliberately vague brief (e.g. "text utilities") must come back as `unclear` with questions, not as a plan.

Baseline to beat, from the first measurements: with a hand-written plan, Claude Haiku 5.5 built 12 of 13 items on every run (see eval/README.md).
So the decomposer is worth exactly what it keeps of that number once the plan is the model's.
