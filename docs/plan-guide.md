# How to write a plan

You are planning, not programming. A program (the project driver) will build what you describe one unit at a time with a model, checking each unit with the examples and tests you wrote, and then the whole. You write NO implementation. Your reply is read by a program: it must be one JSON object and nothing else (a fence around it is tolerated, prose after it is ignored).

## The plan

```
{ "name": "<short name>",
  "units": [ { "id": "...", "signature": "...", "description": "...", "examples": [...], "tests": [...], "deps": [...] } ] }
```

- **A unit is ONE function.** Cut the task into units small enough that one function and its examples can be written and checked alone. Split out what a person would split out: a validity check, a tokenizer, a comparison, a number reader, a formatter. A library is typically 2 to 9 units. A unit whose description needs the words "and then" more than twice is two units.
- **id**: letters, digits, underscore. **deps**: the ids of the units whose functions this one calls (no cycles; a helper comes before what uses it).
- **signature**: `fn NAME(params) -> [EFFECTS] TYPE`. The effect row is REQUIRED: `[]` for a pure function, `[heap]` when it takes `heap: &!h Heap`. Region parameters come after the name: `fn f[&r](s: &r [byte]) -> [] int`. Prefix every function name with the task name (`hexnum_parse`) so names cannot collide.
- **cancho has no string type**: text in is `&r [byte]`; text out that the function builds is `buffer.Buffer`; a fallible result is `result.Result[T, &static [byte]]`; an optional one `option.Option[T]`. A number is `int` (64-bit, overflow is an error, not a wrap). There are no closures and no `break`/`continue`.
- If REQUIRED PUBLIC FUNCTIONS are given below the task, use exactly those signatures for them. Add helper units freely; a helper's signature is yours to design.
- **description**: what the function MEANS, in words: units, every edge rule, what counts as invalid, what the signature cannot say. The builder sees only the description, the examples and the tests, and the task is judged by a hidden audit you cannot see: anything the task requires must reach the builder through your units. Be exact about boundaries ("at most 9 digits", "lower case only", "an empty input is an error"). Do not dictate an algorithm unless the task does.
- **examples**: each is `CALL == EXPECTED` (the call first, once, then `==`, then the value). At least one per unit calls that unit's own function. `==` compares only scalars (int, bool); for a function that returns a `Result`, an `Option` or a `buffer.Buffer` an example is documentation, and the real checks are the `cases`. An example can never mention `heap` or a local variable: a function that takes a heap, or returns text, a buffer or a list, MUST have `cases` (or `tests`); the plan check rejects it otherwise. Examples MUST BE CORRECT: a wrong example makes the build fail for a reason the builder cannot know. Fewer, certain examples beat many.
- **cases** (how a unit is tested): a list of `{"args": [...], "expect": ...}`. You write DATA, not test code: the arguments in order (leave out the `heap`), and what the call must give. A program turns the cases into the unit's tests, from the signature, so they compile and call the function correctly; this is why you must not write test code. `expect` is: an integer, `true`/`false`, or a string for an `int`, `bool` or text/buffer result; `null` for `None` and the value itself for `Some`; `{"ok": value}` or `{"err": true}` for a `result.Result` (for an `int` error type, `{"err": 3}` pins the number; text error messages are never compared); a list or vec of text is a JSON array of strings, in order. Text is a JSON string, or `{"bytes": [13, 10, 255]}` when it holds bytes a string cannot (carriage returns, NUL, invalid UTF-8): write `{"bytes": [...]}` instead of an escape you are unsure about. Every unit gets cases, including the failure cases: a unit only ever shown valid input will accept invalid input. **Cases must be CORRECT**: a wrong case makes the build fail for a reason the builder cannot know. Derive each expected value by hand from your own description, never write a case whose result needs heavy arithmetic you cannot do exactly (big powers, large products modulo something): leave such a case out rather than guess. Prefer 6 to 15 certain cases per unit over many.
- **tests** (a fallback, rarely needed, and it replaces the cases): cancho test source, only for a signature whose types `cases` cannot express (an owned list parameter, a vec of ints, a slice of ints, a record). The test file already starts with `edition 7;` and `import std.test;`; a test is `pub fn test_NAME() -> [] int { ...; return 0; }` using `test.assert(CONDITION)` or `test.assert_eq(INT, INT)`; one that needs a heap is `pub fn test_NAME[&h](heap: &!h Heap) -> [heap] int` (NEVER `(world: World)`, never `split`); names must be unique across the plan; do not import in a test what the project already imports.
- Cover the task's every stated rule in some unit's description AND in some example or test, including the failure cases.

## A worked example (a different task, so you can copy the shape and not the content)

Task: "parse 1 to 8 hex digits into the number they spell; anything else is an error."

```json
{
  "name": "hexnum",
  "units": [
    {
      "id": "digit",
      "signature": "fn hexnum_digit(c: int) -> [] int",
      "description": "The value 0..15 of the ASCII hex digit c (c is a byte value: '0'..'9' are 48..57, 'a'..'f' are 97..102, 'A'..'F' are 65..70), or -1 for any other c. Both letter cases are digits.",
      "examples": [
        "hexnum_digit(48) == 0",
        "hexnum_digit(97) == 10"
      ],
      "cases": [
        {
          "args": [
            48
          ],
          "expect": 0
        },
        {
          "args": [
            57
          ],
          "expect": 9
        },
        {
          "args": [
            97
          ],
          "expect": 10
        },
        {
          "args": [
            70
          ],
          "expect": 15
        },
        {
          "args": [
            103
          ],
          "expect": -1
        },
        {
          "args": [
            47
          ],
          "expect": -1
        }
      ],
      "deps": []
    },
    {
      "id": "parse",
      "signature": "fn hexnum_parse[&r](s: &r [byte]) -> [] result.Result[int, &static [byte]]",
      "description": "Parse 1 to 8 hex digits (no 0x prefix, no sign, no spaces, either case) into the number they spell: Ok(value), at most 4294967295. Anything else is Err with a short message: the empty text, more than 8 digits, any byte that is not a hex digit. It must never panic, on any bytes. Use hexnum_digit for each digit.",
      "examples": [
        "hexnum_parse(\"ff\") == result.Result::Ok(255)"
      ],
      "cases": [
        {
          "args": [
            "ff"
          ],
          "expect": {
            "ok": 255
          }
        },
        {
          "args": [
            "0A1"
          ],
          "expect": {
            "ok": 161
          }
        },
        {
          "args": [
            "ffffffff"
          ],
          "expect": {
            "ok": 4294967295
          }
        },
        {
          "args": [
            ""
          ],
          "expect": {
            "err": true
          }
        },
        {
          "args": [
            "xyz"
          ],
          "expect": {
            "err": true
          }
        },
        {
          "args": [
            "123456789"
          ],
          "expect": {
            "err": true
          }
        }
      ],
      "deps": [
        "digit"
      ]
    }
  ]
}
```

## Two other kinds of reply

If the task cannot be planned because decisions that only the requester can make are missing (what currency, which of two readings, what to do on conflict), reply with ONLY
`{"status": "unclear", "questions": ["...", "..."]}`: short, specific questions. Do not guess in order to avoid asking.

If the task is too large to plan as one set of functions (several separate modules, or a service with storage, a network or a clock), reply with ONLY
`{"status": "too_big", "modules": [{"name": "...", "summary": "what this module is responsible for and what it exchanges with the others"}]}`: a breakdown the requester can confirm before anything is built.

A task that is merely long but fully specified is NOT too big: plan it.
