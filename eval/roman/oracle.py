#!/usr/bin/env python3
"""Hidden cases for `roman`. Independent of the cancho reference: digit-table encoder + canonical regex decoder,
cross-checked against each other (every one of the 3999 encodings matches the regex and nothing else short does) and
against hand-computed values below."""
import itertools, json, re
ONES = ["", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX"]
TENS = ["", "X", "XX", "XXX", "XL", "L", "LX", "LXX", "LXXX", "XC"]
HUND = ["", "C", "CC", "CCC", "CD", "D", "DC", "DCC", "DCCC", "CM"]
THOU = ["", "M", "MM", "MMM"]
def enc(n):
    if not 1 <= n <= 3999: return None
    return THOU[n // 1000] + HUND[n // 100 % 10] + TENS[n // 10 % 10] + ONES[n % 10]
CANON = re.compile(r"M{0,3}(?:CM|CD|D?C{0,3})(?:XC|XL|L?X{0,3})(?:IX|IV|V?I{0,3})")
def dec(s):
    m = re.fullmatch(r"(M{0,3})(CM|CD|D?C{0,3})(XC|XL|L?X{0,3})(IX|IV|V?I{0,3})", s)
    if not s or not m: return None
    return 1000 * len(m[1]) + 100 * HUND.index(m[2]) + 10 * TENS.index(m[3]) + ONES.index(m[4])
# hand-computed anchors (from the numeral's meaning, not from enc)
HAND = {1: "I", 4: "IV", 9: "IX", 14: "XIV", 40: "XL", 49: "XLIX", 90: "XC", 400: "CD", 444: "CDXLIV", 900: "CM",
        1994: "MCMXCIV", 2024: "MMXXIV", 3999: "MMMCMXCIX", 3888: "MMMDCCCLXXXVIII", 1666: "MDCLXVI", 58: "LVIII"}
for k, s in HAND.items(): assert enc(k) == s, (k, s)
ALL = {enc(k): k for k in range(1, 4000)}
assert len(ALL) == 3999
# the regex accepts exactly the encodings (all strings over IVXLCDM up to length 4, plus every encoding)
for L in range(1, 5):
    for t in itertools.product("IVXLCDM", repeat=L):
        s = "".join(t)
        assert (CANON.fullmatch(s) is not None) == (s in ALL), s
for s, k in ALL.items(): assert CANON.fullmatch(s) and dec(s) == k, s
def Ok(x): return {"$variant": "Ok", "args": [x]}
N_ENC = sorted(set(list(range(1, 41)) + [49, 58, 90, 94, 99, 400, 444, 499, 500, 900, 944, 999, 1000, 1666, 1994, 2024, 2999, 3000, 3888, 3998, 3999]
                   + list(range(41, 3999, 37)) + list(range(7, 3999, 211))))
N_BAD = [0, -1, -3999, 4000, 4001, 5000, 99999]
INVALID = ["", " ", "IIII", "VV", "VX", "IC", "IL", "XM", "VIV", "IIV", "XXXX", "LL", "DD", "CCCC", "MMMM", "MMMMM", "IVI", "IXI", "IXX", "CMC", "CDC", "XCX", "XLX", "LXL", "DCD",
           "VIIII", "IIX", "XIIX", "MCMC", "XCIX ", " XIV", "X IV", "iv", "mcmxciv", "Mcm", "XIv", "XIV\n", "A", "IVA", "0", "12", "MMXXIV1", "-IV", "+X", "N", "IIIII",
           "CMM", "MDM", "DM", "LC", "VL", "VC", "IM", "ID", "XD", "XXC", "CCM", "VIX", "MMMCMXCIXI", "Ⅰ", "X\u0000"]
for b in INVALID: assert dec(b) is None, b
GOOD = [enc(n) for n in N_ENC]
def main():
    for n in N_ENC: print(json.dumps({"fn": "to_roman", "args": [n], "expect": Ok(enc(n))}))
    for n in N_BAD: print(json.dumps({"fn": "to_roman", "args": [n], "expect_err": True}))
    for s in GOOD: print(json.dumps({"fn": "from_roman", "args": [s], "expect": Ok(dec(s))}))
    for b in INVALID: print(json.dumps({"fn": "from_roman", "args": [b], "expect_err": True}))
    print(json.dumps({"fn": "roundtrip", "args": [], "expect": Ok(3999)}))
main()
