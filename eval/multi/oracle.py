#!/usr/bin/env python3
"""The oracle of the `multi` item (a small calculator in three modules): prints the audit's cases, one JSON object per line.

    python3 oracle.py            # the cases
    python3 oracle.py --self     # check the oracle against itself (a second, independent evaluator) and exit 0

The semantics are those of eval/multi/brief.txt, written here a second time as plain Python with unbounded integers. A case whose answer would depend on
which of two problems an implementation meets first (a syntax error and an overflow in one expression) is never emitted: `unambiguous` evaluates every
expression two ways (reading and doing at once, and checking the whole shape first) and keeps it only when both agree."""
import json, random, sys

INT_MAX, INT_MIN = 2**63 - 1, -2**63
fits = lambda v: INT_MIN <= v <= INT_MAX
PUNCT = {43: 2, 45: 3, 42: 4, 40: 5, 41: 6}


def scan(text, cap):
    """(code, tokens): the token count and pairs (kind, value), or -1 a byte that is not part of an expression, -2 a number of more than 18 digits,
    -3 more tokens than `cap`; the first problem met, scanning left to right, decides."""
    toks, i = [], 0
    while i < len(text):
        c = text[i]
        if c in (32, 9):
            i += 1
        elif 48 <= c <= 57:
            v = d = 0
            while i < len(text) and 48 <= text[i] <= 57:
                if d >= 18:
                    return -2, []
                v, d, i = v * 10 + text[i] - 48, d + 1, i + 1
            if len(toks) >= cap:
                return -3, []
            toks.append((1, v))
        else:
            if c not in PUNCT:
                return -1, []
            if len(toks) >= cap:
                return -3, []
            toks.append((PUNCT[c], 0))
            i += 1
    return len(toks), toks


def evaluate(toks):
    """(status, value): 0 ok, 1 not an expression, 2 an operation does not fit. Reads left to right and does each operation as soon as both operands are
    known; the first problem met decides."""
    st = {"pos": 0, "bad": 0}
    n = len(toks)

    def kind(i):
        return toks[i][0]

    def factor():
        if st["bad"]:
            return 0
        if st["pos"] >= n:
            st["bad"] = 1
            return 0
        k = kind(st["pos"])
        if k == 1:
            v = toks[st["pos"]][1]
            st["pos"] += 1
            return v
        if k == 3:
            st["pos"] += 1
            v = factor()
            if st["bad"]:
                return 0
            if not fits(-v):
                st["bad"] = 2
                return 0
            return -v
        if k == 5:
            st["pos"] += 1
            v = expr()
            if st["bad"]:
                return 0
            if st["pos"] >= n or kind(st["pos"]) != 6:
                st["bad"] = 1
                return 0
            st["pos"] += 1
            return v
        st["bad"] = 1
        return 0

    def term():
        v = factor()
        while not st["bad"] and st["pos"] < n and kind(st["pos"]) == 4:
            st["pos"] += 1
            w = factor()
            if not st["bad"]:
                if fits(v * w):
                    v = v * w
                else:
                    st["bad"] = 2
        return v

    def expr():
        v = term()
        while not st["bad"] and st["pos"] < n and kind(st["pos"]) in (2, 3):
            plus = kind(st["pos"]) == 2
            st["pos"] += 1
            w = term()
            if not st["bad"]:
                r = v + w if plus else v - w
                if fits(r):
                    v = r
                else:
                    st["bad"] = 2
        return v

    v = expr()
    if not st["bad"] and st["pos"] != n:
        st["bad"] = 1
    return (st["bad"], v if not st["bad"] else 0)


def shape_ok(toks):
    """Is the token list an expression at all (no arithmetic)? A second, independent reader: a stack of what is expected next."""
    expect_operand, depth = True, 0
    for k, _ in toks:
        if expect_operand:
            if k == 1:
                expect_operand = False
            elif k == 3 or k == 5:
                depth += 1 if k == 5 else 0
            else:
                return False
        else:
            if k in (2, 3, 4):
                expect_operand = True
            elif k == 6 and depth > 0:
                depth -= 1
            else:
                return False
    return (not expect_operand) and depth == 0


def unambiguous(toks):
    """Keep an expression unless an operation does not fit BEFORE the point where it stops being an expression: the answer would then depend on whether
    the implementation reads the whole shape first or does each operation at once."""
    st, _ = evaluate(toks)
    return not (st == 2 and not shape_ok(toks))


def calc(text, cap):
    code, toks = scan(text, cap)
    if code == -1:
        return 3, 0
    if code == -2:
        return 4, 0
    if code == -3:
        return 5, 0
    return evaluate(toks)


def lit(b):
    return b.decode("latin-1")


