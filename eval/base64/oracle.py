#!/usr/bin/env python3
"""Hidden cases for `base64` (RFC 4648 section 4: standard alphabet, with padding, strict decode).

One JSON object per line:
    {"fn": "base64_encode", "data": "<hex>", "expect_text": "<ascii>"}
    {"fn": "base64_decode", "text": "<hex>", "expect": "<hex>"}            decode must be Ok(those bytes)
    {"fn": "base64_decode", "text": "<hex>", "expect_err": true, "why": <rule>}
    {"fn": "roundtrip",     "data": "<hex>"}                              decode(encode(data)) is Ok(data)

Expectations come from three places that must agree before a single line is printed:
  1. Python's base64 module (b64encode; b64decode(validate=True) plus the canonical re-encoding check, because the stdlib
     alone accepts non-zero trailing bits),
  2. an independent strictness predicate written from the RFC text (a regular expression over the padded forms with the
     trailing-bit characters spelled out by hand), checked exhaustively on every string up to length 6 over a small alphabet,
  3. the RFC 4648 section 10 vectors and a few hand-computed values, as literals."""
import base64, binascii, json, random, re, itertools

ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

# --- reference 1: the standard library, made strict -------------------------------------------------------------
def py_decode(t: bytes):
    try:
        d = base64.b64decode(t, validate=True)
    except (binascii.Error, ValueError):
        return None
    return d if base64.b64encode(d) == t else None      # canonical: rejects non-zero trailing bits

# --- reference 2: the RFC, by hand ------------------------------------------------------------------------------
# last quartet "xx==": second char must have its low 4 bits clear -> index % 16 == 0 -> A Q g w
# last quartet "xxx=": third char must have its low 2 bits clear   -> index % 4 == 0  -> A E I M Q U Y c g k o s w 0 4 8
assert [c for i, c in enumerate(ALPHA) if i % 16 == 0] == list("AQgw")
assert [c for i, c in enumerate(ALPHA) if i % 4 == 0] == list("AEIMQUYcgkosw048")
C = "[A-Za-z0-9+/]"
STRICT = re.compile(rb"(?:" + C.encode() + rb"{4})*(?:" + C.encode() + rb"[AQgw]==|" + C.encode() + rb"{2}[AEIMQUYcgkosw048]=)?\Z")
def re_ok(t: bytes) -> bool:
    return STRICT.match(t) is not None

def check_agree():
    # exhaustive, lengths 0..6, over characters that cover every class: data, trailing-bit-clear, trailing-bit-set, pad, url-safe, space
    for n in range(0, 7):
        for tup in itertools.product(b"AQ8h=-_ +", repeat=n):
            t = bytes(tup)
            assert (py_decode(t) is not None) == re_ok(t), t
    for n in (0, 4, 8):                                  # full-alphabet quartets in the last position
        for c in ALPHA + "=":
            for t in ("A" + c + "==", "AA" + c + "=", "AAA" + c, "AAAA" + "A" + c + "==", "AAAAAA" + c + "="):
                b = t.encode()
                assert (py_decode(b) is not None) == re_ok(b), b
    rng = random.Random(4648)
    for _ in range(20000):
        t = bytes(rng.choice(b"ABCDQg/+=0 \n") for _ in range(rng.randrange(0, 13)))
        assert (py_decode(t) is not None) == re_ok(t), t

def b2h(b: bytes) -> str: return b.hex()
def enc_case(d: bytes): return {"fn": "base64_encode", "data": b2h(d), "expect_text": base64.b64encode(d).decode()}
def dec_ok(t: bytes):
    d = py_decode(t); assert d is not None and re_ok(t), t
    return {"fn": "base64_decode", "text": b2h(t), "expect": b2h(d)}
def classify(t: bytes) -> str:
    """The first rule an invalid text breaks, checked in the order length, alphabet, padding, trailing bits (informational)."""
    if len(t) % 4: return "length"
    A = ALPHA.encode()
    if any(c not in A and c != 61 for c in t): return "alphabet"
    body = t.rstrip(b"=")
    if len(t) - len(body) > 2 or 61 in body: return "padding"
    return "trailing-bits"
def dec_err(t: bytes, why: str = ""):
    assert py_decode(t) is None and not re_ok(t), t
    return {"fn": "base64_decode", "text": b2h(t), "expect_err": True, "why": classify(t)}
def dec_any(t: bytes, why: str):                          # expectation decided by the two references (they agree)
    return dec_ok(t) if py_decode(t) is not None else dec_err(t, why)

