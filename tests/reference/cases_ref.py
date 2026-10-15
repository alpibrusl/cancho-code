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


def is_text_type(t):
    r = after_amp(t, False)
    return r is not None and r[1] == "[byte]"


LIST_T = "list.List[Box[Box[[byte]]]]"
# parameter kinds
P_INT, P_BOOL, P_TEXT, P_HEAP, P_LIST, P_VEC = "int", "bool", "text", "heap", "list", "vec"
# value kinds of a result: 0 int, 1 bool, 2 buffer, 3 text slice, 4 list, 5 owned box
V_INT, V_BOOL, V_BUF, V_TEXT, V_LIST, V_BOX = range(6)


def classify_param(t):
    """(kind, is_static) or None."""
    if t == "int":
        return P_INT, False
    if t == "bool":
        return P_BOOL, False
    r = after_amp(t, False)
    if r is not None:
        if r[1] == "[byte]":
            return P_TEXT, r[0] == "static"
        if r[1] == LIST_T:
            return P_LIST, False
        if r[1].startswith("vec.Vec[") and r[1].endswith("]") and is_text_type(trim(r[1][len("vec.Vec["):-1])):
            return P_VEC, False
    r = after_amp(t, True)
    if r is not None and r[1] == "Heap":
        return P_HEAP, False
    return None


def plain_v(t):
    if t == "int":
        return V_INT
    if t == "bool":
        return V_BOOL
    if t == "buffer.Buffer":
        return V_BUF
    if is_text_type(t):
        return V_TEXT
    if t == LIST_T:
        return V_LIST
    if t == "Box[[byte]]":
        return V_BOX
    return None


def opt_inner(t):
    """The value kind inside `option.Option[X]` (X int, bool, buffer, text slice), None when t is not a supported option;
    the string 'bad' when it is an option of something else."""
    if t.startswith("option.Option[") and t.endswith("]"):
        v = plain_v(trim(t[len("option.Option["):-1]))
        if v is None or v >= V_LIST:
            return "bad"
        return v
    return None


def classify_ret(t):
    """(outer, v, e, topt) where outer 0 plain / 1 option / 2 result, e 0 other / 1 int / 2 buffer, or (None, unsupported text, 0, 0)."""
    v = plain_v(t)
    if v is not None:
        return 0, v, 0, False
    o = opt_inner(t)
    if o == "bad":
        return None, t, 0, False
    if o is not None:
        return 1, o, 0, False
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
            return None, t, 0, False
        tt = trim(inner[:comma])
        ee = trim(inner[comma + 1:])
        e = 1 if ee == "int" else 2 if ee == "buffer.Buffer" else 0
        o = opt_inner(tt)
        if o == "bad":
            return None, tt, 0, False
        if o is not None:
            return 2, o, e, True
        v = plain_v(tt)
        if v is None:
            return None, tt, 0, False
        return 2, v, e, False
    return None, t, 0, False


# ---- bytes and literals -------------------------------------------------------------

def utf8_seq(b, i):
    """The length of the valid UTF-8 sequence at b[i] and its code point, or (0, 0)."""
    c = b[i]
    n = len(b)

    def cont(k, lo=0x80, hi=0xBF):
        return i + k < n and lo <= b[i + k] <= hi

    if 0xC2 <= c <= 0xDF and cont(1):
        return 2, ((c & 0x1F) << 6) | (b[i + 1] & 0x3F)
    if 0xE0 <= c <= 0xEF:
        lo, hi = (0xA0, 0xBF) if c == 0xE0 else (0x80, 0x9F) if c == 0xED else (0x80, 0xBF)
        if cont(1, lo, hi) and cont(2):
            return 3, ((c & 0x0F) << 12) | ((b[i + 1] & 0x3F) << 6) | (b[i + 2] & 0x3F)
    if 0xF0 <= c <= 0xF4:
        lo, hi = (0x90, 0xBF) if c == 0xF0 else (0x80, 0x8F) if c == 0xF4 else (0x80, 0xBF)
        if cont(1, lo, hi) and cont(2) and cont(3):
            return 4, ((c & 0x07) << 18) | ((b[i + 1] & 0x3F) << 12) | ((b[i + 2] & 0x3F) << 6) | (b[i + 3] & 0x3F)
    return 0, 0


