#!/usr/bin/env python3
"""Reference expander for src/cases.cho: the oracle of scripts/test-cases.sh.

    cases_ref.py PLAN.json     new plan on stdout, report on stderr, exit 0 (no problem) or 1

The spec, in one place (the cancho module is written against the same text):

A unit that carries "cases": [{"args": [...], "expect": V}, ...] gets its "tests" (cancho source items, strings) generated from its
signature, "cases" is removed, and "examples" is filled (up to 3 documentation strings CALL == EXPECTED) when it is absent or empty.
Units without "cases" and every other field are copied as they are. A unit with any problem is copied as it was (cases and all) and
reported: `[CASES_ERROR]<TAB>unit id<TAB>case number or -<TAB>message`.

Types: parameters int, bool, text (`&r [byte]`, `&static [byte]`), the heap (`&!h Heap`, never in args). Returns int, bool,
buffer.Buffer, option.Option[int|bool], result.Result[T, E] (T in int, bool, buffer.Buffer, text; E anything, never compared), text.
expect: int / bool / string; Option: null = None, else Some(value); Result: {"ok": v} or {"err": anything}.
"""
import json
import sys

WS = " \t\n\r"
INT_MIN, INT_MAX = -(1 << 63), (1 << 63) - 1
MAX_PARAMS = 32


def trim(s):
    return s.strip(WS)


def is_start(c):
    return c.isascii() and (c.isalpha() or c == "_")


def is_part(c):
    return c.isascii() and (c.isalnum() or c == "_")


def ident_end(s, p):
    if p >= len(s) or not is_start(s[p]):
        return p
    i = p + 1
    while i < len(s) and is_part(s[i]):
        i += 1
    return i


def skip_sp(s, p):
    while p < len(s) and s[p] == " ":
        p += 1
    return p


def sid_of(unit_id):
    out = []
    for b in unit_id.encode("utf-8"):
        c = chr(b)
        out.append(c if (b < 128 and (c.isalnum() or c == "_")) else "_")
    return "".join(out)


# ---- the signature ------------------------------------------------------------

def parse_sig(sig):
    """(name, [param type texts], row, return text) or None."""
    if not sig.startswith("fn "):
        return None
    a = skip_sp(sig, 3)
    b = ident_end(sig, a)
    if b == a:
        return None
    name = sig[a:b]
    c = skip_sp(sig, b)
    if c < len(sig) and sig[c] == "[":
        q = sig.find("]", c)
        if q < 0:
            return None
        c = skip_sp(sig, q + 1)
    if c >= len(sig) or sig[c] != "(":
        return None
    depth = 0
    i = c
    close = -1
    while i < len(sig):
        ch = sig[i]
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
            if depth == 0:
                close = i
                break
        i += 1
    if close < 0 or sig[close] != ")":
        return None
    inner = sig[c + 1:close]
    d = skip_sp(sig, close + 1)
    if sig[d:d + 2] != "->":
        return None
    e = skip_sp(sig, d + 2)
    if e >= len(sig) or sig[e] != "[":
        return None
    f = sig.find("]", e)
    if f < 0:
        return None
    row = trim(sig[e + 1:f])
    ret = trim(sig[f + 1:])
    if ret == "":
        return None
    params = []
    if trim(inner) != "":
        depth = 0
        start = 0
        parts = []
        for i, ch in enumerate(inner):
            if ch in "([":
                depth += 1
            elif ch in ")]":
                depth -= 1
            elif ch == "," and depth == 0:
                parts.append(inner[start:i])
                start = i + 1
        parts.append(inner[start:])
        for part in parts:
            part = trim(part)
            if part == "":
                return None
            k = part.find(":")
            if k < 0:
                return None
            nm = trim(part[:k])
            if nm == "" or ident_end(nm, 0) != len(nm):
                return None
            params.append(trim(part[k + 1:]))
    return name, params, row, ret


def after_amp(t, bang):
    """For `&r X` / `&!r X`: (identifier, rest after spaces) or None."""
    if not t.startswith("&"):
        return None
    p = 1
    if bang:
        if len(t) < 2 or t[1] != "!":
            return None
        p = 2
    e = ident_end(t, p)
    if e == p:
        return None
    return t[p:e], t[skip_sp(t, e):]


def classify_param(t):
    if t == "int":
        return "int"
    if t == "bool":
        return "bool"
    r = after_amp(t, False)
    if r is not None and r[1] == "[byte]":
        return "text"
    r = after_amp(t, True)
    if r is not None and r[1] == "Heap":
        return "heap"
    return None


