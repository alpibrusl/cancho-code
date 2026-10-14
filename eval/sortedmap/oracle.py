#!/usr/bin/env python3
"""Hidden oracle for `sortedmap`. Prints one JSON line per sequence:
  {"seq": i, "cap": c, "ops": [op, ...]}
Each op carries the state BEFORE it (keys/vals lists of length n, ascending keys) and the observable result:
  insert  {op, key, value, keys, vals, ret, keys_after, vals_after}     ret = new count or -1 (full, key absent)
  remove  {op, key, keys, vals, ret, keys_after, vals_after}
  get     {op, key, keys, vals, found, value}
  lower_bound {op, key, keys, vals, ret}
  count   {op, lo, hi, keys, vals, ret}
The audit resets the arrays to the pre-state before every op (entries at index >= n are garbage), so one wrong
function costs only its own group. Model: a Python dict (the truth) cross-checked at every step against the
two-parallel-sorted-lists + bisect implementation, and a handful of hand-computed asserts below."""
import json, random, bisect

class Model:
    def __init__(self, cap):
        self.cap = cap; self.d = {}
        self.k = []; self.v = []          # the bisect twin
    def state(self):
        return list(self.k), list(self.v)
    def check(self):
        items = sorted(self.d.items())
        assert [a for a, _ in items] == self.k and [b for _, b in items] == self.v, (items, self.k, self.v)
        assert len(self.k) <= self.cap
    def insert(self, key, value):
        if key not in self.d and len(self.d) >= self.cap:
            return -1
        i = bisect.bisect_left(self.k, key)
        if i < len(self.k) and self.k[i] == key: self.v[i] = value
        else: self.k.insert(i, key); self.v.insert(i, value)
        self.d[key] = value
        return len(self.k)
    def remove(self, key):
        self.d.pop(key, None)
        i = bisect.bisect_left(self.k, key)
        if i < len(self.k) and self.k[i] == key: del self.k[i]; del self.v[i]
        return len(self.k)
    def get(self, key):
        return (True, self.d[key]) if key in self.d else (False, 0)
    def lower_bound(self, key):
        return sum(1 for a in sorted(self.d) if a < key)          # independent of bisect
    def count(self, lo, hi):
        return sum(1 for a in self.d if lo <= a < hi)

def run(cap, script):
    m = Model(cap); ops = []
    for o in script:
        k, v = m.state(); op = {"op": o[0]}
        if o[0] == "insert":
            op.update(key=o[1], value=o[2], keys=k, vals=v, ret=m.insert(o[1], o[2]))
            op["keys_after"], op["vals_after"] = m.state()
        elif o[0] == "remove":
            op.update(key=o[1], keys=k, vals=v, ret=m.remove(o[1]))
            op["keys_after"], op["vals_after"] = m.state()
        elif o[0] == "get":
            f, val = m.get(o[1]); op.update(key=o[1], keys=k, vals=v, found=f, value=val)
        elif o[0] == "lower_bound":
            r = m.lower_bound(o[1]); assert r == bisect.bisect_left(m.k, o[1])
            op.update(key=o[1], keys=k, vals=v, ret=r)
        elif o[0] == "count":
            r = m.count(o[1], o[2]); op.update(lo=o[1], hi=o[2], keys=k, vals=v, ret=r)
        m.check(); ops.append(op)
    return {"cap": cap, "ops": ops}

BIG = 4611686018427387904
HUGE = 9223372036854775807
def probes(keys):
    out = []
    for q in keys: out += [("get", q), ("lower_bound", q), ("get", q + 1), ("lower_bound", q + 1)]
    return out