ESC = {34: '\\"', 92: "\\\\", 10: "\\n", 9: "\\t", 13: "\\r", 0: "\\0"}


def text_lit(b):
    """The cancho string literal for the bytes b, or None when some byte cannot be written in one: the lexer takes printable
    ASCII, the escapes \\" \\\\ \\n \\t \\r \\0, and UTF-8 text; the other control bytes, DEL, the C1 controls, U+2028, U+2029,
    U+FEFF and bytes that are not UTF-8 are built from their hex instead."""
    out = ['"']
    i = 0
    while i < len(b):
        c = b[i]
        if c in ESC:
            out.append(ESC[c])
            i += 1
        elif 32 <= c <= 126:
            out.append(chr(c))
            i += 1
        else:
            n, cp = utf8_seq(b, i)
            if n == 0 or cp < 0xA0 or cp in (0x2028, 0x2029, 0xFEFF):
                return None
            out.append(b[i:i + n].decode("utf-8"))
            i += n
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


def scalar_lit(kind, v, who):
    """(literal, None) or (None, message) for an int or a bool."""
    if kind == "int":
        if not is_int(v):
            return None, "%s must be a JSON integer, got %s" % (who, kind_of(v))
        if v < INT_MIN or v > INT_MAX:
            return None, "%s is out of the range of int" % who
        return int_lit(v), None
    if not isinstance(v, bool):
        return None, "%s must be true or false, got %s" % (who, kind_of(v))
    return ("true" if v else "false"), None


def text_bytes(v, who):
    """(bytes, None) or (None, message). A text is a JSON string (its UTF-8) or {"bytes": [0..255, ...]}."""
    if isinstance(v, str):
        return v.encode("utf-8"), None
    if isinstance(v, dict) and len(v) == 1 and "bytes" in v:
        lst = v["bytes"]
        if isinstance(lst, list) and all(is_int(x) and 0 <= x <= 255 for x in lst):
            return bytes(lst), None
        return None, '%s has a "bytes" list that is not a list of integers 0 to 255' % who
    return None, "%s must be a JSON string, got %s" % (who, kind_of(v))


class Val:
    """A text-like value as the generated code uses it: the expression, how it is documented, and what it needs."""

    def __init__(self, expr, doc, local=None, drop=None, borrow=None):
        self.expr, self.doc, self.local, self.drop, self.borrow = expr, doc, local, drop, borrow


def hexs(b):
    return "".join("%02x" % x for x in b)


def text_val(v, who, name, feats, static=False):
    """A text for an argument or a want: (Val, None) or (None, message). `name` is the local's name if one is needed."""
    b, m = text_bytes(v, who)
    if m is not None:
        return None, m
    lit = text_lit(b)
    if lit is not None:
        return Val(lit, lit), None
    if static:
        return None, "%s cannot be written in a cancho string literal and the parameter is &static; use another input" % who
    feats.add("unhex")
    return Val("contents(r%s)" % name, None, "let %s = cases_{s}_unhex(heap, \"%s\");" % (name, hexs(b)),
               "unbox_slice(heap, %s);" % name, name), None


def list_val(v, who, name, feats, vec=False):
    if not isinstance(v, list):
        return None, "%s must be a JSON list of strings, got %s" % (who, kind_of(v))
    items = []
    for i, x in enumerate(v, 1):
        b, m = text_bytes(x, "%s item %d" % (who, i))
        if m is not None:
            return None, m
        lit = text_lit(b)
        if vec and lit is None:
            return None, "%s item %d cannot be written in a cancho string literal (a vec holds literals); use another input" % (who, i)
        items.append((b, lit))
    docs = None if any(lit is None for _, lit in items) else "[" + ", ".join(lit for _, lit in items) + "]"
    if vec:
        local = "var %s = vec.empty(heap, %d, \"\");" % (name, len(items) + 1)
        for _, lit in items:
            local += " %s = vec.push(heap, %s, %s);" % (name, name, lit)
        return Val("r" + name, docs, local, "vec.drop(heap, %s);" % name, name), None
    feats.add("ldrop")
    local = "var %s: list.List[Box[Box[[byte]]]] = list.List::Empty;" % name
    for b, lit in reversed(items):
        if lit is not None:
            feats.add("mk")
            elem = "cases_{s}_mk(heap, %s)" % lit
        else:
            feats.add("unhex")
            elem = "cases_{s}_unhex(heap, \"%s\")" % hexs(b)
        local += " %s = list.push(heap, %s, box(heap, %s));" % (name, name, elem)
    return Val("r" + name, docs, local, "cases_{s}_ldrop(heap, %s);" % name, name), None


