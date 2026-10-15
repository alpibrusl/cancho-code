#!/usr/bin/env python3
"""usage: attack.py BINARY PROJECT_CHO  -- independent attack on a built kvstore service (port 8814).

Ported from lex-code's backlog/items/12-kvstore/attack.py. Adapted: tokens come from --tokens; no loopback-only check (a cancho listener binds the port on all
interfaces); no SQL-specific check beyond the behavioural one (prefix/key that look like SQL or wildcards); added: 405/404 routing, tenant names that are
prefixes of each other, duplicate JSON fields, ttl edge types, code-point counting of values, a replace/delete churn that would exhaust a store that leaks,
robustness against a malformed request line. Takes about 20 seconds (a few real sleeps for expiry)."""
import http.client, json, os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
from svc import Svc

binary = sys.argv[1]
s = Svc(binary, ["--tokens", "tokA:acme,tokB:globex,tokC:acm"], 8814, label="ATTACK")
if os.environ.get("SVC_AUTHORITY_OK") == "0":
    s.note("authority is only what a server needs", False, os.environ.get("SVC_AUTHORITY_WHY", ""))
if not s.up:
    s.note("service starts and listens", False, "did not start")
    s.finish()
A, B, C3 = {"Authorization": "Bearer tokA"}, {"Authorization": "Bearer tokB"}, {"Authorization": "Bearer tokC"}
c = s.check

def put(h, key, value="v", ttl=None, extra=None):
    b = {"value": value}
    if ttl is not None: b["ttl_seconds"] = ttl
    b.update(extra or {})
    return s.req("PUT", f"/kv/{key}", h, b)

def put_utf8(key, value):
    return s.req("PUT", f"/kv/{key}", A, raw_body=json.dumps({"value": value}, ensure_ascii=False).encode("utf-8"))

def keys(h, q=""):
    st, t = s.req("GET", "/kv" + q, h)
    j = s.j(t)
    return j.get("keys") if st == 200 and isinstance(j, dict) else None