def hand():
    S = []
    # capacity 0: nothing fits, everything is absent
    S.append((0, [("insert", 5, 1), ("get", 5), ("lower_bound", 5), ("count", -10, 10), ("remove", 5), ("insert", 0, 0)]))
    # capacity 1
    S.append((1, [("get", 1), ("insert", 1, 10), ("insert", 1, 11), ("insert", 2, 20), ("get", 1), ("get", 2), ("lower_bound", 0),
                  ("lower_bound", 1), ("lower_bound", 2), ("count", 1, 2), ("count", 0, 1), ("remove", 2), ("remove", 1),
                  ("remove", 1), ("insert", 2, 20), ("get", 2), ("count", 0, 100)]))
    # fill to capacity out of order, overflow, replace while full, free a slot, reuse it
    S.append((4, [("insert", 30, 3), ("insert", 10, 1), ("insert", 40, 4), ("insert", 20, 2), ("insert", 25, 9), ("insert", 5, 9),
                  ("insert", 20, 22), ("insert", 10, 11), ("insert", 40, 44), ("insert", 30, 33), ("get", 20), ("get", 25),
                  ("remove", 25), ("remove", 20), ("insert", 25, 9), ("get", 25), ("get", 20), ("lower_bound", 25),
                  ("lower_bound", 26), ("lower_bound", 41), ("lower_bound", 0), ("count", 10, 40), ("count", 10, 41),
                  ("count", 11, 30), ("count", 30, 30), ("count", 40, 10)]))
    # remove from the front, middle, end, then to empty and refill
    S.append((5, [("insert", i, i * i) for i in (3, 1, 4, 5, 2)] + [("remove", 1), ("remove", 3), ("remove", 5), ("remove", 3),
                  ("get", 2), ("get", 4), ("get", 1), ("lower_bound", 3), ("count", 0, 10), ("remove", 2), ("remove", 4),
                  ("remove", 4), ("get", 2), ("lower_bound", 0), ("count", -5, 5)]
                 + [("insert", i, -i) for i in (9, 8, 7, 6, 5)] + [("insert", 4, 0), ("get", 7), ("count", 6, 9), ("count", 5, 10)]))
    # negative keys and values, zero, mixed signs
    S.append((6, [("insert", -5, -50), ("insert", 0, 0), ("insert", 5, 50), ("insert", -1, -10), ("insert", 1, 10), ("insert", -100, 7),
                  ("insert", 2, 2), ("get", -5), ("get", 0), ("get", -2), ("get", 7), ("lower_bound", -5), ("lower_bound", -4),
                  ("lower_bound", 0), ("lower_bound", 3), ("lower_bound", -101), ("lower_bound", 6),
                  ("count", -5, 0), ("count", -5, 1), ("count", -100, 6), ("count", 0, 0), ("count", -1, 0), ("count", 1, -1),
                  ("remove", 0), ("remove", -5), ("get", 0), ("count", -100, 6), ("insert", 0, 1), ("get", 0)]))
    # extreme magnitudes: comparisons must not subtract
    S.append((5, [("insert", HUGE, 1), ("insert", -HUGE, 2), ("insert", 0, 3), ("insert", BIG, 4), ("insert", -BIG, 5),
                  ("get", HUGE), ("get", -HUGE), ("get", BIG), ("get", -BIG), ("get", 1),
                  ("lower_bound", HUGE), ("lower_bound", -HUGE), ("lower_bound", BIG), ("lower_bound", -BIG + 1),
                  ("count", -HUGE, HUGE), ("count", -BIG, BIG), ("count", -BIG, BIG + 1), ("count", HUGE, -HUGE),
                  ("count", 0, HUGE), ("insert", 1, HUGE), ("remove", HUGE), ("remove", -HUGE), ("count", -HUGE, HUGE),
                  ("insert", 7, -HUGE), ("get", 7)]))
    # duplicate pressure: the same few keys over and over (a map, not a multiset)
    S.append((3, [("insert", 1, 1), ("insert", 1, 2), ("insert", 1, 3), ("get", 1), ("count", 0, 5), ("insert", 2, 20),
                  ("insert", 2, 21), ("count", 0, 5), ("remove", 1), ("remove", 1), ("count", 0, 5), ("get", 2), ("lower_bound", 1)]))
    # ascending and descending insertion with probes of every key and gap
    S.append((8, [("insert", i * 2, i) for i in range(8)] + probes([0, 4, 14]) + [("count", 0, 15), ("count", 1, 14), ("count", 3, 4), ("count", 4, 5)]))
    S.append((8, [("insert", 100 - i * 3, i) for i in range(8)] + probes([79, 100]) + [("insert", 50, 0), ("remove", 79), ("insert", 50, 0), ("count", 79, 101)]))
    return S

def rand_seq(seed, cap, keyspace, steps):
    r = random.Random(seed); lo_k = -keyspace // 3
    script = []
    for _ in range(steps):
        x = r.random(); key = r.randint(lo_k, keyspace)
        if x < 0.30: script.append(("insert", key, r.randint(-1000, 1000)))
        elif x < 0.45: script.append(("remove", key))
        elif x < 0.65: script.append(("get", key))
        elif x < 0.80: script.append(("lower_bound", key))
        else:
            a, b = r.randint(lo_k - 1, keyspace + 1), r.randint(lo_k - 1, keyspace + 1)
            script.append(("count", a, b))
    return script

def hand_asserts():
    # computed by hand from the contract, not from Model
    m = Model(2)
    assert m.insert(2, 20) == 1 and m.insert(1, 10) == 2 and m.insert(3, 30) == -1
    assert m.state() == ([1, 2], [10, 20]) and m.insert(2, 21) == 2 and m.state() == ([1, 2], [10, 21])
    assert m.remove(5) == 2 and m.remove(1) == 1 and m.state() == ([2], [21])
    assert m.lower_bound(2) == 0 and m.lower_bound(3) == 1 and m.count(2, 3) == 1 and m.count(3, 2) == 0 and m.get(1) == (False, 0)

def main():
    hand_asserts()
    seqs = [run(c, s) for c, s in hand()]
    # capacity pressure: tiny caps over a keyspace bigger than the cap; roomy caps over a smaller keyspace
    for seed in range(1, 7): seqs.append(run(3, rand_seq(seed, 3, 8, 30)))
    for seed in range(11, 17): seqs.append(run(8, rand_seq(seed, 8, 12, 45)))
    for seed in range(21, 25): seqs.append(run(16, rand_seq(seed, 16, 14, 60)))
    for i, s in enumerate(seqs):
        s["seq"] = i; print(json.dumps(s))
main()
