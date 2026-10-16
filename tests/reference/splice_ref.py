#!/usr/bin/env python3
"""Reference for src/splice.cho: the oracle of scripts/test-splice.sh. Everything works on bytes.

    splice_ref.py span REPLY               "START END" (byte offsets of the patch in the reply), or "-1 -1"
    splice_ref.py splice EXISTING PATCH    new file on stdout, report on stderr, exit 0 / 1

The edit mode (docs/plan.md): a model returns only the code a unit adds (a PATCH) and a program splices it into the project file.

TOP-LEVEL ITEMS. A text is parsed into items, separated by whitespace and by comments:
  edition N;   import PATH;   [pub] fn NAME ... { ... }   [pub] [res] struct NAME ... { ... } | ... ;   [pub] enum NAME ... { ... } | ... ;
A function name must be followed by `(` or `[`, a struct or enum name by `{`, `;` or `[` (else the text is not an item).
A function, struct or enum header runs to the first `{`, the item to its matching `}`; a struct or enum may instead end at a `;` that comes
first. The matcher skips string literals ("..." with backslash escapes, newlines allowed), char literals ('{', '\\'', '\\\\') and `//` comments.
Comment lines directly above an item (no blank line between) belong to it (the item starts at the first). Other comments are free trivia.
Anything else at top level is an error. An item that never closes (or a fn header that meets `;` before `{`) is an error.

IDENTITY: edition; `import PATH` (the text between `import` and `;`, trimmed); `fn NAME`; `type NAME` (struct and enum share it). `pub` does not count.

SPLICE: a patch item whose identity is in the file replaces the FIRST such item in place (its text, leading comments included, byte for byte);
an import already there is left alone; new imports go after the last import (else after the last header line, `edition N;` and `module NAME;`, else at the top), one per line, in
patch order; the patch's edition line (and its `module NAME;` line, which a file keeps as it is) is dropped; other new items are appended, each after one blank line; the result ends in exactly one "\\n"
(trailing whitespace trimmed first). Free comments and spacing of the file are untouched. Errors: nothing changes and the report says why.

PATCH SPAN: as reply.program_span (the longest fenced block, stray fences cut, `</think>`), then from the first line that begins with an item
keyword or `//` (and from which an item parses) to the end of the last item that closes (an item that never closes runs to the end).
"""
import re
import sys

KEYWORDS = [(b"pub res struct ", 3), (b"res struct ", 3), (b"pub struct ", 3), (b"struct ", 3), (b"pub enum ", 4), (b"enum ", 4),
            (b"pub fn ", 2), (b"fn ", 2), (b"import ", 1), (b"edition ", 0), (b"module ", 0)]
EDITION, IMPORT, FN, STRUCT, ENUM = range(5)
WORD = {FN: b"fn", STRUCT: b"struct", ENUM: b"enum"}
WS = b" \t\r\n"


def is_ident(c):
    return 48 <= c <= 57 or 65 <= c <= 90 or 97 <= c <= 122 or c == 95


def keyword_at(t, i):
    for kw, kind in KEYWORDS:
        if t.startswith(kw, i):
            return kind, len(kw)
    return -1, 0


def scan_body(t, i, semi_ends):
    """The end (exclusive) of the item whose header scan starts at i, or -1 when it never closes."""
    n = len(t)
    depth = 0
    opened = False
    while i < n:
        c = t[i]
        if c == 47 and i + 1 < n and t[i + 1] == 47:
            while i < n and t[i] != 10:
                i += 1
        elif c == 34:
            i += 1
            while i < n and t[i] != 34:
                i += 2 if t[i] == 92 else 1
            if i >= n:
                return -1
            i += 1
        elif c == 39:
            if i + 3 < n and t[i + 1] == 92 and t[i + 3] == 39:
                i += 4
            elif i + 2 < n and t[i + 1] != 92 and t[i + 1] != 10 and t[i + 2] == 39:
                i += 3
            else:
                i += 1
        elif c == 123:
            depth += 1
            opened = True
            i += 1
        elif c == 125:
            if depth > 0:
                depth -= 1
            i += 1
            if opened and depth == 0:
                return i
        elif c == 59 and not opened and depth == 0:
            return i + 1 if semi_ends else -1
        else:
            i += 1
    return -1