def classify_ret(t):
    """(kind, tkind, err_is_buffer) or (None, unsupported text, False)."""
    if t == "int":
        return "int", None, False
    if t == "bool":
        return "bool", None, False
    if t == "buffer.Buffer":
        return "buf", None, False
    r = after_amp(t, False)
    if r is not None and r[1] == "[byte]":
        return "text", None, False
    if t.startswith("option.Option[") and t.endswith("]"):
        inner = trim(t[len("option.Option["):-1])
        if inner in ("int", "bool"):
            return "opt", inner, False
        return None, t, False
    if t.startswith("result.Result[") and t.endswith("]"):
        inner = t[len("result.Result["):-1]
        depth = 0
        comma = -1
        for i, ch in enumerate(inner):
            if ch in "([":
                depth += 1
            elif ch in ")]":
                depth -= 1
            elif ch == "," and depth == 0:
                comma = i
                break
        if comma < 0:
            return None, t, False
        tt = trim(inner[:comma])
        ee = trim(inner[comma + 1:])
        if tt in ("int", "bool"):
            tk = tt
        elif tt == "buffer.Buffer":
            tk = "buf"
        else:
            r = after_amp(tt, False)
            if r is not None and r[1] == "[byte]":
                tk = "text"
            else:
                return None, tt, False
        return "res", tk, ee == "buffer.Buffer"
    return None, t, False


# ---- literals -----------------------------------------------------------------

def text_lit(s):
    """The cancho string literal for s, or None when it cannot be written."""
    out = ['"']
    for ch in s:
        o = ord(ch)
        if ch == '"':
            out.append('\\"')
        elif ch == "\\":
            out.append("\\\\")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\t":
            out.append("\\t")
        elif o < 0x20 or o == 0x7F:
            return None
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def int_lit(n):
    """Code and documentation alike: `-5` (the language has unary minus); the one int that has no literal is spelled out."""
    if n == INT_MIN:
        return "0 - 9223372036854775807 - 1"
    return str(n)