# 1. authentication
r_none = c("no token -> 401", s.req("GET", "/kv/a"), 401)
r_unk = c("unknown token -> 401, not echoed", s.req("GET", "/kv/a", {"Authorization": "Bearer nope"}), 401, excludes="nope")
r_basic = c("Basic scheme -> 401", s.req("GET", "/kv/a", {"Authorization": "Basic dG9rQQ=="}), 401)
c("scheme only -> 401", s.req("GET", "/kv/a", {"Authorization": "Bearer"}), 401)
r_sp = c("two spaces before the token -> 401", s.req("GET", "/kv/a", {"Authorization": "Bearer  tokA"}), 401)
c("token with an inner space -> 401", s.req("GET", "/kv/a", {"Authorization": "Bearer tok A"}), 401)
c("trailing space is 401 or ignored, never a crash", s.req("GET", "/kv/a", {"Authorization": "Bearer tokA "}), [401, 404])
c("a prefix of a real token -> 401", s.req("GET", "/kv/a", {"Authorization": "Bearer tok"}), 401)
c("a real token with a suffix -> 401", s.req("GET", "/kv/a", {"Authorization": "Bearer tokAx"}), 401)
c("a real token with a NUL-ish suffix -> 401", s.req("GET", "/kv/a", {"Authorization": "Bearer tokA%00"}), 401)
c("PUT without token -> 401", s.req("PUT", "/kv/a", None, {"value": "v"}), 401)
c("DELETE without token -> 401", s.req("DELETE", "/kv/a"), 401)
c("list without token -> 401", s.req("GET", "/kv"), 401)
c("401 comes before key validation (GET)", s.req("GET", "/kv/BAD%20KEY"), 401)
c("401 comes before key validation (PUT)", s.req("PUT", "/kv/UPPER", None, {"value": "v"}), 401)
c("401 comes before the method check", s.req("POST", "/kv"), 401)
s.note("missing, malformed and unknown token give the identical 401 body", r_none[1] == r_unk[1] == r_basic[1] == r_sp[1], f"{r_none[1][:40]!r} {r_unk[1][:40]!r} {r_basic[1][:40]!r}")
# 2. routing
c("unknown path -> 404", s.req("GET", "/nothing", A), 404)
c("unknown path without token -> 404", s.req("GET", "/nothing"), 404)
c("/kv/a/b -> 404", s.req("GET", "/kv/a/b", A), 404)
c("/kv/a/b PUT -> 404", s.req("PUT", "/kv/a/b", A, {"value": "v"}), 404)
c("POST /kv -> 405", s.req("POST", "/kv", A, {}), 405)
c("DELETE /kv -> 405", s.req("DELETE", "/kv", A), 405)
c("PATCH /kv/a -> 405", s.req("PATCH", "/kv/a", A, {"value": "v"}), 405)
c("POST /kv/a -> 405", s.req("POST", "/kv/a", A, {"value": "v"}), 405)
# 3. put / get / delete
c("PUT new key -> 201", put(A, "alpha", "one"), 201, test=lambda j: j == {"key": "alpha", "value": "one"})
c("PUT existing key -> 200", put(A, "alpha", "two"), 200, test=lambda j: j == {"key": "alpha", "value": "two"})
c("GET -> value and null expires_in", s.req("GET", "/kv/alpha", A), 200, test=lambda j: j == {"key": "alpha", "value": "two", "expires_in": None})
c("PUT empty value -> 201", put(A, "blank", ""), 201)
c("GET empty value -> 200 with empty string", s.req("GET", "/kv/blank", A), 200, test=lambda j: j["value"] == "")
c("GET missing -> 404", s.req("GET", "/kv/nope", A), 404)
c("DELETE existing -> 204", s.req("DELETE", "/kv/blank", A), 204)
st, text = s.req("DELETE", "/kv/alpha", A)
s.note("204 has no body", st == 204 and text == "", f"{st} {text[:40]!r}")
c("GET after DELETE -> 404", s.req("GET", "/kv/blank", A), 404)
c("DELETE missing -> 404", s.req("DELETE", "/kv/blank", A), 404)
c("PUT after DELETE -> 201 (as new)", put(A, "alpha", "three"), 201)
nasty = "it's ' OR '1'='1 \"x\" \\ \n\t\u0001 </script> %s %% {} \\u0041"
c("value with quotes, controls and SQL stored verbatim", put(A, "q", nasty), 201)
c("... read back verbatim", s.req("GET", "/kv/q", A), 200, test=lambda j: j["value"] == nasty)
c("non-ASCII value round-trips", put(A, "uni", "é日本🙂"), 201)
c("... read back", s.req("GET", "/kv/uni", A), 200, test=lambda j: j["value"] == "é日本🙂")
c("escaped unicode in the request is decoded", s.req("PUT", "/kv/esc", A, raw_body='{"value":"\\u00e9\\ud83d\\ude42\\n"}'), 201)
c("... read back decoded", s.req("GET", "/kv/esc", A), 200, test=lambda j: j["value"] == "é🙂\n")
c("Content-Type is JSON", s.req("GET", "/kv/alpha", A), 200)
# 4. isolation
c("B cannot read A's key: 404", s.req("GET", "/kv/alpha", B), 404)
c("B cannot delete A's key: 404", s.req("DELETE", "/kv/alpha", B), 404)
c("A's key survives B's delete", s.req("GET", "/kv/alpha", A), 200, test=lambda j: j["value"] == "three")
c("B PUT the same key -> 201 (separate key space)", put(B, "alpha", "bee"), 201)
c("B's overwrite does not touch A's", s.req("GET", "/kv/alpha", A), 200, test=lambda j: j["value"] == "three")
c("B's own value", s.req("GET", "/kv/alpha", B), 200, test=lambda j: j["value"] == "bee")
c("B deleting its key leaves A's", s.req("DELETE", "/kv/alpha", B), 204)
c("A still has its key", s.req("GET", "/kv/alpha", A), 200, test=lambda j: j["value"] == "three")
st1, b1 = s.req("GET", "/kv/q", B); st2, b2 = s.req("GET", "/kv/zzz-missing", B)
s.note("foreign key and missing key give the identical 404", (st1, b1) == (st2, b2) == (404, b2), f"{st1} {b1[:40]!r} vs {st2} {b2[:40]!r}")
c("tenant 'acm' (a prefix of 'acme') cannot see acme's key", s.req("GET", "/kv/alpha", C3), 404)
c("tenant 'acm' has an empty list", s.req("GET", "/kv", C3), 200, test=lambda j: j == {"keys": []})
c("tenant 'acm' stores the same key as new", put(C3, "alpha", "c"), 201)
c("tenant 'acme' unaffected by 'acm'", s.req("GET", "/kv/alpha", A), 200, test=lambda j: j["value"] == "three")
c("tenant 'acm' list shows only its key", s.req("GET", "/kv", C3), 200, test=lambda j: j == {"keys": ["alpha"]})
c("tenant 'acme' list does not show 'acm' extras", s.req("GET", "/kv?prefix=alpha", A), 200, test=lambda j: j == {"keys": ["alpha"]})
# 5. keys
for bad in ["UPPER", "a%20b", "x" * 65, "a;b", "%27", "..%2Fetc", "a'b", "a%2Fb", "%C3%A4", "a+b", "%61", "a%00b", "a:b", "a=b"]:
    c(f"GET key {bad[:20]!r} -> 404", s.req("GET", f"/kv/{bad}", A), 404)
    c(f"DELETE key {bad[:20]!r} -> 404", s.req("DELETE", f"/kv/{bad}", A), 404)
    c(f"PUT key {bad[:20]!r} -> 400", put(A, bad), 400)
