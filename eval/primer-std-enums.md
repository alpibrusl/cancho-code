
## Addendum: the standard enums and bytes (not in `cancho agent-guidelines`)

Facts the language page does not state, measured to be needed (alpibrusl/cancho#458):

- `Option` and `Result` are ordinary enums in the standard library. Import them (`import std.option;`, `import std.result;`) and write the types with the module name: `option.Option[int]`, `result.Result[int, &static [byte]]`.
- You build a value with the variant, qualified: `option.Option::Some(5)`, `option.Option::None`, `result.Result::Ok(5)`, `result.Result::Err("a message")`. There are no helper functions `ok(...)`, `err(...)`, `some(...)`: `result.ok(x)` and `result.err("m")` do not exist.
- You take one apart with `match`: `match r { result.Result::Ok(v) => { ... } result.Result::Err(e) => { ... } }`, and each arm must return or assign.
- A byte slice is `&r [byte]`: `len(s)` is its length, `s[i]` is a `byte`, and a `byte` is not an `int`: compare with `int_of(s[i]) == 48`. There is no string type.
