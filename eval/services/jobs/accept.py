#!/usr/bin/env python3
"""usage: accept.py BINARY PROJECT.cho -- the brief's explicit requirements for `jobs`, replayed against the built service.
The text of a failure is the builder's feedback, so every check names the requirement it comes from."""
import os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
from svc import Svc

s = Svc(sys.argv[1], ["--tokens", "tokA:acme,tokB:globex"], 18811, label="ACCEPTANCE")
if os.environ.get("SVC_AUTHORITY_OK") == "0":
    s.note("authority is only what a server needs", False, os.environ.get("SVC_AUTHORITY_WHY", ""))
if not s.up:
    s.note("service starts with --port N --tokens ...", False, "did not start or does not listen")
    s.finish()

# A service that stops answering must not make this script run for minutes.
T0, DEAD = time.time(), [0]
_req = s.req
def guarded(*a, **k):
    if DEAD[0] >= 2 or time.time() - T0 > 40:
        return 0, "<service unresponsive>"
    r = _req(*a, **k)
    if r[0] == 0: DEAD[0] += 1
    return r
s.req = guarded

def run():
    A, B = {"Authorization": "Bearer tokA"}, {"Authorization": "Bearer tokB"}
    def mk(h, kind="build", payload="p", extra=None, key=None):
        b = {"kind": kind, "payload": payload}; b.update(extra or {})
        hh = dict(h)
        if key: hh["Idempotency-Key"] = key
        return s.req("POST", "/jobs", hh, b)
    c = s.check
    def job_ok(j, tenant, state): return j["tenant"] == tenant and j["state"] == state and isinstance(j["id"], int) and "kind" in j and "payload" in j

    # security 1: authentication
    r_none = c("1. no Authorization header -> 401", s.req("GET", "/jobs"), 401)
    r_unk = c("1. unknown token -> 401 and the token is not echoed", s.req("GET", "/jobs", {"Authorization": "Bearer wrong-token-xyz"}), 401, excludes="wrong-token-xyz")
    c("1. 'Bearer' with no token -> 401", s.req("GET", "/jobs", {"Authorization": "Bearer"}), 401)
    c("1. 'Basic ...' scheme -> 401", s.req("GET", "/jobs", {"Authorization": "Basic dG9rQQ=="}), 401)
    c("1. a token longer than a configured one -> 401", s.req("GET", "/jobs", {"Authorization": "Bearer tokAx"}), 401)
    c("1. a token that is only a prefix of a configured one -> 401", s.req("GET", "/jobs", {"Authorization": "Bearer tok"}), 401)
    c("1. lowercase scheme 'bearer' -> 401", s.req("GET", "/jobs", {"Authorization": "bearer tokA"}), 401)
    s.note("1. missing and unknown token give the identical 401 body", r_none[1] == r_unk[1], "%r vs %r" % (r_none[1][:60], r_unk[1][:60]))
    c("1. authentication comes first even for an unknown path -> 401", s.req("GET", "/no/such/path"), 401)
    c("1. a valid token works with a lowercase header name", s.req("GET", "/jobs", {"authorization": "Bearer tokA"}), 200)

    # create
    r = c("POST /jobs -> 201 with the owner, state queued and an integer id", mk(A), 201, test=lambda j: job_ok(j, "acme", "queued") and j["kind"] == "build" and j["payload"] == "p")
    id1 = (s.j(r[1]) or {}).get("id", 1)
    c("a create response never contains a token", mk(A), 201, excludes="tokA")
    mk(B, kind="other")
    c("responses are JSON", s.req("GET", "/jobs/%s" % id1, A), 200, test=lambda j: isinstance(j, dict))
    c("GET /jobs/{id} returns the job", s.req("GET", "/jobs/%s" % id1, A), 200, test=lambda j: j["id"] == id1 and job_ok(j, "acme", "queued"))

    # listing
    c("GET /jobs lists only the caller's tenant's jobs", s.req("GET", "/jobs", B), 200, test=lambda j: len(j["jobs"]) == 1 and j["jobs"][0]["tenant"] == "globex" and j["next_after"] == j["jobs"][0]["id"])
    c("state=queued filters", s.req("GET", "/jobs?state=queued", A), 200, test=lambda j: len(j["jobs"]) >= 2 and all(x["state"] == "queued" for x in j["jobs"]))
    c("state=bogus -> 400", s.req("GET", "/jobs?state=bogus", A), 400)
    c("security 3: SQL-looking state -> 400", s.req("GET", "/jobs?state=queued'%20OR%20'1'='1", A), 400)
    c("security 3: limit=0 -> 400", s.req("GET", "/jobs?limit=0", A), 400)
    c("security 3: limit=51 -> 400", s.req("GET", "/jobs?limit=51", A), 400)
    c("security 3: limit=abc -> 400", s.req("GET", "/jobs?limit=abc", A), 400)
    c("security 3: after=abc -> 400", s.req("GET", "/jobs?after=abc", A), 400)
    mk(A); mk(A)
    p1 = c("limit=2 gives 2 jobs, ascending, with next_after = last id", s.req("GET", "/jobs?limit=2", A), 200,
           test=lambda j: len(j["jobs"]) == 2 and j["jobs"][0]["id"] < j["jobs"][1]["id"] and j["next_after"] == j["jobs"][1]["id"])
    last = (s.j(p1[1]) or {}).get("next_after") or 0
    c("after=<last> returns only greater ids", s.req("GET", "/jobs?limit=50&after=%s" % last, A), 200, test=lambda j: len(j["jobs"]) >= 1 and all(x["id"] > last for x in j["jobs"]))
    c("after past the end -> empty jobs and null next_after", s.req("GET", "/jobs?after=999999", A), 200, test=lambda j: j["jobs"] == [] and j["next_after"] is None)

    # security 2: isolation
    miss = s.req("GET", "/jobs/999999", B)
    c("2. a missing id -> 404", miss, 404)
    c("2. another tenant's job -> 404 (not 403)", s.req("GET", "/jobs/%s" % id1, B), 404)
    c("2. claim of another tenant's job -> 404", s.req("POST", "/jobs/%s/claim" % id1, B), 404)
    c("2. complete of another tenant's job -> 404", s.req("POST", "/jobs/%s/complete" % id1, B), 404)
    s.note("2. foreign id and missing id give the identical response", s.req("GET", "/jobs/%s" % id1, B) == miss, "")
    c("2. the job is untouched after the foreign attempts", s.req("GET", "/jobs/%s" % id1, A), 200, test=lambda j: j["state"] == "queued")

    # state machine
    c("complete of a queued job -> 409", s.req("POST", "/jobs/%s/complete" % id1, A), 409)
    c("claim -> 200 running", s.req("POST", "/jobs/%s/claim" % id1, A), 200, test=lambda j: j["state"] == "running" and j["id"] == id1)
    c("claim of a running job -> 409", s.req("POST", "/jobs/%s/claim" % id1, A), 409)
    c("complete -> 200 done", s.req("POST", "/jobs/%s/complete" % id1, A), 200, test=lambda j: j["state"] == "done")
    c("claim of a done job -> 409", s.req("POST", "/jobs/%s/claim" % id1, A), 409)
    c("complete of a done job -> 409", s.req("POST", "/jobs/%s/complete" % id1, A), 409)
    c("claim of a missing id -> 404", s.req("POST", "/jobs/999999/claim", A), 404)

    # security 6: path ids
    for bad in ["0", "abc", "1%20OR%201=1"]:
        c("6. path id %r -> 404" % bad, s.req("GET", "/jobs/" + bad, A), 404)

    # security 4: validation
    c("4. kind with uppercase -> 400", mk(A, kind="Deploy"), 400)
    c("4. empty kind -> 400", mk(A, kind=""), 400)
    c("4. kind of 41 characters -> 400", mk(A, kind="a" * 41), 400)
    c("4. kind of 40 characters -> 201", mk(A, kind="a" * 40), 201)
    c("4. kind with - and _ and digits -> 201", mk(A, kind="job_7-x"), 201)
    c("4. payload of 1001 characters -> 400", mk(A, payload="a" * 1001), 400)
    c("4. payload of 1000 characters -> 201", mk(A, payload="a" * 1000), 201)
    c("4. missing payload -> 400", s.req("POST", "/jobs", A, {"kind": "x"}), 400)
    c("4. kind of the wrong type -> 400", s.req("POST", "/jobs", A, {"kind": 5, "payload": "p"}), 400)
    for f, v in [("id", 99), ("tenant", "globex"), ("state", "done")]:
        c("4. body setting %r -> 400" % f, mk(A, extra={f: v}), 400)
    c("4. invalid JSON -> 400", s.req("POST", "/jobs", A, raw_body="{not json"), 400)
    c("4. payload comes back verbatim", mk(A, payload="it's \"quoted\" \\ and ' OR '1'='1"), 201, test=lambda j: j["payload"] == "it's \"quoted\" \\ and ' OR '1'='1")

    # security 5: size
    c("5. body of 5000 bytes -> 413", s.req("POST", "/jobs", A, raw_body='{"kind":"x","payload":"' + "a" * 5000 + '"}'), 413)

    # idempotency
    k1 = c("idempotent create: first call -> 201", mk(A, key="accept-key-1"), 201)
    k2 = c("same key, same tenant -> 200 and the same job", mk(A, key="accept-key-1"), 200)
    s.note("replay returns the original id", (s.j(k1[1]) or {}).get("id") == (s.j(k2[1]) or {}).get("id") is not None, "%s vs %s" % (k1[1][:60], k2[1][:60]))
    kb = c("same key, other tenant -> 201, independent", mk(B, key="accept-key-1"), 201, test=lambda j: j["tenant"] == "globex")
    s.note("the other tenant's job is a different job", (s.j(kb[1]) or {}).get("id") != (s.j(k1[1]) or {}).get("id"), "")

    # methods
    c("unknown path with a valid token -> 404", s.req("GET", "/nothing", A), 404)
    c("DELETE /jobs/{id} -> 404 or 405", s.req("DELETE", "/jobs/%s" % id1, A), [404, 405])
    c("still alive after all of the above", s.req("GET", "/jobs", A), 200)

try:
    run()
except Exception as ex:
    s.note("the script could not read an answer (malformed or missing body)", False, repr(ex)[:160])
s.finish()
