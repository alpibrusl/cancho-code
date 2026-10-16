# How to write a plan

You are planning, not programming. A program (the project driver) will build what you describe one unit at a time with a model, checking each unit with the examples and tests you wrote, and then the whole. You write NO implementation. Your reply is read by a program: it must be one JSON object and nothing else (a fence around it is tolerated, prose after it is ignored).

## The plan

```
{ "name": "<short name>",
  "units": [ { "id": "...", "signature": "...", "description": "...", "examples": [...], "tests": [...], "deps": [...] } ] }
```

- **A unit is ONE function.** Cut the task into units small enough that one function and its examples can be written and checked alone. Split out what a person would split out: a validity check, a tokenizer, a comparison, a number reader, a formatter. A library is typically 2 to 9 units. A unit whose description needs the words "and then" more than twice is two units.
- **id**: letters, digits, underscore. **deps**: the ids of the units whose functions this one calls (no cycles; a helper comes before what uses it).
- **signature**: `fn NAME(params) -> [EFFECTS] TYPE`. The effect row is REQUIRED: `[]` for a pure function, `[heap]` when it takes `heap: &!h Heap`. Region parameters come after the name: `fn f[&r](s: &r [byte]) -> [] int`. A function the brief names (a bullet `- name(...) : ...`) keeps exactly that name, with no prefix: the brief's names are the package's public API, and the build is refused if a unit does not declare each one. Every other function (a helper you add) is prefixed with the task name (`hexnum_parse`) so names cannot collide.
- **cancho has no string type**: text in is `&r [byte]`; text out that the function builds is `buffer.Buffer`; a fallible result is `result.Result[T, &static [byte]]`; an optional one `option.Option[T]`. A number is `int` (64-bit, overflow is an error, not a wrap). There are no closures and no `break`/`continue`.
- If REQUIRED PUBLIC FUNCTIONS are given below the task, use exactly those signatures for them. Add helper units freely; a helper's signature is yours to design.
- **description**: what the function MEANS, in words: units, every edge rule, what counts as invalid, what the signature cannot say. The builder sees only the description, the examples and the tests, and the task is judged by a hidden audit you cannot see: anything the task requires must reach the builder through your units. Be exact about boundaries ("at most 9 digits", "lower case only", "an empty input is an error"). Do not dictate an algorithm unless the task does.
- **examples**: each is `CALL == EXPECTED` (the call first, once, then `==`, then the value). At least one per unit calls that unit's own function. `==` compares only scalars (int, bool); for a function that returns a `Result`, an `Option` or a `buffer.Buffer` an example is documentation, and the real checks are the `cases`. An example can never mention `heap` or a local variable: a function that takes a heap, or returns text, a buffer or a list, MUST have `cases` (or `tests`); the plan check rejects it otherwise. Examples MUST BE CORRECT: a wrong example makes the build fail for a reason the builder cannot know. Fewer, certain examples beat many.
- **cases** (how a unit is tested): a list of `{"args": [...], "expect": ...}`. You write DATA, not test code: the arguments in order (leave out the `heap`), and what the call must give. A program turns the cases into the unit's tests, from the signature, so they compile and call the function correctly; this is why you must not write test code. `expect` is: an integer, `true`/`false`, or a string for an `int`, `bool` or text/buffer result; `null` for `None` and the value itself for `Some`; `{"ok": value}` or `{"err": true}` for a `result.Result` (for an `int` error type, `{"err": 3}` pins the number; text error messages are never compared); a list or vec of text is a JSON array of strings, in order. Text is a JSON string, or `{"bytes": [13, 10, 255]}` when it holds bytes a string cannot (carriage returns, NUL, invalid UTF-8): write `{"bytes": [...]}` instead of an escape you are unsure about. Every unit gets cases, including the failure cases: a unit only ever shown valid input will accept invalid input. **Cases must be CORRECT**: a wrong case makes the build fail for a reason the builder cannot know. Derive each expected value by hand from your own description, never write a case whose result needs heavy arithmetic you cannot do exactly (big powers, large products modulo something): leave such a case out rather than guess. Prefer certain cases over many, but never leave a rule out for lack of room: 6 to 15 cases is typical for a unit, more for one that carries many rules.
- **tests** (a fallback, replaces the cases; see "When `cases` cannot express a signature" below): cancho test source, only for a signature whose types `cases` cannot express. The test file already starts with `edition 7;` and `import std.test;`; a test is `pub fn test_NAME() -> [] int { ...; return 0; }` using `test.assert(CONDITION)` or `test.assert_eq(INT, INT)`; one that needs a heap is `pub fn test_NAME[&h](heap: &!h Heap) -> [heap] int` (NEVER `(world: World)`, never `split`); names must be unique across the plan; do not import in a test what the project already imports. A unit has `cases` OR `tests`, never both.
- Cover the task's every stated rule in some unit's description AND in some example or test, including the failure cases (see "Cover everything the task states" below).

