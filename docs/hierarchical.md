# Hierarchical planning: a request that is too big becomes a module tree

Issue #76. The design is [decomposition.md](decomposition.md); this page says what is built and what the rules are. **Built so far: the tree and its check (`treecheck`).** Not built: the planner that proposes a tree, the build of a tree module by module, the confirmation stop, the forecast, the journal tree and the board roll-up, and the evaluation against the hand plans. Nothing on this page claims how well a model splits a request.

## The tree

A module tree is a JSON file. A model proposes it when the planner answers `too_big`; a program accepts or refuses it. A request that needs no split keeps today's path (brief, plan, units).

```json
{
  "name": "bank",
  "requirements": [{"id": "R1", "text": "keep accounts and their balances"}, {"id": "R2", "text": "a transfer moves the money or changes nothing"}],
  "interfaces":   [{"id": "I1", "text": "the shared types and signatures, written once", "provider": "ledger"}],
  "modules": [
    {"id": "ledger", "brief": "what it must do, in the requester's words", "claims": ["R1", "R2"], "needs": ["fs_write"], "units": 6},
    {"id": "api", "brief": "...", "claims": ["R2"], "deps": ["ledger"], "uses": ["I1"], "units": 5}
  ]
}
```

A module either has `units` (your estimate of the functions it takes: a leaf, planned and built like today) or `modules` (one more level, the same shape; a module that is still too big splits once). Depth 2 is the ceiling.

## The rules (`treecheck <tree.json> [allow]`)

Every problem is reported, one line each: `[TREE_ERROR]<TAB><rule><TAB><node><TAB><message>`, then `[TREE]<TAB>valid|invalid`; a valid tree also prints `[TREE_SUMMARY]<TAB>modules=N<TAB>units=U<TAB>depth=D`. Exit 0 valid, 1 invalid, 2 usage. `allow` is the comma-separated authority the requester allowed (`fs_read,fs_write,net_out,net_in,process,clock,env,random` are the names the report knows); it is not part of the tree, because the model does not get to say what it may do.

| rule | refused when |
|---|---|
| `tree-json` | not JSON, or the root lacks a string `name`, a non-empty `requirements`, an `interfaces` array or a non-empty `modules` |
| `requirement-field` | a requirement is not `{id, text}`, or an id is used twice |
| `module-field` | a module lacks `id` / `brief` / `claims` / `units` (or `modules`), or `deps` / `uses` / `needs` is not an array of strings |
| `duplicate-module` | a module id is used twice anywhere in the tree |
| `empty-claims`, `unknown-claim` | a module claims nothing, or claims what is not a requirement (at depth 2: what its module does not claim) |
| `coverage` | a requirement (at depth 2: a claim of the module) is claimed by no module of the level |
| `unknown-dep`, `module-cycle` | a dependency is not a module of the same level, or the dependencies of a level form a cycle |
| `interface-field`, `duplicate-interface`, `unknown-provider`, `interface-unused` | an interface is not `{id, text, provider}`, has a repeated id, a provider that is not a top-level module, or nothing uses it |
| `unknown-interface`, `interface-self`, `interface-order` | a module uses an undeclared interface, or one it provides itself, or does not depend on the module that provides it (interfaces first: the provider is built before any user) |
| `unknown-capability`, `authority`, `authority-widens` | a need the report does not know, a need the requester did not allow, or (depth 2) a need its module does not have |
| `fan-out`, `module-too-big`, `too-deep`, `too-many-units` | more than 8 modules in a level; a leaf estimated above 12 units (at depth 2 this is the answer "too large; this is the breakdown to confirm", a result and not a build); `modules` inside a submodule; more than 60 units in all |

The gate is `sh scripts/test-tree.sh` (one fixture per rule in `tests/trees`, table in `tests/trees/expected.txt`) and `sh scripts/test-tree.sh --mutants` (a copy of `src/tree.cho` with one rule disabled must fail the gate, for every rule). The checker's authority is pinned in `docs/authority-tree.json`.

## Still to build, in order

1. The planner's `too_big` answer carries a tree; the agent checks it in the round, like a plan (`tree-json` and the rules above are the next round's teacher).
2. A forecast (modules, units, cost from measured per-unit averages), and the stop: the human's yes at the tree, `--yes` to skip; above a threshold the forecast needs its own yes.
3. The build: interfaces written once first, each module its own brief, plan and work directory, modules in dependency order with the parallel driver; system acceptance (#77) for the whole.
4. The journal as a tree of runs and the board rolled up per module.
5. The evaluation: only a top-level request for each of the four services, the model's tree against the hand plan (valid, covers, builds, attack score, cost).
