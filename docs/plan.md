# The plan: units, and the check that runs before any model does

docs/parity.md P3; lex-code's `--package-check` is the model (`[PLAN_CHECK]`, "filing is deterministic on purpose: an LLM does not get to decide, unreviewed, what done means").

A plan is a JSON file. It says what to build as **units** (one function each), what each one must do as **examples**, and which units come first. It is checked by `plancheck <plan.json>` with no model: the same file always gets the same answer.

```json
{
  "name": "tokenbucket",
  "units": [
    { "id": "refill",
      "signature": "fn bucket_refill(tokens_milli: int, last_ms: int, now_ms: int, capacity: int, per_sec: int) -> [] int",
      "examples": ["bucket_refill(0, 0, 1000, 10, 1) == 1000"],
      "deps": [] },
    { "id": "allow",
      "signature": "fn bucket_allow(tokens_milli: int, cost: int) -> [] int",
      "examples": ["bucket_allow(5000, 5) == 0"],
      "deps": ["refill"] }
  ]
}
```

A unit may also carry a `description` (a string): what the function means in the author's words, which the signature and the examples cannot say (units of measure, an edge rule). The project driver puts it in the task the agent reads (docs/project.md). It is optional and not checked beyond being a string.

A unit may carry `tests` (an array of strings): cancho source items, usually `pub fn test_...`, that the project driver appends verbatim to the unit's tests file and that **replace** the tests made from `examples` when present. This is for functions an example cannot call: a result that is text or a `Result` needs a heap or a match, which `CALL == EXPECTED` cannot say. The `examples` stay as documentation shown to the model and are still checked for shape. A signature may carry region and type parameters after the name: `fn f[&r](s: &r [byte]) -> [] int`.

## Output

One line per problem, then the verdict:

```
[PLAN_ERROR]<TAB><rule><TAB><unit id, or - when it is about the plan><TAB><message>
[PLAN]<TAB>valid|invalid
```

Exit 0 valid, 1 invalid, 2 usage (no argument, or the file cannot be read). **Every** problem is reported, not the first. Rules are stable names, in the manner of `cancho check`'s `rule`:

| rule | refused when |
|---|---|
| `plan-json` | the file is not JSON, or the root is not an object with a string `name` and an array `units` |
| `unit-field` | a unit is not an object, or lacks a string `id`, a string `signature`, an array of strings `examples`, an array of strings `deps`, or has a `description` that is not a string or `tests` that is not an array of strings |
| `duplicate-id` | two units have the same `id` |
| `bad-signature` | the signature is not `fn NAME(...) -> [` effect row `] TYPE`. A function's effect row is required: `-> int` is refused, `-> [] int` is the pure form |
| `duplicate-function` | two units declare the same function name ("a function is declared by exactly one unit") |
| `no-example` | a unit has no example |
| `example-own` | none of a unit's examples calls the unit's own function |
| `example-callee` | an example's call is to a function no unit declares |
| `example-shape` | an example is not `CALL == EXPECTED` (the call first, once, a `==`, something after it) |
| `tautology` | an example's two sides are the same text, or it contains `|| true` or `or true`: it checks nothing |
| `unknown-dep` | a `deps` entry is not the `id` of any unit |
| `needs-tests` | the function takes a heap, or its result holds text, a buffer or a list (alone or inside a `Result`/`Option`), and the unit has no `tests`: an example `CALL == EXPECTED` cannot run for it (`==` compares scalars; a test has no heap). A `Result` or `Option` of scalars is not flagged |
| `cycle` | the dependencies form a cycle (reported once, on the first unit of it in the file) |

## What this does not check

That the examples are *right*, or that they can all be satisfied together (lex-code's plan check runs the examples against a reference; there is none here). That a signature's types exist. Those need the model or the compiler and belong to later features (P4b unit verification, P6 hardening).