# ---- helper generation ----------------------------------------------------------------

SUP_SAME = ("fn cases_{s}_same[&a, &b](x: &a [byte], y: &b [byte]) -> [] bool { if len(x) != len(y) { return false; } var i = 0; "
            "while i < len(x) { if int_of(x[i]) != int_of(y[i]) { return false; } i = i + 1; } return true; }")
SUP_MK = ("fn cases_{s}_mk[&h, &r](heap: &!h Heap, s: &r [byte]) -> [heap] Box[[byte]] { let b = box_slice(heap, len(s), byte_of(0)); "
          "borrow mut b as &!w in { copy_into(contents(w), s); } return b; }")
SUP_HEXV = "fn cases_{s}_hexv(c: int) -> [] int { if c >= 97 { return c - 87; } return c - 48; }"
SUP_UNHEX = ("fn cases_{s}_unhex[&h, &r](heap: &!h Heap, hex: &r [byte]) -> [heap] Box[[byte]] { let n = len(hex) / 2; "
             "let b = box_slice(heap, n, byte_of(0)); borrow mut b as &!w in { let s = contents(w); var i = 0; while i < n { "
             "s[i] = byte_of(cases_{s}_hexv(int_of(hex[2 * i])) * 16 + cases_{s}_hexv(int_of(hex[2 * i + 1]))); i = i + 1; } } return b; }")
SUP_LDROP = ("fn cases_{s}_ldrop[&h](heap: &!h Heap, l: list.List[Box[Box[[byte]]]]) -> [heap] int { match l { list.List::Empty => { return 0; } "
             "list.List::Cons(f, rest) => { unbox_slice(heap, unbox(heap, f)); let tail = unbox(heap, rest); return 1 + cases_{s}_ldrop(heap, tail); } } }")
SUP_NTH = ("fn cases_{s}_nth[&l](l: &l list.List[Box[Box[[byte]]]], i: int) -> [] &l [byte] { match l { list.List::Empty => { return \"\"; } "
           "list.List::Cons(f, rest) => { if i == 0 { return contents(contents(f)); } return cases_{s}_nth(contents(rest), i - 1); } } }")
SUP_LEQ = ("fn cases_{s}_leq[&a, &b](x: &a list.List[Box[Box[[byte]]]], y: &b list.List[Box[Box[[byte]]]]) -> [] bool { "
           "if list.length(x) != list.length(y) { return false; } var i = 0; while i < list.length(x) { "
           "if !cases_{s}_same(cases_{s}_nth(x, i), cases_{s}_nth(y, i)) { return false; } i = i + 1; } return true; }")


def cmp_stmt(var, v):
    if v in (V_INT, V_BOOL):
        return "if %s == want { return 0; } return 1;" % var
    if v == V_TEXT:
        return "if cases_{s}_same(%s, want) { return 0; } return 1;" % var
    if v == V_BUF:
        body, drop = "cases_{s}_same(buffer.bytes(x), want)", "buffer.drop(heap, %s);" % var
    elif v == V_BOX:
        body, drop = "cases_{s}_same(contents(x), want)", "unbox_slice(heap, %s);" % var
    else:
        body, drop = "cases_{s}_leq(x, want)", "cases_{s}_ldrop(heap, %s);" % var
    return "var same = false; borrow %s as &x in { same = %s; } %s if same { return 0; } return 1;" % (var, body, drop)


