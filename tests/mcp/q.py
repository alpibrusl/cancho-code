#!/usr/bin/env python3
"""q.py <response file> <line number> <expression>: evaluate a Python expression over line N of a response file, for the gate.
`r` is the response, `T` the JSON a tool put in its text (when it did), `lines` every response. Booleans print as true/false."""
import json, sys
lines = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
n = int(sys.argv[2])
r = lines[n - 1] if 0 < n <= len(lines) else None
T = None
try:
    T = json.loads(r["result"]["content"][0]["text"])
except Exception:
    pass
try:
    v = eval(sys.argv[3])
except Exception as e:
    v = "EXC:%s" % type(e).__name__
print(v if isinstance(v, str) else json.dumps(v))