def kind_of(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "a boolean"
    if isinstance(v, int):
        return "an integer"
    if isinstance(v, float):
        return "a number that is not an integer"
    if isinstance(v, str):
        return "a string"
    if isinstance(v, list):
        return "a list"
    return "an object"


def value_lit(kind, v, who):
    """(literal, None) or (None, message); who names the value for the message."""
    if kind == "int":
        if not is_int(v):
            return None, "%s must be a JSON integer, got %s" % (who, kind_of(v))
        if v < INT_MIN or v > INT_MAX:
            return None, "%s is out of the range of int" % who
        return int_lit(v), None
    if kind == "bool":
        if not isinstance(v, bool):
            return None, "%s must be true or false, got %s" % (who, kind_of(v))
        return ("true" if v else "false"), None
    # text (a text parameter, a buffer or a text result)
    if not isinstance(v, str):
        return None, "%s must be a JSON string, got %s" % (who, kind_of(v))
    lit = text_lit(v)
    if lit is None:
        return None, "%s cannot be written in a cancho string literal; use another input" % who
    return lit, None


# ---- helper and test generation -------------------------------------------------

SAME = ("fn cases_{s}_same[&a, &b](x: &a [byte], y: &b [byte]) -> [] bool { if len(x) != len(y) { return false; } var i = 0; "
        "while i < len(x) { if int_of(x[i]) != int_of(y[i]) { return false; } i = i + 1; } return true; }")


def cmp_buf(var):
    return ("var same = false; borrow %s as &x in { same = cases_{s}_same(buffer.bytes(x), want); } buffer.drop(heap, %s); "
            "if same { return 0; } return 1;" % (var, var))


def build_helpers(sid, name, ptypes, kind, tkind, err_buf, used):
    """The helper items (strings) for the kinds in `used`, in a fixed order."""
    has_heap = "heap" in ptypes
    plist = []
    clist = []
    n = 0
    for t in ptypes:
        if t == "heap":
            plist.append("heap: &!h Heap")
            clist.append("heap")
        else:
            n += 1
            plist.append("a%d: %s" % (n, {"int": "int", "bool": "bool", "text": "&static [byte]"}[t]))
            clist.append("a%d" % n)
    call = "%s(%s)" % (name, ", ".join(clist))
    gen = "[&h]" if has_heap else ""
    row = "[heap]" if has_heap else "[]"

    def head(h, want):
        ps = list(plist)
        if want:
            ps.append("want: %s" % want)
        return "fn cases_%s_%s%s(%s) -> %s int" % (sid, h, gen, ", ".join(ps), row)

    def buf_drop_err(arm_ret):
        return "result.Result::Err(e) => { buffer.drop(heap, e); return %d; }" % arm_ret

    items = []
    if kind in ("buf", "text") or (kind == "res" and tkind in ("buf", "text")):
        items.append(SAME.replace("{s}", sid))
    wt = {"int": "int", "bool": "bool", "buf": "&static [byte]", "text": "&static [byte]"}
    if "is" in used:
        if kind == "buf":
            body = "let got = %s; %s" % (call, cmp_buf("got").replace("{s}", sid))
        else:
            body = "let got = %s; if cases_%s_same(got, want) { return 0; } return 1;" % (call, sid)
        items.append("%s { %s }" % (head("is", "&static [byte]"), body))
    if "some" in used:
        items.append("%s { match %s { option.Option::Some(v) => { if v == want { return 0; } return 1; } "
                     "option.Option::None => { return 2; } } }" % (head("some", wt[tkind]), call))
    if "none" in used:
        items.append("%s { match %s { option.Option::Some(_) => { return 2; } option.Option::None => { return 0; } } }"
                     % (head("none", None), call))
    if "ok" in used:
        if tkind in ("int", "bool"):
            okarm = "result.Result::Ok(v) => { if v == want { return 0; } return 1; }"
        elif tkind == "text":
            okarm = "result.Result::Ok(v) => { if cases_%s_same(v, want) { return 0; } return 1; }" % sid
        else:
            okarm = "result.Result::Ok(b) => { %s }" % cmp_buf("b").replace("{s}", sid)
        errarm = buf_drop_err(2) if err_buf else "result.Result::Err(_) => { return 2; }"
        items.append("%s { match %s { %s %s } }" % (head("ok", wt[tkind]), call, okarm, errarm))
    if "err" in used:
        okarm = ("result.Result::Ok(b) => { buffer.drop(heap, b); return 2; }" if tkind == "buf"
                 else "result.Result::Ok(_) => { return 2; }")
        errarm = buf_drop_err(0) if err_buf else "result.Result::Err(_) => { return 0; }"
        items.append("%s { match %s { %s %s } }" % (head("err", None), call, okarm, errarm))
    return items


def expand_unit(unit, report):
    """The new unit dict, or None when there was a problem (already reported)."""
    uid = unit.get("id")
    who = uid if isinstance(uid, str) else "-"

    def err(k, msg):
        report.append("[CASES_ERROR]\t%s\t%s\t%s" % (who, k, msg))

    cases = unit["cases"]
    if not isinstance(cases, list) or len(cases) == 0:
        err("-", 'cases must be a non-empty list of {"args": [...], "expect": value} objects')
        return None
    if "tests" in unit and not (isinstance(unit["tests"], list) and len(unit["tests"]) == 0):
        err("-", "this unit has both cases and tests; give cases OR tests, not both")
        return None
    sig = unit.get("signature")
    if not isinstance(sig, str):
        err("-", "a unit with cases needs a string signature")
        return None
    parsed = parse_sig(sig)
    if parsed is None:
        err("-", "cannot read the signature; it must be `fn NAME(params) -> [row] TYPE`")
        return None
    name, ptexts, row, rtext = parsed
    if len(ptexts) > MAX_PARAMS:
        err("-", "the signature has more than %d parameters; give tests instead" % MAX_PARAMS)
        return None
    ptypes = []
    heaps = 0
    for t in ptexts:
        c = classify_param(t)
        if c == "heap":
            heaps += 1
            if heaps > 1:
                c = None
        if c is None:
            err("-", "signature uses a type that cases cannot express (%s); give tests instead" % t)
            return None
        ptypes.append(c)
    kind, tkind, err_buf = classify_ret(rtext)
    if kind is None:
        err("-", "signature uses a type that cases cannot express (%s); give tests instead" % tkind)
        return None
    has_heap = "heap" in ptypes
    if (kind == "buf" or (kind == "res" and (tkind == "buf" or err_buf))) and not has_heap:
        err("-", "the function returns a buffer.Buffer but takes no heap parameter; give tests instead")
        return None
    sid = sid_of(who) if isinstance(uid, str) else sid_of("-")
    argtypes = [t for t in ptypes if t != "heap"]

    problems = len(report)
    tests = []
    examples = []
    used = []
    for k, case in enumerate(cases, 1):
        if not (isinstance(case, dict) and isinstance(case.get("args"), list) and "expect" in case):
            err(k, 'a case must be an object with "args" (a list) and "expect"')
            continue
        args, expect = case["args"], case["expect"]
        if len(args) != len(argtypes):
            err(k, "args has %d value(s) but the function takes %d (the heap is not given in args)" % (len(args), len(argtypes)))
            continue
        lits = []
        bad = False
        for i, (a, t) in enumerate(zip(args, argtypes), 1):
            lc, m = value_lit(t, a, "argument %d" % i)
            if m is not None:
                err(k, m)
                bad = True
                break
            lits.append(lc)
        if bad:
            continue
        # the call, with the heap where the signature has it
        ci = 0
        call_args = []
        for t in ptypes:
            if t == "heap":
                call_args.append("heap")
            else:
                call_args.append(lits[ci])
                ci += 1
        # the expectation
        shape = None   # (helper or None, want literal or None, expected doc text)
        m = None
        if kind in ("int", "bool"):
            lc, m = value_lit(kind, expect, "expect")
            if m is None:
                shape = (None, lc, lc)
        elif kind in ("buf", "text"):
            lc, m = value_lit("text", expect, "expect")
            if m is None:
                shape = ("is", lc, lc)
        elif kind == "opt":
            if expect is None:
                shape = ("none", None, "option.Option::None")
            else:
                lc, m = value_lit(tkind, expect, "expect")
                if m is None:
                    shape = ("some", lc, "option.Option::Some(%s)" % lc)
        else:
            if not (isinstance(expect, dict) and len(expect) == 1 and ("ok" in expect or "err" in expect)):
                m = 'expect for a Result must be {"ok": value} or {"err": anything}'
            elif "err" in expect:
                shape = ("err", None, "result.Result::Err")
            else:
                vk = {"int": "int", "bool": "bool", "buf": "text", "text": "text"}[tkind]
                lc, m = value_lit(vk, expect["ok"], 'expect "ok"')
                if m is None:
                    shape = ("ok", lc, "result.Result::Ok(%s)" % lc)
        if shape is None:
            err(k, m)
            continue
        helper, want, doc = shape
        hdr = ("pub fn test_%s_%d[&h](heap: &!h Heap) -> [heap] int" if has_heap else "pub fn test_%s_%d() -> [] int") % (sid, k)
        if helper is None:
            body = "test.assert(%s(%s) == %s); return 0;" % (name, ", ".join(call_args), want)
        else:
            hargs = list(call_args)
            if want is not None:
                hargs.append(want)
            body = "test.assert_eq(cases_%s_%s(%s), 0); return 0;" % (sid, helper, ", ".join(hargs))
            if helper not in used:
                used.append(helper)
        tests.append("%s { %s }" % (hdr, body))
        line = "%s(%s) == %s" % (name, ", ".join(call_args), doc)
        ctext = "%s(%s)" % (name, ", ".join(call_args))
        if " == " not in ctext and "|| true" not in line and "or true" not in line:
            examples.append(line)
    if len(report) > problems:
        return None
    order = ["is", "some", "none", "ok", "err"]
    helpers = build_helpers(sid, name, ptypes, kind, tkind, err_buf, [h for h in order if h in used])
    new_tests = helpers + tests
    ex = unit.get("examples")
    fill = "examples" not in unit or (isinstance(ex, list) and len(ex) == 0)
    if fill and not examples:
        err("-", 'no case can be shown as an example (its call text contains " == "); add a case without it, or give examples')
        return None
    out = {}
    for key, val in unit.items():
        if key == "cases":
            if "examples" not in unit:
                out["examples"] = examples[:3]
            if "tests" not in unit:
                out["tests"] = new_tests
        elif key == "examples":
            out[key] = examples[:3] if fill else val
        elif key == "tests":
            out[key] = new_tests
        else:
            out[key] = val
    return out


def depth_of(v):
    if isinstance(v, dict):
        return 1 + max([depth_of(x) for x in v.values()] + [0])
    if isinstance(v, list):
        return 1 + max([depth_of(x) for x in v] + [0])
    return 0


def expand(text):
    report = []
    try:
        plan = json.loads(text)
    except ValueError:
        report.append("[CASES_ERROR]\t-\t-\tthe plan is not valid JSON")
        return text, report
    if not (isinstance(plan, dict) and isinstance(plan.get("units"), list)):
        report.append('[CASES_ERROR]\t-\t-\tthe plan must be a JSON object with a "units" array')
        return text, report
    if depth_of(plan) > 55:
        report.append("[CASES_ERROR]\t-\t-\tthe plan is nested more than 55 levels deep")
        return text, report
    units = []
    for u in plan["units"]:
        if isinstance(u, dict) and "cases" in u:
            nu = expand_unit(u, report)
            units.append(u if nu is None else nu)
        else:
            units.append(u)
    plan["units"] = units
    return json.dumps(plan, ensure_ascii=False), report


def main():
    text = open(sys.argv[1], "rb").read().decode("utf-8")
    new, report = expand(text)
    sys.stdout.write(new)
    sys.stdout.flush()
    for line in report:
        sys.stderr.write(line + "\n")
    return 1 if report else 0


if __name__ == "__main__":
    sys.exit(main())