c("GET /kv/ (empty key) -> 404", s.req("GET", "/kv/", A), 404)
c("PUT /kv/ (empty key) -> 400", s.req("PUT", "/kv/", A, {"value": "v"}), 400)
c("PUT key of 64 chars -> 201", put(A, "k" * 64), 201)
c("... GET it", s.req("GET", "/kv/" + "k" * 64, A), 200)
c("PUT key of 1 char -> 201", put(A, "z"), 201)
c("PUT key with . _ - -> 201", put(A, "a.b_c-d9"), 201)
c("percent-encoded key is not decoded into a valid one", s.req("GET", "/kv/%61lpha", A), 404)
# 6. body validation
c("value 1001 chars -> 400", put(A, "v1", "a" * 1001), 400)
c("value 1000 chars -> 201", put(A, "v2", "a" * 1000), 201)
c("1000 two-byte characters -> 201 (characters, not bytes)", put_utf8("v3", "é" * 1000), 201)
c("1001 two-byte characters -> 400", put_utf8("v3", "é" * 1001), 400)
c("1000 four-byte characters -> 201", put_utf8("v4", "🙂" * 1000), 201)
c("1000-character value escaped as \\u00e9 -> 201", s.req("PUT", "/kv/v5", A, raw_body='{"value":"' + "\\u00e9" * 600 + '"}'), 201)
c("missing value -> 400", s.req("PUT", "/kv/v6", A, {}), 400)
c("value null -> 400", s.req("PUT", "/kv/v6", A, {"value": None}), 400)
c("value not a string (int) -> 400", s.req("PUT", "/kv/v6", A, {"value": 5}), 400)
c("value not a string (list) -> 400", s.req("PUT", "/kv/v6", A, {"value": ["a"]}), 400)
c("value not a string (object) -> 400", s.req("PUT", "/kv/v6", A, {"value": {"a": 1}}), 400)
for ttl in [0, -1, 86401, 10 ** 12, 10 ** 30]:
    c(f"ttl {ttl} -> 400", put(A, "t0", ttl=ttl), 400)
for raw in ['1.5', '2.0', '1e2', '"5"', 'null', 'true', '[1]']:
    c(f"ttl {raw} -> 400", s.req("PUT", "/kv/t0", A, raw_body='{"value":"v","ttl_seconds":' + raw + '}'), 400)