def main():
    check_agree()
    out = []
    # RFC 4648 section 10 (hand-typed, not computed)
    RFC = [(b"", ""), (b"f", "Zg=="), (b"fo", "Zm8="), (b"foo", "Zm9v"), (b"foob", "Zm9vYg=="), (b"fooba", "Zm9vYmE="), (b"foobar", "Zm9vYmFy")]
    for d, e in RFC:
        assert base64.b64encode(d).decode() == e
        out.append(enc_case(d)); out.append(dec_ok(e.encode()))
    # hand-computed
    HAND = [(b"Man", "TWFu"), (b"Ma", "TWE="), (b"M", "TQ=="), (b"\xfb\xff", "+/8="), (b"\xff\xff\xff", "////"), (b"\x00", "AA=="),
            (b"\x00\x00\x00", "AAAA"), (b"\xfb", "+w=="), (b"\xff", "/w=="), (b"\xff\xfe", "//4="), (b"\x00\x10\x83", "ABCD")]
    for d, e in HAND:
        assert base64.b64encode(d).decode() == e, (d, e)
        out.append(enc_case(d)); out.append(dec_ok(e.encode()))
    # all lengths 0..8, two data patterns (encode, decode of the encoding, round trip)
    for pat in (bytes(range(1, 9)), bytes([255, 128, 127, 0, 254, 1, 250, 5])):
        for n in range(0, 9):
            d = pat[:n]
            out.append(enc_case(d)); out.append(dec_ok(base64.b64encode(d))); out.append({"fn": "roundtrip", "data": b2h(d)})
    # every byte value, long inputs (buffer growth), seeded random
    out.append(enc_case(bytes(range(256)))); out.append(dec_ok(base64.b64encode(bytes(range(256)))))
    out.append({"fn": "roundtrip", "data": b2h(bytes(range(256)))})
    rng = random.Random(1)
    for n in (11, 30, 31, 32, 33, 100, 255, 600):
        d = bytes(rng.randrange(256) for _ in range(n))
        out.append(enc_case(d)); out.append(dec_ok(base64.b64encode(d)))
        if n in (11, 33, 600): out.append({"fn": "roundtrip", "data": b2h(d)})
    # decode errors: wrong length
    for t in ("A", "AA", "AAA", "AAAAA", "AAAAAA", "AAAAAAA", "AAAA=", "Zg", "Zm8", "Zm9vYg", "Zm9vYmE", "Zg=", "Zm9vYmFyA"):
        out.append(dec_err(t.encode(), "length"))
    # characters outside the alphabet (url-safe, whitespace, controls, high bytes, punctuation)
    for t in (b"Zm9-", b"Zm9_", b"-_-_", b"Zm9v!A==", b"Zm9v YmFy", b" Zm9v", b"Zm9v ", b"Zm9v\n", b"Zm9vYmFy\n", b"Zm9v\r\nYmFy", b"Zm\t9",
              b"Zm9\x00", b"\x00m9v", b"Zm9\x80", b"Zm9\xff", b"\xc3\xa9m9v", b"Zm9*", b"Zm9.", b"Zm9,", b"Zm@v", b"Z[9v", b"Zm9`", b"Zm:v", b"Zm9v\x00",
              b"Zg==\n", b"Zg== ", b"Zg=\x00=", b"Zm9v\x7f", b"AA==\x00\x00\x00\x00"):
        out.append(dec_err(t, "alphabet"))
    # padding: misplaced, too much, missing, in the middle
    for t in (b"====", b"A===", b"=AAA", b"A=AA", b"AA=A", b"Zg=A", b"Zm9v====", b"Zg==Zg==", b"Zm8=Zm8=", b"Zm9vZg==Zg==", b"=Zm9", b"Z=m9",
              b"Zm=9", b"AAAA=AAA", b"AAAA====", b"AAA=AAAA", b"AA==AAAA", b"A=A=", b"=A=A", b"==AA", b"=A==", b"A==="):
        out.append(dec_err(t, "padding"))
    # non-zero trailing bits (the stdlib accepts all of these)
    for t in (b"Zh==", b"Zm9=", b"AB==", b"AP==", b"AAB=", b"AAC=", b"AAD=", b"Zh==", b"Zm9vYh==", b"Zm9vYmF=", b"/x==", b"//==", b"////", b"///="):
        if py_decode(t) is None:
            out.append(dec_err(t, "trailing-bits"))
    # ... and their neighbours that are fine: trailing bits clear
    for t in (b"AQ==", b"Zw==", b"AA==", b"AAE=", b"AAA=", b"Zm8=", b"//8=", b"/w==", b"Zg==", b"Zm9vYg==", b"Zm9vYmE="):
        out.append(dec_ok(t))
    # every possible second char before "==" and third char before "=": exactly 4 + 16 accepted
    for c in ALPHA:
        out.append(dec_any(("A" + c + "==").encode(), "trailing-bits"))
        out.append(dec_any(("AA" + c + "=").encode(), "trailing-bits"))
    # every length 0..8: unpadded, one pad, two pads
    for n in range(0, 9):
        for t in ("A" * n, "A" * (n - 1) + "=" if n >= 1 else "", "A" * (n - 2) + "==" if n >= 2 else "", "A" * (n - 1) + "-" if n >= 1 else "", "A" * n + "=="):
            out.append(dec_any(t.encode(), "length"))
    # decode never panics on a long pile of garbage; one valid long text
    out.append(dec_err(bytes(range(0, 256)), "alphabet"))
    out.append(dec_err(bytes(range(128, 256)) * 2, "alphabet"))
    big = bytes(rng.randrange(256) for _ in range(900))
    out.append(dec_ok(base64.b64encode(big)))
    seen = set(); n = 0
    for c in out:
        key = json.dumps(c, sort_keys=True)
        if key in seen: continue
        seen.add(key); print(key); n += 1

main()