## Several files (ONLY when the task asks for them)

Most tasks are one file: then leave `files` and `file` out. When the task says the library is several files, or modules, add:

- **`files`**, at the root next to `units`: one entry per file the task names, `{"file": "tokens.cho", "module": "tokens", "imports": ["std.buffer"]}`: the file's name as the task gives it, the module name the task gives, and in `imports` the `std.` modules the file's functions will use and the `module` of every OTHER file whose functions this file calls. The builder writes each file's `module` and `import` lines from this: it does not guess them. A file that is used by another comes first: the imports may not form a cycle, and a file with no unit is refused.
- **`file`** on every unit: the file the task says the function belongs to (`"file": "tokens.cho"`).
- A unit that depends on a unit of ANOTHER file needs that file's module in its own file's `imports`, or the plan is refused. Two files may not both declare a function of the same name. Helpers keep the task prefix as ever.
- An example calls the unit's own function by its plain name. To call a function of another module inside an example or a test, put the module's name in front, `tokens.tk_kind(toks, 0)`; the unit's tests run inside its own module, so they see the imports of its file. A function another module calls must be `pub fn` (the builder is told).
- `project.cho` is the root file: no module can import it, so a unit that other files use never goes there. Leave it out of `files`, unless a unit of yours (the one that wires the modules together) is to live there: then `{"file": "project.cho", "imports": [...]}`.

```text
{ "name": "widths",
  "files": [ { "file": "tokens.cho", "module": "tokens" },
             { "file": "parser.cho", "module": "parser", "imports": ["tokens"] } ],
  "units": [ { "id": "digits", "file": "tokens.cho", "signature": "fn tok_digits(n: int) -> [] int", "examples": ["tok_digits(12) == 2"], "deps": [] },
             { "id": "width", "file": "parser.cho", "signature": "fn parse_width(n: int) -> [] int", "examples": ["parse_width(12) == 3"], "deps": ["digits"] } ] }
```

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

## Cover everything the task states

The build is judged by a hidden audit that checks every rule the task states, on inputs you have not seen. A rule that no case or test exercises is a rule the builder has no way to learn, and the audit will find it. Before you write a unit's cases, go through the task sentence by sentence and list what it states; then check each item has at least one case (or test) in the unit that owns it:
- every rule, and each boundary or limit of it: the smallest and the largest value allowed, and the value just outside each;
- the empty input, a single element, a repeated element, an input that is already in the target form;
- EVERY kind of error the task names, one case for each kind (one case never stands for two kinds of error), with the failure `expect` written out;
- every case, order, tie, "last one wins", "unchanged", "ignored" or "kept exactly" clause, and what the task says about non-ASCII bytes, whitespace or signs;
- the task's own worked examples are exact: put every one of them, as written, among the cases of the unit that owns that function (an example of a public function is a case of that unit). A worked example about something you split into a helper goes into the helper's description and its cases.
Put the rule itself into the description of the unit that implements it, in the task's words, so the builder reads the same sentence you did. Do not drop a statement because it looks minor.

## When `cases` cannot express a signature