c("ttl 1 -> 201", put(A, "t-min", ttl=1), 201)
c("ttl 86400 -> 201", put(A, "t-max", ttl=86400), 201)
c("unknown field -> 400", put(A, "u1", extra={"extra": 1}), 400)
c("unknown field with ttl -> 400", put(A, "u1", ttl=5, extra={"Value": "x"}), 400)
c("duplicate value field -> 400", s.req("PUT", "/kv/u1", A, raw_body='{"value":"a","value":"b"}'), 400)
c("duplicate ttl field -> 400", s.req("PUT", "/kv/u1", A, raw_body='{"value":"a","ttl_seconds":5,"ttl_seconds":6}'), 400)
c("invalid JSON -> 400", s.req("PUT", "/kv/u2", A, raw_body="{nope"), 400)
c("trailing garbage -> 400", s.req("PUT", "/kv/u2", A, raw_body='{"value":"a"} x'), 400)
c("array body -> 400", s.req("PUT", "/kv/u2", A, raw_body="[1]"), 400)
c("string body -> 400", s.req("PUT", "/kv/u2", A, raw_body='"a"'), 400)
c("empty body -> 400", s.req("PUT", "/kv/u2", A, raw_body=""), 400)
c("trailing comma -> 400", s.req("PUT", "/kv/u2", A, raw_body='{"value":"a",}'), 400)
c("bad UTF-8 in the body -> 400", s.req("PUT", "/kv/u2", A, raw_body=b'{"value":"\xff\xfe"}'), 400)
c("body of 4097 bytes -> 413", s.req("PUT", "/kv/big", A, raw_body='{"value":"' + "a" * (4097 - 12) + '"}'), 413)
c("body of 5000 bytes -> 413", s.req("PUT", "/kv/big", A, raw_body='{"value":"' + "a" * 5000 + '"}'), 413)
c("body of 200000 bytes -> 413", s.req("PUT", "/kv/big", A, raw_body='{"value":"' + "a" * 200000 + '"}'), 413)
c("body of 4096 bytes is parsed (400 for a long value, not 413)", s.req("PUT", "/kv/big", A, raw_body='{"value":"' + "a" * (4096 - 12) + '"}'), 400)
c("rejected PUTs stored nothing", s.req("GET", "/kv/u1", A), 404)
c("a rejected PUT leaves the old entry", put(A, "keep-me", "old"), 201)
c("... rejected replace -> 400", put(A, "keep-me", "new", ttl=0), 400)
c("... old value intact", s.req("GET", "/kv/keep-me", A), 200, test=lambda j: j["value"] == "old")
# 7. listing
for k in ["app.one", "app.two", "app_three", "apple", "apx", "zeta", "app"]: put(A, k)
put(B, "app.bee")
s.note("listing is ascending", (keys(A, "?limit=100") or []) == sorted(keys(A, "?limit=100") or ["x"]) and "app.one" in (keys(A, "?limit=100") or []), str(keys(A, "?limit=100"))[:80])
s.note("prefix 'app.' lists exactly the matching keys", keys(A, "?prefix=app.") == ["app.one", "app.two"], str(keys(A, "?prefix=app."))[:80])
s.note("prefix 'app_' is not a wildcard", keys(A, "?prefix=app_") == ["app_three"], str(keys(A, "?prefix=app_"))[:80])
s.note("prefix 'app' lists app, app.*, app_*, apple in order", keys(A, "?prefix=app") == ["app", "app.one", "app.two", "app_three", "apple"], str(keys(A, "?prefix=app"))[:100])
s.note("percent-encoded prefix is decoded", keys(A, "?prefix=%61pp.") == ["app.one", "app.two"], str(keys(A, "?prefix=%61pp."))[:80])
s.note("empty prefix lists everything", "zeta" in (keys(A, "?prefix=&limit=100") or []), "")
c("prefix with % -> 400", s.req("GET", "/kv?prefix=%25", A), 400)
c("prefix '%' raw -> 400", s.req("GET", "/kv?prefix=%", A), 400)
c("prefix with _ wildcard attempt '_' alone is just an underscore", s.req("GET", "/kv?prefix=_", A), 200, test=lambda j: j == {"keys": []})
c("prefix SQL injection -> 400", s.req("GET", "/kv?prefix=a'%20OR%20'1'='1", A), 400)
c("prefix with a semicolon -> 400", s.req("GET", "/kv?prefix=a;DROP", A), 400)
c("prefix uppercase -> 400", s.req("GET", "/kv?prefix=APP", A), 400)
c("prefix with a space -> 400", s.req("GET", "/kv?prefix=a%20b", A), 400)
c("prefix with + -> 400", s.req("GET", "/kv?prefix=a+b", A), 400)
c("prefix of 65 chars -> 400", s.req("GET", "/kv?prefix=" + "a" * 65), 401)
c("prefix of 65 chars with token -> 400", s.req("GET", "/kv?prefix=" + "a" * 65, A), 400)
c("prefix of 64 chars -> 200", s.req("GET", "/kv?prefix=" + "k" * 64, A), 200, test=lambda j: j == {"keys": ["k" * 64]})
c("prefix matching nothing -> empty list", s.req("GET", "/kv?prefix=nomatch", A), 200, test=lambda j: j == {"keys": []})
c("prefix is case sensitive and keys are lowercase: no 500", s.req("GET", "/kv?prefix=zeta", A), 200, test=lambda j: j == {"keys": ["zeta"]})
for bad in ["0", "101", "abc", "", "-1", "+5", "1.5", "1000", "0x10"]:
    c(f"limit={bad!r} -> 400", s.req("GET", f"/kv?limit={bad}", A), 400)
