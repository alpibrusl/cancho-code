#!/usr/bin/env python3
"""usage: accept.py BINARY PROJECT_CHO  -- the acceptance scenarios of the kvstore brief (what the builder is shown).

Port 18814. Takes about 4 seconds (two real sleeps for expiry)."""
import json, os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
from svc import Svc

binary = sys.argv[1]
s = Svc(binary, ["--tokens", "tokA:acme,tokB:globex"], 18814, label="ACCEPTANCE")
if os.environ.get("SVC_AUTHORITY_OK") == "0":
    s.note("authority is only what a server needs", False, os.environ.get("SVC_AUTHORITY_WHY", ""))
if not s.up:
    s.note("service starts and listens", False, "did not start")
    s.finish()
A, B = {"Authorization": "Bearer tokA"}, {"Authorization": "Bearer tokB"}
c = s.check

def put(h, key, value="v", ttl=None, extra=None):
    b = {"value": value}
    if ttl is not None: b["ttl_seconds"] = ttl
    b.update(extra or {})
    return s.req("PUT", "/kv/" + key, h, b)

# authentication
r_none = c("GET without token -> 401", s.req("GET", "/kv/a"), 401)
r_unk = c("GET with an unknown token -> 401, token not echoed", s.req("GET", "/kv/a", {"Authorization": "Bearer nope"}), 401, excludes="nope")
r_bad = c("GET with a Basic scheme -> 401", s.req("GET", "/kv/a", {"Authorization": "Basic dG9rQQ=="}), 401)
c("GET with 'Bearer' and no token -> 401", s.req("GET", "/kv/a", {"Authorization": "Bearer"}), 401)
c("PUT without token -> 401", s.req("PUT", "/kv/a", None, {"value": "v"}), 401)
c("DELETE without token -> 401", s.req("DELETE", "/kv/a"), 401)
c("listing without token -> 401", s.req("GET", "/kv"), 401)
s.note("missing, malformed and unknown token give the identical 401 body", r_none[1] == r_unk[1] == r_bad[1], "%r / %r / %r" % (r_none[1][:40], r_unk[1][:40], r_bad[1][:40]))
# put / get / delete
c("PUT new key -> 201 {key, value}", put(A, "k1", "hello"), 201, test=lambda j: j == {"key": "k1", "value": "hello"})
c("PUT existing key -> 200", put(A, "k1", "hello2"), 200, test=lambda j: j["value"] == "hello2")
c("GET -> value, permanent has null expires_in", s.req("GET", "/kv/k1", A), 200, test=lambda j: j == {"key": "k1", "value": "hello2", "expires_in": None})
c("GET missing key -> 404", s.req("GET", "/kv/missing", A), 404)
c("empty value is allowed", put(A, "empty", ""), 201)
c("DELETE existing -> 204", s.req("DELETE", "/kv/empty", A), 204)
c("DELETE again -> 404", s.req("DELETE", "/kv/empty", A), 404)
c("value with quotes, newline and non-ASCII round-trips", put(A, "txt", 'it\'s "q" \\ \n é日本'), 201)
c("... read back verbatim", s.req("GET", "/kv/txt", A), 200, test=lambda j: j["value"] == 'it\'s "q" \\ \n é日本')
# tenants
c("other tenant cannot read: 404", s.req("GET", "/kv/k1", B), 404)
c("other tenant cannot delete: 404", s.req("DELETE", "/kv/k1", B), 404)
c("same key in the other tenant is new: 201", put(B, "k1", "bee"), 201)
c("first tenant keeps its value", s.req("GET", "/kv/k1", A), 200, test=lambda j: j["value"] == "hello2")
c("each tenant lists only its own keys", s.req("GET", "/kv", B), 200, test=lambda j: j == {"keys": ["k1"]})
# keys
c("uppercase key on GET -> 404", s.req("GET", "/kv/UPPER", A), 404)
c("uppercase key on PUT -> 400", put(A, "UPPER"), 400)
c("65-character key on PUT -> 400", put(A, "k" * 65), 400)
c("64-character key on PUT -> 201", put(A, "k" * 64), 201)
c("key with . _ - -> 201", put(A, "a.b_c-d"), 201)
# body validation
c("value of 1001 characters -> 400", put(A, "v1", "a" * 1001), 400)
c("value of 1000 characters -> 201", put(A, "v2", "a" * 1000), 201)
c("missing value -> 400", s.req("PUT", "/kv/v3", A, {}), 400)
c("value not a string -> 400", s.req("PUT", "/kv/v3", A, {"value": 5}), 400)
c("ttl_seconds 0 -> 400", put(A, "t0", ttl=0), 400)
c("ttl_seconds 86401 -> 400", put(A, "t0", ttl=86401), 400)
c("ttl_seconds 1.5 -> 400", s.req("PUT", "/kv/t0", A, {"value": "v", "ttl_seconds": 1.5}), 400)
c("ttl_seconds 86400 -> 201", put(A, "t1", ttl=86400), 201)
c("unknown field -> 400", put(A, "u1", extra={"extra": 1}), 400)
c("invalid JSON -> 400", s.req("PUT", "/kv/u2", A, raw_body="{nope"), 400)
c("body of 5000 bytes -> 413", s.req("PUT", "/kv/big", A, raw_body='{"value":"' + "a" * 5000 + '"}'), 413)
c("rejected PUT stored nothing", s.req("GET", "/kv/u1", A), 404)
# listing
for k in ["app.one", "app.two", "app_three", "apx", "zeta"]: put(A, k)
c("listing is ascending", s.req("GET", "/kv?limit=100", A), 200, test=lambda j: j["keys"] == sorted(j["keys"]) and "app.one" in j["keys"])
c("prefix app. lists exactly the matching keys", s.req("GET", "/kv?prefix=app.", A), 200, test=lambda j: j == {"keys": ["app.one", "app.two"]})
c("prefix with SQL -> 400", s.req("GET", "/kv?prefix=a'%20OR%20'1'='1", A), 400)
c("prefix with % -> 400", s.req("GET", "/kv?prefix=%25", A), 400)
c("limit=0 -> 400", s.req("GET", "/kv?limit=0", A), 400)
c("limit=101 -> 400", s.req("GET", "/kv?limit=101", A), 400)
c("limit=2 returns exactly 2 keys", s.req("GET", "/kv?limit=2", A), 200, test=lambda j: len(j["keys"]) == 2)
# expiry (real clock)
c("PUT with ttl 1 -> 201", put(A, "ttl-short", "soon", ttl=1), 201)
c("PUT with ttl 2 -> 201", put(A, "ttl-two", "later", ttl=2), 201)
c("PUT ttl 2 then replace without ttl", put(A, "swap", "x", ttl=2), 201)
c("... replace -> 200", put(A, "swap", "y"), 200)
c("GET shows expires_in 2 for a fresh ttl of 2", s.req("GET", "/kv/ttl-two", A), 200, test=lambda j: j["expires_in"] in (1, 2))
time.sleep(1.3)
c("entry with ttl 1 has expired: 404", s.req("GET", "/kv/ttl-short", A), 404)
c("entry with ttl 2 is still there, expires_in 1", s.req("GET", "/kv/ttl-two", A), 200, test=lambda j: j["expires_in"] == 1)
time.sleep(1.2)
c("entry with ttl 2 has expired: 404", s.req("GET", "/kv/ttl-two", A), 404)
c("expired entries are not listed", s.req("GET", "/kv?limit=100", A), 200, excludes="ttl-")
c("DELETE of an expired entry -> 404", s.req("DELETE", "/kv/ttl-short", A), 404)
c("entry replaced without ttl survives", s.req("GET", "/kv/swap", A), 200, test=lambda j: j["expires_in"] is None)
c("PUT on an expired key -> 201 (as new)", put(A, "ttl-short", "again"), 201)
c("service still serves", s.req("GET", "/kv/k1", A), 200)
s.finish()