def parse_items(t):
    """(items, status, pos): items are dicts kind/start/end/ns/ne/kw; status 0 ok, 1 stray text at pos, 2 an item at pos never closes."""
    items = []
    n = len(t)
    i = 0
    while True:
        while i < n and t[i] in WS:
            i += 1
        if i >= n:
            return items, 0, 0
        start = i
        kwpos = i
        if t.startswith(b"//", i):
            j = i
            while True:
                eol = t.find(b"\n", j)
                eol = n if eol < 0 else eol
                if t[j:eol].lstrip(b" \t").startswith(b"//"):
                    j = eol + 1
                    if j >= n:
                        j = n
                        break
                else:
                    break
            k = j
            while k < n and t[k] in b" \t":
                k += 1
            if keyword_at(t, k)[0] < 0:
                i = j
                continue
            kwpos = k
        kind, klen = keyword_at(t, kwpos)
        if kind < 0:
            return items, 1, i
        q = kwpos + klen
        if kind == EDITION or kind == IMPORT:
            semi = t.find(b";", q)
            if semi < 0:
                return items, 2, kwpos
            if kind == IMPORT:
                a, b = q, semi
                while a < b and t[a] in WS:
                    a += 1
                while b > a and t[b - 1] in WS:
                    b -= 1
            else:
                a = b = q
            items.append(dict(kind=kind, start=start, end=semi + 1, ns=a, ne=b, kw=kwpos))
            i = semi + 1
            continue
        while q < n and t[q] == 32:
            q += 1
        ne = q
        while ne < n and is_ident(t[ne]):
            ne += 1
        if ne == q:
            return items, 1, i
        k = ne
        while k < n and t[k] in b" \t":
            k += 1
        if k >= n or t[k] not in (b"([" if kind == FN else b"{;["):
            return items, 1, i
        end = scan_body(t, ne, kind != FN)
        if end < 0:
            return items, 2, kwpos
        items.append(dict(kind=kind, start=start, end=end, ns=q, ne=ne, kw=kwpos))
        i = end


def tag(kind):
    return 3 if kind in (STRUCT, ENUM) else kind


def ident(t, it):
    return (tag(it["kind"]), t[it["ns"]:it["ne"]])


def line_of(t, pos):
    return t.count(b"\n", 0, pos) + 1


def first40(t, pos):
    eol = t.find(b"\n", pos)
    eol = len(t) if eol < 0 else eol
    return t[pos:eol].rstrip(b"\r")[:40]


def ident_text(t, it):
    k = tag(it["kind"])
    return {1: b"import ", 2: b"fn ", 3: b"type "}[k] + t[it["ns"]:it["ne"]]


def parse_errors(who, t, items, st, pos):
    if st == 1:
        return [b"%d:%s: text outside any item: %s" % (line_of(t, pos), who, first40(t, pos))]
    if st == 2:
        return [b"%d:%s: item never closes (unbalanced braces): %s" % (line_of(t, pos), who, first40(t, pos))]
    return []


def splice(existing, patch):
    """(new file, report lines (bytes), code)"""
    E, se, pe = parse_items(existing)
    P, sp, pp = parse_items(patch)
    errs = parse_errors(b"existing", existing, E, se, pe) + parse_errors(b"patch", patch, P, sp, pp)
    if sp == 0 and not P:
        errs.append(b"1:patch: no item (a fn, struct, enum, import or edition line)")
    if sp == 0:
        seen = {}
        for it in P:
            if it["kind"] == EDITION:
                continue
            key = ident(patch, it)
            if key in seen:
                errs.append(b"%d:patch: defines %s twice (first at line %d)" % (line_of(patch, it["kw"]), ident_text(patch, it), seen[key]))
            else:
                seen[key] = line_of(patch, it["kw"])
    if errs:
        return existing, [b"[SPLICE_ERROR]\t-\t" + e for e in errs], 1
    notes = []
    replace = {}      # existing item index -> patch item
    used = set()
    imports_have = {ident(existing, e)[1] for e in E if e["kind"] == IMPORT}
    new_imports, appended = [], []
    for k, it in enumerate(P):
        if it["kind"] == EDITION:
            notes.append(b"[SPLICE_NOTE]\tdropped edition")
        elif it["kind"] == IMPORT:
            if it_name(patch, it) in imports_have:
                notes.append(b"[SPLICE_NOTE]\tkept import " + it_name(patch, it))
            else:
                notes.append(b"[SPLICE_NOTE]\tadded import " + it_name(patch, it))
                new_imports.append(it)
        else:
            idx = next((e for e, x in enumerate(E) if ident(existing, x) == ident(patch, it)), -1)
            word = WORD[it["kind"]] + b" " + patch[it["ns"]:it["ne"]]
            if idx >= 0:
                notes.append(b"[SPLICE_NOTE]\treplaced " + word)
                replace[idx] = it
            else:
                notes.append(b"[SPLICE_NOTE]\tadded " + word)
                appended.append(it)
    anchor = -1
    for e, x in enumerate(E):
        if x["kind"] == IMPORT:
            anchor = e
    if anchor < 0:
        for e, x in enumerate(E):
            if x["kind"] == EDITION:
                anchor = e      # the last header line: `edition N;`, then `module NAME;` in a module file
    inserts = b"".join(b"\n" + patch[i["start"]:i["end"]] for i in new_imports)
    out = b""
    if anchor < 0 and new_imports:
        out = b"".join(patch[i["start"]:i["end"]] + b"\n" for i in new_imports) + b"\n"
    pos = 0
    for e, x in enumerate(E):
        if e in replace:
            it = replace[e]
            out += existing[pos:x["start"]] + patch[it["start"]:it["end"]]
        else:
            out += existing[pos:x["end"]]
        pos = x["end"]
        if e == anchor:
            out += inserts
    out += existing[pos:]
    out = out.rstrip(WS)
    for it in appended:
        out += (b"\n\n" if out else b"") + patch[it["start"]:it["end"]]
    return out + b"\n", notes, 0