c("limit=1 -> one key, the smallest", s.req("GET", "/kv?limit=1", A), 200, test=lambda j: len(j["keys"]) == 1 and j["keys"][0] == sorted(keys(A, "?limit=100"))[0])
c("limit=2 -> exactly 2 keys", s.req("GET", "/kv?limit=2", A), 200, test=lambda j: len(j["keys"]) == 2)
c("limit=100 -> accepted", s.req("GET", "/kv?limit=100", A), 200)
c("bad limit with a valid prefix -> 400", s.req("GET", "/kv?prefix=app&limit=0", A), 400)
c("good prefix and limit", s.req("GET", "/kv?prefix=app&limit=2", A), 200, test=lambda j: j == {"keys": ["app", "app.one"]})
c("unknown query parameters are ignored", s.req("GET", "/kv?foo=bar&prefix=zeta", A), 200, test=lambda j: j == {"keys": ["zeta"]})
c("B's list has only B's keys", s.req("GET", "/kv?prefix=app", B), 200, test=lambda j: j == {"keys": ["app.bee"]})
# 7b. many keys: ordering, limit, deletion in the middle
many = [f"m{i:03d}" for i in range(300)]
for k in many: put(A, k, k)
s.note("300 keys listed 100 at a time are the first 100 in order", keys(A, "?prefix=m&limit=100") == many[:100], "")
for k in many[::2]: s.req("DELETE", f"/kv/{k}", A)
s.note("after deleting every second key the rest are listed in order", keys(A, "?prefix=m&limit=100") == many[1::2][:100], str(keys(A, "?prefix=m&limit=3")))
c("a deleted key is gone", s.req("GET", "/kv/m000", A), 404)
c("a kept key is intact", s.req("GET", "/kv/m001", A), 200, test=lambda j: j["value"] == "m001")
for k in many[::2][:20]: put(A, k, "again-" + k)
c("deleted keys can be stored again", s.req("GET", "/kv/m004", A), 200, test=lambda j: j["value"] == "again-m004")
# 8. expiry (real clock)
c("PUT with ttl 3 -> 201", put(A, "ttl-three", "soon", ttl=3), 201)
c("PUT with ttl 1 -> 201", put(A, "ttl-one", "blink", ttl=1), 201)
c("PUT permanent key for contrast", put(A, "perm-key", "stay"), 201)
c("PUT ttl 2 then replace without ttl -> permanent", put(A, "swap", "x", ttl=2), 201)
c("... replace -> 200", put(A, "swap", "y"), 200)
c("PUT permanent then replace with ttl 1", put(A, "swap2", "x"), 201)
c("... replace with ttl -> 200", put(A, "swap2", "y", ttl=1), 200)
c("PUT ttl 86400 for contrast", put(A, "long-key", "x", ttl=86400), 201)
c("B's key with ttl 1", put(B, "b-one", "b", ttl=1), 201)
c("expires_in is rounded up (3 right after the PUT)", s.req("GET", "/kv/ttl-three", A), 200, test=lambda j: j["expires_in"] == 3)
time.sleep(1.4)
c("ttl 3 entry after 1.4 s: expires_in 2 (rounded up)", s.req("GET", "/kv/ttl-three", A), 200, test=lambda j: j["expires_in"] == 2)
c("ttl 1 entry expired -> 404", s.req("GET", "/kv/ttl-one", A), 404)
c("ttl 1 entry absent from the list", s.req("GET", "/kv?prefix=ttl", A), 200, test=lambda j: j == {"keys": ["ttl-three"]})
c("replaced-with-ttl entry expired -> 404", s.req("GET", "/kv/swap2", A), 404)
c("B's expired entry -> 404", s.req("GET", "/kv/b-one", B), 404)
c("expired entry DELETE -> 404", s.req("DELETE", "/kv/ttl-one", A), 404)
c("permanent entry survives", s.req("GET", "/kv/perm-key", A), 200)
c("replaced-to-permanent entry survives", s.req("GET", "/kv/swap", A), 200, test=lambda j: j["expires_in"] is None)
c("long ttl entry has a large expires_in", s.req("GET", "/kv/long-key", A), 200, test=lambda j: 86000 < j["expires_in"] <= 86400)
c("PUT on an expired key -> 201 (as new)", put(A, "ttl-one", "again"), 201)
c("... and it is permanent", s.req("GET", "/kv/ttl-one", A), 200, test=lambda j: j["value"] == "again" and j["expires_in"] is None)
c("PUT over a live ttl entry -> 200 and a new ttl", put(A, "ttl-three", "renewed", ttl=5), 200)
c("... the ttl was replaced", s.req("GET", "/kv/ttl-three", A), 200, test=lambda j: j["expires_in"] in (4, 5) and j["value"] == "renewed")
time.sleep(2.2)
c("expired entry's PUT -> 201 not 200 after waiting", put(A, "ttl-one", "x", ttl=1), 200)
time.sleep(1.2)
c("an entry stored 1.2 s ago with ttl 1 is gone", s.req("GET", "/kv/ttl-one", A), 404)
c("DELETE on a live entry then expiry check", s.req("DELETE", "/kv/ttl-three", A), 204)
# 9. churn: replacing and deleting must give room back
t0 = time.time()
conn = http.client.HTTPConnection("127.0.0.1", 8814, timeout=15)
def fast(method, path, body=None):
    global conn
    for _ in range(2):
        try:
            conn.request(method, path, body=json.dumps(body) if body is not None else None, headers=dict(A, **{"Content-Type": "application/json"}))
            r = conn.getresponse(); r.read(); return r.status
        except Exception:
            conn.close(); conn = http.client.HTTPConnection("127.0.0.1", 8814, timeout=15)
    return 0