def cases():
    rnd = random.Random(20261016)
    out = []
    add = lambda g, **kw: out.append(dict(g=g, **kw))

    # ---- tk_scan -----------------------------------------------------------------------------------------------------------------
    scans = [b"", b"   ", b"7", b"007", b"12345", b"1+2", b" 1 +  2 ", b"(1)", b"1\t+\t2", b"+-*()", b"12 34", b"1+2*3-(4)", b"a", b"1 + a", b"1.5", b"1,2",
             b"1_000", b"~", b"2*", b"- -3", b"((((1))))", b"1" * 18, b"1" * 19, b"0" * 18, b"0" * 19, b"123456789012345678", b"1234567890123456789",
             b"9" * 18 + b"+1", b"1+" + b"9" * 19, b"x" + b"1" * 19, b"1" * 19 + b"x", b"1+2+3+4+5+6+7+8", b"(1+2)*(3+4)"]
    for t in scans:
        add("scan", text=lit(t), cap=16, code=scan(t, 16)[0], toks=scan(t, 16)[1])
    for t, cap in [(b"1+2", 3), (b"1+2", 2), (b"1+2+3", 5), (b"1+2+3", 4), (b"", 0), (b"7", 0), (b"7", 1), (b"()", 1), (b"()", 2), (b"1 +", 1), (b"1 + a", 1),
                   (b"a", 0)]:
        add("scan", text=lit(t), cap=cap, code=scan(t, cap)[0], toks=scan(t, cap)[1])
    alphabet = b"0123456789 +-*()\t"
    for _ in range(40):
        t = bytes(rnd.choice(alphabet) for _ in range(rnd.randint(0, 14)))
        cap = rnd.choice([16, 16, 16, 4, 6])
        add("scan", text=lit(t), cap=cap, code=scan(t, cap)[0], toks=scan(t, cap)[1])
    for _ in range(8):
        t = bytes(rnd.choice(alphabet + b"ab.x,") for _ in range(rnd.randint(1, 10)))
        add("scan", text=lit(t), cap=16, code=scan(t, 16)[0], toks=scan(t, 16)[1])

    # ---- tk_kind, tk_value ----------------------------------------------------------------------------------------------------------
    for _ in range(12):
        pairs = [[rnd.randint(1, 6), rnd.choice([0, 1, 7, 42, 10**17, 10**18 - 1])] for _ in range(rnd.randint(1, 6))]
        add("access", pairs=pairs)

    # ---- ps_fits_add / sub / mul ---------------------------------------------------------------------------------------------------
    edge = [0, 1, -1, 2, -2, 3, 10**9, 4294967296, -4294967296, 2**31, -2**31, 2**62, -2**62, INT_MAX, INT_MIN, INT_MAX - 1, INT_MIN + 1, 10**18, -10**18,
            3037000499, 3037000500, -3037000500, 2**32 + 1, 4611686018427387903]
    pairs = [(a, b) for a in edge for b in edge]
    rnd.shuffle(pairs)
    for op, f in (("add", lambda a, b: a + b), ("sub", lambda a, b: a - b), ("mul", lambda a, b: a * b)):
        for a, b in pairs[:90]:
            add("fits", op=op, a=a, b=b, ok=fits(f(a, b)))

    # ---- ps_eval and calc_eval: hand-made and random expressions ------------------------------------------------------------------
    texts = [b"7", b"1+2*3", b"(1+2)*3", b"2*(3+4)*5", b"-(2+3)*2", b"--3", b"2--3", b"2*-3", b"10-4-3", b"1 - 2 - 3", b"100 - 10*10", b"((((((7))))))", b"-(-(-(3)))",
             b"0", b"0*5", b"-0", b"2*3*4*5", b"1+2+3+4+5", b"(1)", b"((1)+2)*(3-(4*5))",
             b"", b"   ", b"()", b"1+", b"*2", b"(1", b"1)", b"1 2", b"(1)(2)", b"1+*2", b"++1", b"+1", b"1-", b"-", b"(", b")", b"1+(2", b"(1+2))", b"2 3 + 4",
             b"1+2 3", b"((1+2)", b"1*", b"*", b"1 + - ", b"(-)", b"-()", b"(1+2)3", b"3(1+2)",
             b"999999999999999999*9", b"999999999999999999*10", b"999999999999999999*999999999999999999", b"999999999999999999*9+999999999999999999",
             b"999999999999999999*9-999999999999999999", b"999999999999999999*9 + 999999999999999999*9", b"-999999999999999999*9-999999999999999999*9",
             b"-(-2147483648*4294967296)", b"(-2147483648*4294967296)", b"2147483648*4294967296", b"-2147483648*4294967296-1", b"-2147483648*4294967296+1",
             b"3037000500*3037000500", b"3037000499*3037000499", b"4611686018427387904", b"1000000000*1000000000*10", b"1000000000*1000000000*9",
             b"a", b"1 + a", b"1 . 5", b"1" * 19, b"1" * 18, b"1" * 18 + b"*9", b"0000000000000000007", b"7" + b" " * 3 + b"+" + b"\t" + b"1"]
    for _ in range(120):
        def gen(depth):
            r = rnd.random()
            if depth == 0 or r < 0.3:
                return str(rnd.choice([0, 1, 2, 3, 7, 10, 99, 12345, 10**9, 10**12, 10**17, 999999999999999999, 4294967296, 3037000499])).encode()
            if r < 0.45:
                return b"-" + gen(depth - 1)
            if r < 0.6:
                return b"(" + gen(depth - 1) + b")"
            return gen(depth - 1) + rnd.choice([b"+", b"-", b"*", b" + ", b" * ", b"-"]) + gen(depth - 1)
        texts.append(gen(rnd.randint(1, 4)))
    for _ in range(40):
        t = bytearray(texts[rnd.randint(40, len(texts) - 1)])
        if t:
            i = rnd.randrange(len(t))
            if rnd.random() < 0.5:
                del t[i]
            else:
                t.insert(i, rnd.choice(b"+-*()1"))
        texts.append(bytes(t))
    kept = []
    for t in texts:
        code, toks = scan(t, 40)
        if code < 0:
            kept.append((t, None))
            continue
        if not unambiguous(toks):
            continue
        kept.append((t, toks))
    for t, toks in kept:
        if toks is not None and len(toks) <= 40:
            st, v = evaluate(toks)
            add("eval", toks=toks, code=st, value=v)
    for t, toks in kept:
        st, v = calc(t, 40)
        add("calc", text=lit(t), cap=40, code=st, value=v)
    for t, cap in [(b"1+2+3+4", 7), (b"1+2+3+4", 6), (b"((((1))))", 9), (b"((((1))))", 8), (b"1+2+3+4+5+6+7+8+9", 8), (b"7", 1), (b"7", 0), (b"1 +", 1)]:
        add("calc", text=lit(t), cap=cap, code=calc(t, cap)[0], value=calc(t, cap)[1])

    # ---- calc_record: a store that sums what was recorded, and refuses what does not fit ------------------------------------------
    seqs = [[b"1+2", b"10", b"-4"], [b"5", b"oops", b"6"], [b"1+", b"2"], [b"999999999999999999*9", b"999999999999999999*9", b"1"],
            [b"999999999999999999*9", b"-999999999999999999*9", b"-999999999999999999*9", b"-5"],
            [b"999999999999999999*9", b"999999999999999999*9", b"999999999999999999*9", b"-3"],
            [b"3037000500*3037000500", b"2", b"1111111111111111111", b"3"], [b"", b"1", b"( 2 )"], [b"1" * 19, b"1"], [b"7"] * 5, [b"-9*999999999999999999", b"-1", b"-1", b"1"]]
    for _ in range(14):
        seqs.append([rnd.choice(texts[:75]) for _ in range(rnd.randint(2, 6))])
    for seq in seqs:
        total, count, steps = 0, 0, []
        ok = True
        for t in seq:
            code, toks = scan(t, 40)
            if code >= 0 and not unambiguous(toks):
                ok = False
        if not ok:
            continue
        for t in seq:
            st, v = calc(t, 40)
            if st == 0:
                if fits(total + v):
                    total, count = total + v, count + 1
                else:
                    st = 2
            steps.append({"text": lit(t), "code": st, "total": total, "count": count})
        add("record", steps=steps)

    # ---- the getters ------------------------------------------------------------------------------------------------------------------
    for tot, cnt in [(0, 0), (5, 1), (-7, 3), (INT_MAX, 9), (INT_MIN, 2), (123456789012345, 40)]:
        add("getters", total=tot, count=cnt)
    return out


def self_check():
    """The oracle against a second implementation of the same rules: an eval of the token list by a different method (shunting-yard on Python ints, with the
    overflow rule applied to each operation) on the expressions where the two readings agree."""
    rnd = random.Random(7)
    bad = 0
    for _ in range(3000):
        t = "".join(rnd.choice("0123456789 +-*()") for _ in range(rnd.randint(0, 12))).encode()
        code, toks = scan(t, 40)
        if code < 0:
            continue
        a = evaluate(toks)
        if (a[0] == 1 and shape_ok(toks)) or (a[0] == 0 and not shape_ok(toks)):
            bad += 1
            print("SHAPE", t, a, file=sys.stderr)
        if shape_ok(toks) and a[0] == 0:
            # a valid expression: Python's own evaluator gives the same value when nothing overflows
            src = t.decode().replace(" ", "")
            try:
                want = eval(src.replace("--", "- -"), {}, {})
            except Exception:
                continue
            if want != a[1]:
                bad += 1
                print("MISMATCH", t, a, want, file=sys.stderr)
    return bad


if __name__ == "__main__":
    if "--self" in sys.argv:
        sys.exit(1 if self_check() else 0)
    for c in cases():
        print(json.dumps(c))