def it_name(t, it):
    return t[it["ns"]:it["ne"]]


def normalise(text):
    """What splicing the file's items one at a time from its edition line gives: the edition line, the imports, then the other items, each
    after a blank line (free comments and spacing dropped)."""
    items, st, pos = parse_items(text)
    assert st == 0
    ed = [i for i in items if i["kind"] == EDITION][:1]
    out = b"".join(text[i["start"]:i["end"]] + b"\n" for i in ed)
    out += b"".join(text[i["start"]:i["end"]] + b"\n" for i in items if i["kind"] == IMPORT)
    for i in items:
        if i["kind"] not in (EDITION, IMPORT):
            out += (b"\n" if out else b"") + text[i["start"]:i["end"]] + b"\n"
    return out


# ---- the patch in a reply -------------------------------------------------------------------

ITEM_LINES = (b"fn ", b"pub fn ", b"struct ", b"pub struct ", b"res struct ", b"pub res struct ", b"enum ", b"pub enum ", b"import ", b"//", b"edition ", b"module ")


def is_space(c):
    return c == 32 or 9 <= c <= 13


def is_info(c):
    return 65 <= c <= 90 or 97 <= c <= 122 or 48 <= c <= 57 or c in (95, 43, 45)


def next_block(s, lo, hi, frm):
    p = frm
    while True:
        i = s.find(b"```", p, hi)
        if i < 0:
            return -1, 0, 0
        j = i + 3
        while j < hi and is_info(s[j]):
            j += 1
        while j < hi and s[j] in b" \t":
            j += 1
        if j < hi and s[j] == 10:
            close = s.find(b"```", j + 1, hi)
            if close >= 0:
                return j + 1, close, close + 3
        p = i + 1


def segment_patch(s, lo, hi):
    a, b = lo, hi
    best = -1
    frm = lo
    while True:
        cs, ce, resume = next_block(s, lo, hi, frm)
        if cs < 0:
            break
        if best < 0 or ce - cs > best:
            best, ba, bb = ce - cs, cs, ce
        frm = resume
    if best >= 0:
        a, b = ba, bb
    k = a
    while k < b and is_space(s[k]):
        k += 1
    if s.startswith(b"```", k) and k + 3 <= b:
        j = k + 3
        while j < b and is_info(s[j]):
            j += 1
        while j < b and s[j] in b" \t":
            j += 1
        if j < b and s[j] == 10:
            a = j + 1
    e = b
    while e > a and is_space(s[e - 1]):
        e -= 1
    if e - 3 >= a and s.startswith(b"```", e - 3):
        q = e - 3
        while q > a and s[q - 1] in b" \t":
            q -= 1
        if q > a and s[q - 1] == 10:
            b = q - 1
    i = a
    while i < b:
        at_line = i == a or s[i - 1] == 10
        if not at_line and i - 7 >= a and s.startswith(b"<think>", i - 7) and (i - 7 == a or s[i - 8] == 10):
            at_line = True
        if at_line and s.startswith(ITEM_LINES, i):
            items, st, pos = parse_items(s[i:b])
            if items or st == 2:
                if st == 2:
                    end = b
                    while end > i and s[end - 1] == 10:
                        end -= 1
                else:
                    end = i + items[-1]["end"]
                return i, end
        i += 1
    return -1, -1


def patch_span(s):
    hi = len(s)
    while True:
        t = s.rfind(b"</think>", 0, hi)
        if t < 0:
            return segment_patch(s, 0, hi)
        if s[t + 8:hi].strip(b" \t\n\v\f\r"):
            a, b = segment_patch(s, t + 8, hi)
            if a >= 0:
                return a, b
        hi = t


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "span":
        a, b = patch_span(open(sys.argv[2], "rb").read())
        sys.stdout.write("%d %d\n" % (a, b))
        return 0
    if len(sys.argv) == 4 and sys.argv[1] == "splice":
        new, report, code = splice(open(sys.argv[2], "rb").read(), open(sys.argv[3], "rb").read())
        sys.stdout.buffer.write(new)
        sys.stdout.flush()
        for line in report:
            sys.stderr.buffer.write(line + b"\n")
        return code
    sys.stderr.write("usage: splice_ref.py span REPLY | splice EXISTING PATCH\n")
    return 2


if __name__ == "__main__":
    sys.exit(main())