def drop_stmt(var, v):
    if v == V_BUF:
        return "buffer.drop(heap, %s);" % var
    if v == V_BOX:
        return "unbox_slice(heap, %s);" % var
    if v == V_LIST:
        return "cases_{s}_ldrop(heap, %s);" % var
    return ""


def some_arm(v, code):
    d = drop_stmt("v", v)
    if d:
        return "option.Option::Some(v) => { %s return %d; }" % (d, code)
    return "option.Option::Some(_) => { return %d; }" % code


def err_arm(e, code):
    if e == 2:
        return "result.Result::Err(e) => { buffer.drop(heap, e); return %d; }" % code
    return "result.Result::Err(_) => { return %d; }" % code


def ok_drop_arm(v, topt, code):
    if topt:
        return "result.Result::Ok(o) => { match o { %s option.Option::None => { return %d; } } }" % (some_arm(v, code), code)
    d = drop_stmt("v", v)
    if d:
        return "result.Result::Ok(v) => { %s return %d; }" % (d, code)
    return "result.Result::Ok(_) => { return %d; }" % code


HELPERS = ["is", "some", "none", "ok", "err", "errn", "oksome", "oknone"]


def build_helper(which, sid, name, params, hasheap, ret, wantinfo):
    """One helper item. params: list of (kind, is_static); wantinfo: the type of `want` (a string) or None."""
    outer, v, e, topt = ret
    regions = ["&h"] if hasheap else []
    plist = []
    clist = []
    n = 0
    for kind, static in params:
        if kind == P_HEAP:
            plist.append("heap: &!h Heap")
            clist.append("heap")
            continue
        n += 1
        clist.append("a%d" % n)
        if kind == P_INT:
            plist.append("a%d: int" % n)
        elif kind == P_BOOL:
            plist.append("a%d: bool" % n)
        elif kind == P_TEXT:
            if static:
                plist.append("a%d: &static [byte]" % n)
            else:
                regions.append("&t%d" % n)
                plist.append("a%d: &t%d [byte]" % (n, n))
        elif kind == P_LIST:
            regions.append("&l%d" % n)
            plist.append("a%d: &l%d list.List[Box[Box[[byte]]]]" % (n, n))
        else:
            regions.append("&v%d" % n)
            regions.append("&e%d" % n)
            plist.append("a%d: &v%d vec.Vec[&e%d [byte]]" % (n, n, n))
    if wantinfo is not None:
        if wantinfo == "text":
            regions.append("&w")
            plist.append("want: &w [byte]")
        elif wantinfo == "list":
            regions.append("&w")
            plist.append("want: &w list.List[Box[Box[[byte]]]]")
        else:
            plist.append("want: %s" % wantinfo)
    head = "fn cases_%s_%s%s(%s) -> %s int" % (sid, which, "[%s]" % ", ".join(regions) if regions else "", ", ".join(plist),
                                              "[heap]" if hasheap else "[]")
    call = "%s(%s)" % (name, ", ".join(clist))
    if which == "is":
        body = "let got = %s; %s" % (call, cmp_stmt("got", v))
    elif which == "some":
        body = "match %s { option.Option::Some(v) => { %s } option.Option::None => { return 2; } }" % (call, cmp_stmt("v", v))
    elif which == "none":
        body = "match %s { %s option.Option::None => { return 0; } }" % (call, some_arm(v, 2))
    elif which == "ok":
        body = "match %s { result.Result::Ok(v) => { %s } %s }" % (call, cmp_stmt("v", v), err_arm(e, 2))
    elif which == "err":
        body = "match %s { %s %s }" % (call, ok_drop_arm(v, topt, 2), err_arm(e, 0))
    elif which == "errn":
        body = "match %s { %s result.Result::Err(n) => { if n == want { return 0; } return 3; } }" % (call, ok_drop_arm(v, topt, 2))
    elif which == "oksome":
        body = ("match %s { result.Result::Ok(o) => { match o { option.Option::Some(v) => { %s } option.Option::None => { return 3; } } } %s }"
                % (call, cmp_stmt("v", v), err_arm(e, 2)))
    else:
        body = ("match %s { result.Result::Ok(o) => { match o { %s option.Option::None => { return 0; } } } %s }"
                % (call, some_arm(v, 1), err_arm(e, 2)))
    return ("%s { %s }" % (head, body)).replace("{s}", sid)


