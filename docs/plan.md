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

A unit may carry `effort` (`low`, `medium`, `high`, `xhigh` or `max`, the API's own values): how hard the model should think about this unit. The project driver writes it into the task as an `EFFORT:` line and the Claude agent sends it as `output_config.effort` for that unit, overriding `--effort`; absent, the flag (or the model's default) applies. Any other value is refused by `unit-field`. What it buys, measured: [eval/results/2026-10-19-effort-per-unit.md](../eval/results/2026-10-19-effort-per-unit.md).

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
| `needs-tests` | the function takes a heap, or its result holds text, a buffer or a list (alone or inside a `Result`/`Option`), and the unit has neither `tests` nor `cases`: an example `CALL == EXPECTED` cannot run for it (`==` compares scalars; a test has no heap). A `Result` or `Option` of scalars is not flagged |
| `bad-test` | one of the unit's `tests` is a `pub fn test_...` that takes a `World` or calls `split`: that is not a test form (tests take `Heap`/`Io` references directly), so the unit's test file could never build |
| `cycle` | the dependencies form a cycle (reported once, on the first unit of it in the file) |

## What this does not check

That the examples are *right*, or that they can all be satisfied together (lex-code's plan check runs the examples against a reference; there is none here). That a signature's types exist. Those need the model or the compiler and belong to later features (P4b unit verification, P6 hardening).


## `cases`: test data instead of test code

A unit may carry `cases`: `[{"args": [...], "expect": ...}, ...]`. `src/cases.cho` (`cases.expand`) turns them into the unit's `tests` from the unit's own signature, so the generated test code compiles and calls the function correctly. This exists because a model that writes test code against its own signatures got it wrong in most failed builds (`eval/results/2026-10-15-plan-generator.md`). The planner (`cancho-agent --mode plan`) expands the cases before the plan check and writes the expanded plan, so the project driver never sees `cases`.

- `args`: the arguments in order, without the heap. Parameters: `int`, `bool`, text (`&[byte]`), a list of text (`list.List[Box[Box[[byte]]]]`) or a vec of text (`vec.Vec[&[byte]]`) as a JSON array of text values.
- **Text values** are a JSON string (its UTF-8) or `{"bytes": [0..255, ...]}` for any bytes (NUL, `\r`, `0xFF`...): a text with a byte a cancho string literal cannot hold is built from its bytes by the generated test.
- `expect`: an integer, `true`/`false`, or a text value for an `int`, `bool` or text/buffer result; `null` is `None` and the bare value is `Some` for an `option.Option` of int, bool, text or buffer; a list of text is a JSON array of text values (compared element by element, in order); `{"ok": v}` / `{"err": e}` for a `result.Result` (`{"ok": null}` is `Ok(None)` when the Ok type is an option). The error payload is compared only when the error type is `int` and `e` is an integer; `{"err": true}` is any error.
- Returns: `int`, `bool`, `buffer.Buffer`, a text slice, `Box[[byte]]`, a list of text, `option.Option[...]`, `result.Result[...]` of those.
- A signature with another type (a record, a slice of ints) is reported (`give tests instead`); a unit with both `cases` and `tests` is refused; a malformed value is refused for that case with its position.
- `examples` are filled (up to three documentation lines) when the unit has none. A unit with `cases` satisfies the `needs-tests` rule.
- Gate: `scripts/test-cases.sh`: a differential against `tests/reference/cases_ref.py` on 120 plans, and 53 real units whose generated tests pass against the hand-checked references and fail when one expected value is flipped.

## `review`: a blind second pass over the cases

About 1 in 80 expected values a planner writes is wrong (arithmetic it cannot do), and one wrong case makes its unit unsatisfiable. `src/review.cho` (`module review`, pure, effect row `[heap]`) filters them with a second model that never sees the planner's values:

- `review.blind(heap, plan) -> Buffer`: the reviewer's questions, `{"units":[{"id","signature","description","cases":[{"args":[...]}]}]}` for every unit with a non-empty `cases`, in plan order. No `expect`, `examples`, `tests` or `deps` (examples contain expected values). A plan that is not JSON gives `{"units":[]}`.
- `review.apply(heap, plan, answers) -> (Buffer plan, Buffer report, int code)`: `answers` is `{"units":[{"id","answers":[{"expect": V} | {"skip": true}, ...]}]}`, one answer per case, in order. A case survives iff the answer is `{"expect": V}` and V equals the planner's `expect`; a mismatch or a skip drops it. The plan comes back without the dropped cases, everything else as it was.
- Equality: integers by value and `1` is not `1.0`; a text is a string or `{"bytes":[...]}` and two texts are equal iff their bytes are (so `{"bytes":[104,105]}` equals `"hi"`); arrays element by element; objects by key and value; `{"err": x}` is equal iff both `x` are the same integer or neither is an integer (the error payload is compared only when it is an integer, as `cases` does).
- Report: `[REVIEW_DROPPED]<TAB>unit<TAB>case<TAB>planner V reviewer W|skip` per dropped case, `[REVIEW_ERROR]<TAB>unit<TAB>-<TAB>message` per problem (a unit that lost all its cases, no answers for a unit, a wrong number of answers, an answer of another shape, answers or plan that are not the right JSON), then `[REVIEW]<TAB>kept K of N cases`. Code 0 when every unit with `cases` (and no `tests`) keeps at least one; code 1 otherwise, and then the plan is the input.
- Gate: `scripts/test-review.sh`: a differential against `tests/reference/review_ref.py` (blind on 162 plans, apply on 39 pairs), 54 plans whose perturbed and skipped answers drop exactly those cases and whose survivors still expand and pass the plan check, and a check that no planner value reaches the questions.