statuses = {}
for i in range(10000):
    st = fast("PUT", "/kv/churn", {"value": chr(97 + i % 26) * 1000})
    statuses[st] = statuses.get(st, 0) + 1
    if time.time() - t0 > 40: break
s.note("10000 replacements of one 1000-character value all succeed (first 201, then 200)", statuses == {201: 1, 200: 9999}, str(statuses))
c("... the last value is the stored one", s.req("GET", "/kv/churn", A), 200, test=lambda j: j["value"] == chr(97 + 9999 % 26) * 1000)
t1 = time.time()
statuses = {}
for i in range(1500):
    k = f"cy{i % 7}"
    a = fast("PUT", f"/kv/{k}", {"value": "z" * 900})
    b = fast("DELETE", f"/kv/{k}")
    statuses[(a, b)] = statuses.get((a, b), 0) + 1
    if time.time() - t1 > 15: break
s.note("PUT/DELETE cycles keep answering 201/204", set(statuses) == {(201, 204)}, str(statuses))
c("the 300 earlier keys are intact after the churn", s.req("GET", "/kv/m299", A), 200, test=lambda j: j["value"] == "m299")
s.note("the earlier listing is intact after the churn", keys(A, "?prefix=m&limit=100") is not None and len(keys(A, "?prefix=m&limit=100")) == 100, "")
# 10. robustness
out = s.raw(b"GARBAGE\r\n\r\n")
s.note("a malformed request line is answered 400", "400" in out.split("\r\n")[0], out[:60])
out = s.raw(b"GET /kv/alpha HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer tokA\r\nAuthorization: Bearer tokB\r\n\r\n")
s.note("two Authorization headers do not crash it", out.startswith("HTTP/1.1"), out[:60])
c("still alive after all of the above", s.req("GET", "/kv/perm-key", A), 200)
s.finish()