def want_type(ret, which):
    outer, v, e, topt = ret
    if which in ("none", "err", "oknone"):
        return None
    if which == "errn":
        return "int"
    return {V_INT: "int", V_BOOL: "bool", V_BUF: "text", V_TEXT: "text", V_BOX: "text", V_LIST: "list"}[v]


def build_support(sid, ret, feats):
    outer, v, e, topt = ret
    items = []
    if v in (V_BUF, V_TEXT, V_LIST, V_BOX):
        items.append(SUP_SAME)
    if "mk" in feats:
        items.append(SUP_MK)
    if "unhex" in feats:
        items.append(SUP_HEXV)
        items.append(SUP_UNHEX)
    if "ldrop" in feats or v == V_LIST:
        items.append(SUP_LDROP)
    if v == V_LIST:
        items.append(SUP_NTH)
        items.append(SUP_LEQ)
    return [s.replace("{s}", sid) for s in items]


# ---- one unit -------------------------------------------------------------------------

def expect_shape(ret, expect, feats):
    """(helper or None, want Val/literal or None, want type, doc) or (None, message)."""
    outer, v, e, topt = ret

    def want_of(vk, val, who):
        if vk in (V_INT, V_BOOL):
            lc, m = scalar_lit("int" if vk == V_INT else "bool", val, who)
            return (Val(lc, lc), None) if m is None else (None, m)
        if vk == V_LIST:
            return list_val(val, who, "w", feats)
        return text_val(val, who, "w", feats)

    if outer == 0:
        r, m = want_of(v, expect, "expect")
        if r is None:
            return None, m
        return (None if v in (V_INT, V_BOOL) else "is"), r, r.doc
    if outer == 1:
        if expect is None:
            return "none", None, "option.Option::None"
        r, m = want_of(v, expect, "expect")
        if r is None:
            return None, m
        return "some", r, None if r.doc is None else "option.Option::Some(%s)" % r.doc
    if not (isinstance(expect, dict) and len(expect) == 1 and ("ok" in expect or "err" in expect)):
        return None, 'expect for a Result must be {"ok": value} or {"err": anything}'
    if "err" in expect:
        x = expect["err"]
        if e == 1 and is_int(x):
            lc, m = scalar_lit("int", x, 'expect "err"')
            if m is not None:
                return None, m
            return "errn", Val(lc, lc), "result.Result::Err(%s)" % lc
        return "err", None, "result.Result::Err"
    x = expect["ok"]
    if topt:
        if x is None:
            return "oknone", None, "result.Result::Ok(option.Option::None)"
        r, m = want_of(v, x, 'expect "ok"')
        if r is None:
            return None, m
        return "oksome", r, None if r.doc is None else "result.Result::Ok(option.Option::Some(%s))" % r.doc
    r, m = want_of(v, x, 'expect "ok"')
    if r is None:
        return None, m
    return "ok", r, None if r.doc is None else "result.Result::Ok(%s)" % r.doc


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
    params = []
    heaps = 0
    for t in ptexts:
        c = classify_param(t)
        if c is not None and c[0] == P_HEAP:
            heaps += 1
            if heaps > 1:
                c = None
        if c is None:
            err("-", "signature uses a type that cases cannot express (%s); give tests instead" % t)
            return None
        params.append(c)
    ret = classify_ret(rtext)
    if ret[0] is None:
        err("-", "signature uses a type that cases cannot express (%s); give tests instead" % ret[1])
        return None
    outer, rv, re_, topt = ret
    has_heap = any(k == P_HEAP for k, _ in params)
    if (rv in (V_BUF, V_LIST, V_BOX) or re_ == 2) and not has_heap:
        err("-", "the function returns a buffer.Buffer but takes no heap parameter; give tests instead")
        return None
    sid = sid_of(who)
    argparams = [p for p in params if p[0] != P_HEAP]

    problems = len(report)
    items = []
    examples = []
    used = []
    feats = set()
    for k, case in enumerate(cases, 1):
        if not (isinstance(case, dict) and isinstance(case.get("args"), list) and "expect" in case):
            err(k, 'a case must be an object with "args" (a list) and "expect"')
            continue
        args, expect = case["args"], case["expect"]
        if len(args) != len(argparams):
            err(k, "args has %d value(s) but the function takes %d (the heap is not given in args)" % (len(args), len(argparams)))
            continue
        vals = []
        bad = False
        for i, (a, (kind, static)) in enumerate(zip(args, argparams), 1):
            wh = "argument %d" % i
            if kind in (P_INT, P_BOOL):
                lc, m = scalar_lit(kind, a, wh)
                val = Val(lc, lc) if m is None else None
            elif kind == P_TEXT:
                val, m = text_val(a, wh, "a%d" % i, feats, static)
            else:
                val, m = list_val(a, wh, "a%d" % i, feats, vec=(kind == P_VEC))
            if m is not None:
                err(k, m)
                bad = True
                break
            vals.append(val)
        if bad:
            continue
        ci = 0
        call_args = []
        call_docs = []
        for kind, _ in params:
            if kind == P_HEAP:
                call_args.append("heap")
                call_docs.append("heap")
            else:
                call_args.append(vals[ci].expr)
                call_docs.append(vals[ci].doc)
                ci += 1
        shape = expect_shape(ret, expect, feats)
        if shape[0] is None and (len(shape) == 2):
            err(k, shape[1])
            continue
        helper, want, doc = shape
        # the pieces that need locals
        locals_ = [x for x in vals + ([want] if want is not None else []) if x.local]
        hdr = "pub fn test_%s_%d" % (sid, k)
        if want is not None:
            wexpr = want.expr
        else:
            wexpr = None
        if helper is None:
            stmt = "if %s(%s) == %s { code = 0; }" % (name, ", ".join(call_args), wexpr)
        else:
            hargs = list(call_args)
            if wexpr is not None:
                hargs.append(wexpr)
            stmt = "code = cases_%s_%s(%s);" % (sid, helper, ", ".join(hargs))
            if helper not in used:
                used.append(helper)
        if locals_:
            body = ("".join(x.local + " " for x in locals_) + "var code = 1; " +
                    "".join("borrow %s as &r%s in { " % (x.borrow, x.borrow) for x in locals_) + stmt + " " +
                    "".join("} " for _ in locals_) + "".join(x.drop + " " for x in locals_) + "return code;")
            items.append("fn cases_%s_c%d[&h](heap: &!h Heap) -> [heap] int { %s }".replace("{s}", sid) % (sid, k, body.replace("{s}", sid)))
            items.append("%s[&h](heap: &!h Heap) -> [heap] int { test.assert_eq(cases_%s_c%d(heap), 0); return 0; }" % (hdr, sid, k))
        else:
            h2 = "%s[&h](heap: &!h Heap) -> [heap] int" % hdr if has_heap else "%s() -> [] int" % hdr
            if helper is None:
                inner = "test.assert(%s(%s) == %s); return 0;" % (name, ", ".join(call_args), wexpr)
            else:
                inner = "test.assert_eq(%s, 0); return 0;" % stmt[len("code = "):-1]
            items.append("%s { %s }" % (h2, inner))
        if doc is not None and all(d is not None for d in call_docs):
            ctext = "%s(%s)" % (name, ", ".join(call_docs))
            line = "%s == %s" % (ctext, doc)
            if " == " not in ctext and "|| true" not in line and "or true" not in line:
                examples.append(line)
    if len(report) > problems:
        return None
    sup = build_support(sid, ret, feats)
    helpers = [build_helper(h, sid, name, params, has_heap, ret,
                            want_type(ret, h)) for h in HELPERS if h in used]
    new_tests = sup + helpers + items
    ex = unit.get("examples")
    fill = "examples" not in unit or (isinstance(ex, list) and len(ex) == 0)
    if fill and not examples:
        err("-", 'no case can be shown as an example (its call text contains " == " or a byte string); add a case without it, or give examples')
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
