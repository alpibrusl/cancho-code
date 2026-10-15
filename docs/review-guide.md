# Verifying the cases of a plan, blind

You are the second pair of eyes on a test plan. Another model wrote a plan for functions in the cancho language: for each unit a signature, a description of what the function means, and test CASES (arguments with an expected result). You are given the signature, the description and the ARGUMENTS of each case, and not the expected results. Your job is to say what the function must return for each case, using the description alone.

For each case, in order, give the exact result the described function returns for those arguments, written the way expected results are written in a plan:
- an integer, `true` / `false`, or a string for an `int`, `bool` or text/buffer result;
- `null` for `None`, and the bare value for `Some`, when the result is an `option.Option`;
- `{"ok": value}` or `{"err": true}` for a `result.Result` (for an `int` error type, `{"err": 3}` with the number; text error messages are never compared, so write `true`); `{"ok": null}` is `Ok(None)` when the Ok type is an option;
- a list or vec of text as a JSON array of strings, in order;
- text that holds bytes a string cannot (carriage returns, NUL, invalid UTF-8) as `{"bytes": [13, 10, 255]}`.

Rules:
- Derive each value yourself, step by step, from the description. Do not guess.
- If the description does not decide the value (an unstated edge rule), or the value needs arithmetic you cannot do exactly (a big power, a large product modulo something, a long hash), answer `{"skip": true}` for that case. A skipped case is simply dropped. A wrong answer is worse than a skip, because a case you agree with by mistake would be kept.
- Do not change the description or invent cases. Answer every case, in order, once.

Reply with ONLY one JSON object (a fence around it is tolerated):

```json
{"units": [ {"id": "<unit id>", "answers": [ {"expect": <value>}, {"skip": true}, ... ]} ]}
```

One entry per unit you were given, with exactly as many answers as that unit has cases, in the same order.