`cases` can express: for parameters, `int`, `bool`, text (`&r [byte]`), a list of text (`&l list.List[Box[Box[[byte]]]]`), a vec of text slices, and the heap; for the result, `int`, `bool`, text (`buffer.Buffer`, `&r [byte]` or `Box[[byte]]`), a list of text, and `option.Option[X]` or `result.Result[X, E]` with X an `int`, `bool`, `buffer.Buffer` or `&r [byte]` (E an `int` or text). It cannot express an `Option` of a `Box`, a slice of ints (`&k [int]`), a vec of ints, a record, a tuple. Then the plan check answers `[CASES_ERROR] ... give tests instead`, and you have two ways out:
1. **Change the signature** when the task does not fix it: an owned optional text is `option.Option[buffer.Buffer]`, not `option.Option[Box[[byte]]]`; keep `cases`.
2. **Give that unit `tests` and delete its `cases`** (the other units keep theirs). The unit still needs an `examples` entry that calls its own function with its whole name (it is documentation here, so it may pass a heap and text). The tests are small cancho functions: a helper that calls the unit and answers 0 when the result is right, one `pub fn test_...` per group of checks, one check for EVERY kind of result (found, missing, error, empty) and every edge the task states. Give every helper a name unique in the whole plan (a short prefix of the unit: `kvf_`), compare bytes with a loop, and free what you take (`unbox_slice(heap, b)` for a `Box`, `buffer.drop(heap, b)` for a buffer). A payload that owns memory (a buffer, a `Box`, a list) cannot be discarded: never match it with `Ok(_)` or `Some(_)`, bind it and free it in that arm (the plan check refuses the `_` there), as the example below does. Mind the escapes: a test is cancho source INSIDE a JSON string, and a cancho string literal cannot contain a real line break. Where the source needs the two characters backslash and n between quotes, write `\\n` in the JSON (`\\"` for a quote, `\\\\` for a backslash); a bare `\n` in the JSON becomes a real line break and the plan check refuses it (`bad-test`). A unit for `option.Option[Box[[byte]]]`, shaped as the plan should be:

```json
{
  "name": "kv",
  "units": [
    {
      "id": "find",
      "signature": "fn kv_find[&h, &t, &k](heap: &!h Heap, text: &t [byte], key: &k [byte]) -> [heap] option.Option[Box[[byte]]]",
      "description": "text is one line `key=value`. Some(value) (a new owned copy of the bytes after the first `=`, empty allowed) when the bytes before the first `=` are exactly key (case matters); None when key differs, and None when the line has no `=`. Never panics.",
      "examples": [
        "kv_find(heap, \"a=1\", \"a\") == option.Option::Some(\"1\")",
        "kv_find(heap, \"a=1\", \"b\") == option.Option::None"
      ],
      "tests": [
        "fn kvf_same[&a, &b](x: &a [byte], y: &b [byte]) -> [] bool { if len(x) != len(y) { return false; } var k = 0; while k < len(x) { if x[k] != y[k] { return false; } k = k + 1; } return true; }",
        "fn kvf_some[&h](heap: &!h Heap, text: &static [byte], key: &static [byte], want: &static [byte]) -> [heap] int { match kv_find(heap, text, key) { option.Option::Some(b) => { var same = false; borrow b as &x in { same = kvf_same(contents(x), want); } unbox_slice(heap, b); if same { return 0; } return 1; } option.Option::None => { return 2; } } }",
        "fn kvf_none[&h](heap: &!h Heap, text: &static [byte], key: &static [byte]) -> [heap] int { match kv_find(heap, text, key) { option.Option::Some(b) => { unbox_slice(heap, b); return 1; } option.Option::None => { return 0; } } }",
        "pub fn test_kv_find_found[&h](heap: &!h Heap) -> [heap] int { test.assert_eq(kvf_some(heap, \"a=1\", \"a\", \"1\"), 0); test.assert_eq(kvf_some(heap, \"k=\", \"k\", \"\"), 0); return 0; }",
        "pub fn test_kv_find_missing[&h](heap: &!h Heap) -> [heap] int { test.assert_eq(kvf_none(heap, \"a=1\", \"b\"), 0); test.assert_eq(kvf_none(heap, \"novalue\", \"a\"), 0); return 0; }"
      ],
      "deps": []
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
