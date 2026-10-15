#!/usr/bin/env python3
"""usage: attack.py BINARY PROJECT.cho -- independent attack on a built cancho `jobs` service (port of lex-code's 09-jobs attack.py).
Adapted from the Lex original: no database or environment (flags, in-memory state), no loopback-only check (a cancho listener binds all
interfaces), no `grants` check (authority is checked by service_run through SVC_AUTHORITY_OK); added: several tokens for one tenant, header and
token edge cases, the exact 4096-byte body boundary, characters-not-bytes payload length, deep nesting, the list page budget (64 KiB output buffer),
and idempotent replay after the job has moved on."""
import json, os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
from svc import Svc

s = Svc(sys.argv[1], ["--tokens", "tokA:acme,tokB:globex,tokC:acme"], 8811, label="ATTACK")
if os.environ.get("SVC_AUTHORITY_OK") == "0":
    s.note("authority is only what a server needs", False, os.environ.get("SVC_AUTHORITY_WHY", ""))
if not s.up:
    s.note("server starts with --port N --tokens ...", False, "did not start")
    s.finish()

# Never run for long against a service that has stopped answering: a request that times out twice ends the requests.
T0, DEAD = time.time(), [0]
_req, _raw = s.req, s.raw
def guarded(*a, **k):
    if DEAD[0] >= 2 or time.time() - T0 > 40:
        return 0, "<service unresponsive>"
    r = _req(*a, **k)
    if r[0] == 0: DEAD[0] += 1
    return r
s.req = guarded
s.raw = lambda *a, **k: "<service unresponsive>" if DEAD[0] >= 2 or time.time() - T0 > 40 else _raw(*a, **k)

def run():
    A, B, C3 = {"Authorization": "Bearer tokA"}, {"Authorization": "Bearer tokB"}, {"Authorization": "Bearer tokC"}
    def mk(h, kind="x", payload="p", extra=None, key=None):
        b = {"kind": kind, "payload": payload}; b.update(extra or {})
        hh = dict(h)
        if key is not None: hh["Idempotency-Key"] = key
        return s.req("POST", "/jobs", hh, b)
    c = s.check

    # 1. authentication
    r_none = c("no token -> 401", s.req("GET", "/jobs"), 401)
    r_unk = c("unknown token -> 401, not echoed", s.req("GET", "/jobs", {"Authorization": "Bearer nope"}), 401, excludes="nope")
    c("malformed (Basic) -> 401", s.req("GET", "/jobs", {"Authorization": "Basic dG9rQQ=="}), 401)
    c("scheme only -> 401", s.req("GET", "/jobs", {"Authorization": "Bearer"}), 401)
    c("empty token -> 401", s.req("GET", "/jobs", {"Authorization": "Bearer "}), 401)
    c("lowercase scheme -> 401", s.req("GET", "/jobs", {"Authorization": "bearer tokA"}), 401)
    c("token with a character appended -> 401", s.req("GET", "/jobs", {"Authorization": "Bearer tokAA"}), 401)
    c("token with a character prepended -> 401", s.req("GET", "/jobs", {"Authorization": "Bearer xtokA"}), 401)
    c("token truncated -> 401", s.req("GET", "/jobs", {"Authorization": "Bearer tok"}), 401)
    c("token in the wrong case -> 401", s.req("GET", "/jobs", {"Authorization": "Bearer TOKA"}), 401)
    c("two spaces after the scheme -> 401", s.req("GET", "/jobs", {"Authorization": "Bearer  tokA"}), 401)
    c("a tenant name is not a token -> 401", s.req("GET", "/jobs", {"Authorization": "Bearer acme"}), 401)
    c("the whole spec is not a token -> 401", s.req("GET", "/jobs", {"Authorization": "Bearer tokA:acme"}), 401)
    c("token followed by a comma entry -> 401", s.req("GET", "/jobs", {"Authorization": "Bearer tokA,tokB"}), 401)
    c("the last configured token works", s.req("GET", "/jobs", C3), 200)
    c("lowercase header name works", s.req("GET", "/jobs", {"authorization": "Bearer tokA"}), 200)
    s.note("missing and unknown token give the identical 401 body", r_none[1] == r_unk[1], "%r vs %r" % (r_none[1][:50], r_unk[1][:50]))
    c("POST without token -> 401", s.req("POST", "/jobs", None, {"kind": "x", "payload": "p"}), 401)
    c("claim without token -> 401", s.req("POST", "/jobs/1/claim"), 401)
    c("unknown path without token -> 401", s.req("GET", "/admin"), 401)
    c("tokens never appear in any 401 body", s.req("GET", "/jobs", {"Authorization": "Bearer tokB-but-wrong"}), 401, excludes="tokB")
    c("401 body is JSON with an error", s.req("GET", "/jobs"), 401, test=lambda j: isinstance(j, dict) and "error" in j)

    # 2. create
    r = c("create -> 201 with owner and state", mk(A), 201, test=lambda j: j["tenant"] == "acme" and j["state"] == "queued" and isinstance(j["id"], int) and j["kind"] == "x" and j["payload"] == "p")
    id1 = (s.j(r[1]) or {}).get("id", 1)
    c("create response never echoes a token", mk(A), 201, excludes="tokA")
    rb = mk(B)
    idb = (s.j(rb[1]) or {}).get("id", 2)
    c("tokens of one tenant share its jobs", s.req("GET", "/jobs/%s" % id1, C3), 200, test=lambda j: j["tenant"] == "acme")
    rc = c("a job made with the other acme token is acme's", mk(C3, kind="viac"), 201, test=lambda j: j["tenant"] == "acme")
    c("... and tokA sees it", s.req("GET", "/jobs/%s" % (s.j(rc[1]) or {}).get("id", 0), A), 200, test=lambda j: j["kind"] == "viac")
    c("ids are unique", s.req("GET", "/jobs?limit=50", A), 200, test=lambda j: len({x["id"] for x in j["jobs"]}) == len(j["jobs"]))

    # 3. listing
    c("GET /jobs with no query string -> 200", s.req("GET", "/jobs", A), 200, test=lambda j: isinstance(j["jobs"], list) and len(j["jobs"]) >= 3)
    c("tenant list shows only own jobs", s.req("GET", "/jobs", B), 200, test=lambda j: all(x["tenant"] == "globex" for x in j["jobs"]) and len(j["jobs"]) == 1)
    c("a job object has exactly id, tenant, kind, payload, state", s.req("GET", "/jobs/%s" % id1, A), 200, test=lambda j: sorted(j) == ["id", "kind", "payload", "state", "tenant"])
    c("state=queued -> 200", s.req("GET", "/jobs?state=queued", A), 200)
    c("state=bogus -> 400", s.req("GET", "/jobs?state=bogus", A), 400)
    c("state=QUEUED -> 400", s.req("GET", "/jobs?state=QUEUED", A), 400)
    c("state= (empty) -> 400", s.req("GET", "/jobs?state=", A), 400)
    c("state SQL injection -> 400", s.req("GET", "/jobs?state=queued'%20OR%20'1'='1", A), 400)
    c("state with a percent-encoded valid name -> 400 (not decoded)", s.req("GET", "/jobs?state=%71ueued", A), 400)
    c("after SQL injection -> 400", s.req("GET", "/jobs?after=1%20OR%201=1", A), 400)
    for bad in ["0", "51", "abc", "-1", "1.5", "+5", "", "1e1", "100"]:
        c("limit=%r -> 400" % bad, s.req("GET", "/jobs?limit=" + bad, A), 400)
    for bad in ["abc", "-1", "", "1.5", "1x"]:
        c("after=%r -> 400" % bad, s.req("GET", "/jobs?after=" + bad, A), 400)
    c("limit=1 -> 200", s.req("GET", "/jobs?limit=1", A), 200, test=lambda j: len(j["jobs"]) == 1)
    c("limit=50 -> 200", s.req("GET", "/jobs?limit=50", A), 200)
    c("an unknown query parameter is ignored", s.req("GET", "/jobs?foo=bar", A), 200)
    c("after=0 is valid", s.req("GET", "/jobs?after=0", A), 200, test=lambda j: len(j["jobs"]) >= 3)
    mk(A); mk(A)
    p1 = c("limit=2 returns 2 in ascending id order with next_after", s.req("GET", "/jobs?limit=2", A), 200,
           test=lambda j: len(j["jobs"]) == 2 and j["jobs"][0]["id"] < j["jobs"][1]["id"] and j["next_after"] == j["jobs"][1]["id"])
    last = ((s.j(p1[1]) or {}).get("next_after") if isinstance(s.j(p1[1]), dict) else 0) or 0
    c("after=<last id> pages on, ids greater and ascending", s.req("GET", "/jobs?limit=50&after=%s" % last, A), 200,
      test=lambda j: len(j["jobs"]) >= 1 and all(x["id"] > last for x in j["jobs"]) and [x["id"] for x in j["jobs"]] == sorted(x["id"] for x in j["jobs"]))
    c("after past the end -> empty list and null next_after", s.req("GET", "/jobs?after=999999", A), 200, test=lambda j: j["jobs"] == [] and j["next_after"] is None)
    def walk(h, query, limit):
        seen, after, guard = [], 0, 0
        while guard < 400:
            guard += 1
            st, t = s.req("GET", "/jobs?limit=%d&after=%d%s" % (limit, after, query), h)
            j = s.j(t)
            if st != 200 or not isinstance(j, dict) or not j.get("jobs"): break
            seen += [x["id"] for x in j["jobs"]]; after = j["next_after"]
        return seen
    ja = s.j(s.req("GET", "/jobs?limit=50", A)[1])
    all_a = [x["id"] for x in ja["jobs"]] if isinstance(ja, dict) and isinstance(ja.get("jobs"), list) else []
    walked = walk(A, "", 2)
    s.note("walking pages of 2 visits every acme job once, in order", walked == all_a and len(walked) >= 5, "%s vs %s" % (walked, all_a))

    # 4. isolation
    miss = s.req("GET", "/jobs/999999", B)
    c("B cannot read A's job: 404", s.req("GET", "/jobs/%s" % id1, B), 404)
    c("B cannot claim A's job: 404", s.req("POST", "/jobs/%s/claim" % id1, B), 404)
    c("B cannot complete A's job: 404", s.req("POST", "/jobs/%s/complete" % id1, B), 404)
    c("A cannot read B's job: 404", s.req("GET", "/jobs/%s" % idb, A), 404)
    fr, mi = s.req("GET", "/jobs/%s" % id1, B), miss
    s.note("foreign id and missing id give the identical response", fr == mi, "%s vs %s" % (fr, mi))
    fc, mc = s.req("POST", "/jobs/%s/claim" % id1, B), s.req("POST", "/jobs/999999/claim", B)
    s.note("foreign claim and missing claim give the identical response", fc == mc, "%s vs %s" % (fc, mc))
    c("A's job is untouched after B's attempts (still queued)", s.req("GET", "/jobs/%s" % id1, A), 200, test=lambda j: j["state"] == "queued")
    c("B's job is untouched after A's attempts (still queued)", s.req("GET", "/jobs/%s" % idb, B), 200, test=lambda j: j["state"] == "queued")

    # 5. state machine
    c("complete a queued job -> 409", s.req("POST", "/jobs/%s/complete" % id1, A), 409)
    c("claim -> 200 running", s.req("POST", "/jobs/%s/claim" % id1, A), 200, test=lambda j: j["state"] == "running" and j["id"] == id1)
    c("claim again -> 409", s.req("POST", "/jobs/%s/claim" % id1, A), 409)
    c("GET shows running", s.req("GET", "/jobs/%s" % id1, A), 200, test=lambda j: j["state"] == "running")
    c("state=running lists it", s.req("GET", "/jobs?state=running", A), 200, test=lambda j: [x["id"] for x in j["jobs"]] == [id1])
    c("the other acme token completes it -> 200 done", s.req("POST", "/jobs/%s/complete" % id1, C3), 200, test=lambda j: j["state"] == "done")
    c("complete again -> 409", s.req("POST", "/jobs/%s/complete" % id1, A), 409)
    c("claim a done job -> 409", s.req("POST", "/jobs/%s/claim" % id1, A), 409)
    c("state=done lists it", s.req("GET", "/jobs?state=done", A), 200, test=lambda j: [x["id"] for x in j["jobs"]] == [id1])
    c("state=queued no longer lists it", s.req("GET", "/jobs?state=queued", A), 200, test=lambda j: id1 not in [x["id"] for x in j["jobs"]] and len(j["jobs"]) >= 3)
    c("state filter and paging together", s.req("GET", "/jobs?state=queued&limit=1", A), 200, test=lambda j: len(j["jobs"]) == 1 and j["jobs"][0]["state"] == "queued")
    c("claim missing id -> 404", s.req("POST", "/jobs/999999/claim", A), 404)
    c("complete missing id -> 404", s.req("POST", "/jobs/999999/complete", A), 404)
    c("409 body is JSON with an error", s.req("POST", "/jobs/%s/claim" % id1, A), 409, test=lambda j: isinstance(j, dict) and "error" in j)

    # 6. path ids
    for bad in ["0", "-1", "abc", "1%20OR%201=1", "..%2Fetc%2Fpasswd", "99999999999999999999", "123456789012345678", "1.5", "%27", "1;2", "1,2"]:
        c("path id %r -> 404" % bad, s.req("GET", "/jobs/" + bad, A), 404)
    c("trailing slash /jobs/ -> 404", s.req("GET", "/jobs/", A), 404)
    c("literal ../etc/passwd -> 404", s.req("GET", "/jobs/../etc/passwd", A), 404)
    c("/jobs/{id}/ -> 404", s.req("POST", "/jobs/%s/" % id1, A), 404)
    c("/jobs/{id}/delete -> 404", s.req("POST", "/jobs/%s/delete" % id1, A), 404)
    c("/jobs/0/claim -> 404", s.req("POST", "/jobs/0/claim", A), 404)
    c("/jobs/abc/complete -> 404", s.req("POST", "/jobs/abc/complete", A), 404)
    c("/jobs/{id}/claim/x -> 404", s.req("POST", "/jobs/%s/claim/x" % id1, A), 404)

    # 7. create validation
    c("kind uppercase -> 400", mk(A, kind="Deploy"), 400)
    c("kind empty -> 400", mk(A, kind=""), 400)
    c("kind with space -> 400", mk(A, kind="a b"), 400)
    c("kind with a dot -> 400", mk(A, kind="a.b"), 400)
    c("kind with a non-ASCII letter -> 400", mk(A, kind="café"), 400)
    c("kind 41 chars -> 400", mk(A, kind="a" * 41), 400)
    c("kind 40 chars -> 201", mk(A, kind="a" * 40), 201)
    c("kind with - and _ -> 201", mk(A, kind="build-1_x"), 201)
    c("kind starting with a digit -> 201", mk(A, kind="9lives"), 201)
    c("kind SQL injection -> 400", mk(A, kind="x'; DROP TABLE jobs;--"), 400)
    c("kind with an escaped newline -> 400", s.req("POST", "/jobs", A, raw_body='{"kind":"a\\nb","payload":"p"}'), 400)
    c("kind spelled with \\u escapes is decoded -> 201", s.req("POST", "/jobs", A, raw_body='{"kind":"\\u0061bc","payload":"p"}'), 201, test=lambda j: j["kind"] == "abc")
    c("payload 1001 chars -> 400", mk(A, payload="a" * 1001), 400)
    c("payload 1000 chars -> 201", mk(A, payload="a" * 1000), 201, test=lambda j: len(j["payload"]) == 1000)
    c("payload of 1000 two-byte characters -> 201 (characters, not bytes)", s.req("POST", "/jobs", A, raw_body=json.dumps({"kind": "x", "payload": "é" * 1000}, ensure_ascii=False)), 201, test=lambda j: j["payload"] == "é" * 1000)
    c("payload of 1001 two-byte characters -> 400", s.req("POST", "/jobs", A, raw_body=json.dumps({"kind": "x", "payload": "é" * 1001}, ensure_ascii=False)), 400)
    c("payload empty string -> 201", mk(A, payload=""), 201, test=lambda j: j["payload"] == "")
    c("missing payload -> 400", s.req("POST", "/jobs", A, {"kind": "x"}), 400)
    c("missing kind -> 400", s.req("POST", "/jobs", A, {"payload": "p"}), 400)
    c("kind not a string -> 400", s.req("POST", "/jobs", A, {"kind": 5, "payload": "p"}), 400)
    c("payload not a string -> 400", s.req("POST", "/jobs", A, {"kind": "x", "payload": 5}), 400)
    c("payload null -> 400", s.req("POST", "/jobs", A, {"kind": "x", "payload": None}), 400)
    c("payload an object -> 400", s.req("POST", "/jobs", A, {"kind": "x", "payload": {"a": 1}}), 400)
    for f, v in [("id", 99), ("tenant", "globex"), ("tenant_id", 2), ("state", "done"), ("extra", 1), ("Kind", "y")]:
        c("unknown/forbidden field %r -> 400" % f, mk(A, extra={f: v}), 400)
    c("unknown field holding a long array -> 400", s.req("POST", "/jobs", A, raw_body='{"kind":"x","payload":"p","z":[' + ",".join(["1"] * 1500) + ']}'), 400)
    c("invalid JSON -> 400", s.req("POST", "/jobs", A, raw_body="{not json"), 400)
    c("truncated JSON -> 400", s.req("POST", "/jobs", A, raw_body='{"kind":"x","payload":"p"'), 400)
    c("trailing garbage after the object -> 400", s.req("POST", "/jobs", A, raw_body='{"kind":"x","payload":"p"} x'), 400)
    c("JSON array body -> 400", s.req("POST", "/jobs", A, raw_body="[1,2]"), 400)
    c("JSON string body -> 400", s.req("POST", "/jobs", A, raw_body='"kind"'), 400)
    c("JSON null body -> 400", s.req("POST", "/jobs", A, raw_body="null"), 400)
    c("empty body -> 400", s.req("POST", "/jobs", A, raw_body=""), 400)
    c("deeply nested body -> 400, no crash", s.req("POST", "/jobs", A, raw_body="[" * 2000 + "]" * 2000), 400)
    c("deeply nested unknown field -> 400, no crash", s.req("POST", "/jobs", A, raw_body='{"kind":"x","payload":"p","z":' + "[" * 1000 + "]" * 1000 + "}"), 400)
    c("payload quotes and SQL text stored verbatim", mk(A, payload="it's ' OR '1'='1"), 201, test=lambda j: j["payload"] == "it's ' OR '1'='1")
    c("payload with backslashes, quotes, newline and unicode round-trips", mk(A, payload='a\\b"c\nd 日本 \U0001F600'), 201, test=lambda j: j["payload"] == 'a\\b"c\nd 日本 \U0001F600')
    rj = mk(A, payload="stored-check")
    c("a created job reads back the same through GET", s.req("GET", "/jobs/%s" % (s.j(rj[1]) or {}).get("id", 0), A), 200, test=lambda j: j["payload"] == "stored-check" and j["kind"] == "x")
    c("the failed creates above created nothing", s.req("GET", "/jobs?limit=50&state=queued", A), 200, test=lambda j: all(x["kind"] != "Deploy" and x["kind"] != "" for x in j["jobs"]))

    # 8. size limit
    pad = '{"kind":"x","payload":"p"}'
    c("body of exactly 4096 bytes -> 201", s.req("POST", "/jobs", A, raw_body=pad + " " * (4096 - len(pad))), 201)
    c("body of 4097 bytes -> 413", s.req("POST", "/jobs", A, raw_body=pad + " " * (4097 - len(pad))), 413)
    c("body of 5000 bytes -> 413", s.req("POST", "/jobs", A, raw_body='{"kind":"x","payload":"' + "a" * 5000 + '"}'), 413)
    c("body of 12000 bytes -> 413", s.req("POST", "/jobs", A, raw_body='{"kind":"x","payload":"' + "a" * 12000 + '"}'), 413)
    c("body of 200000 bytes -> 413", s.req("POST", "/jobs", A, raw_body='{"kind":"x","payload":"' + "a" * 200000 + '"}'), 413)
    c("oversized body that is not even JSON -> 413", s.req("POST", "/jobs", A, raw_body="x" * 6000), 413)
    c("oversized unauthenticated body still refused (401 or 413), never 500", s.req("POST", "/jobs", None, raw_body="x" * 6000), [401, 413])
    c("oversized body on a GET is refused too", s.req("GET", "/jobs", A, raw_body="x" * 6000), 413)
    c("alive after oversized bodies", s.req("GET", "/jobs", A), 200)

    # 9. idempotency
    def count(h):
        j = s.j(s.req("GET", "/jobs?limit=50", h)[1])
        return len(j["jobs"]) if isinstance(j, dict) and isinstance(j.get("jobs"), list) else -1
    k1 = c("idempotent create (first) -> 201", mk(A, key="key-1"), 201)
    n1 = count(A)
    k2 = c("same key, same tenant -> 200 and the same job", mk(A, key="key-1"), 200)
    n2 = count(A)
    id_k = (s.j(k1[1]) or {}).get("id")
    s.note("replayed idempotency key returns the original id", id_k is not None and id_k == (s.j(k2[1]) or {}).get("id"), "%s vs %s" % (k1[1][:60], k2[1][:60]))
    s.note("replay created nothing (job count unchanged)", n1 == n2 and n1 >= 0, "%s -> %s" % (n1, n2))
    c("same key with a different body still returns the original", mk(A, kind="other", payload="different", key="key-1"), 200, test=lambda j: j["id"] == id_k and j["kind"] == "x" and j["payload"] == "p")
    c("the other acme token shares the tenant's keys", mk(C3, key="key-1"), 200, test=lambda j: j["id"] == id_k)
    kb = c("same key, other tenant -> 201 (independent)", mk(B, key="key-1"), 201, test=lambda j: j["tenant"] == "globex")
    s.note("other tenant's job with the same key is a different job", (s.j(kb[1]) or {}).get("id") != id_k)
    c("other tenant replays its own key -> 200", mk(B, key="key-1"), 200, test=lambda j: j["id"] == (s.j(kb[1]) or {}).get("id"))
    c("a different key creates a new job", mk(A, key="key-2"), 201, test=lambda j: j["id"] != id_k)
    c("a key that is a prefix of another is a different key", mk(A, key="key-"), 201)
    c("a key differing in case is a different key", mk(A, key="KEY-1"), 201)
    s.req("POST", "/jobs/%s/claim" % id_k, A)
    c("replay after the job moved on returns it as it is now", mk(A, key="key-1"), 200, test=lambda j: j["id"] == id_k and j["state"] == "running")
    c("an invalid body with a known key is still 400", mk(A, kind="BAD", key="key-1"), 400)
    n3 = count(A)
    a1 = mk(A, key=""); a2 = mk(A, key="")
    s.note("an empty Idempotency-Key is no key: two creates make two jobs", a1[0] == 201 and a2[0] == 201 and (s.j(a1[1]) or {}).get("id") != (s.j(a2[1]) or {}).get("id"), "%s / %s" % (a1[0], a2[0]))
    c("a long key works", mk(A, key="k" * 300), 201)
    c("... and replays", mk(A, key="k" * 300), 200)
    c("a key with spaces and punctuation works", mk(A, key="a b; c=d/e"), 201)

    # 10. the page budget: 60 jobs of 1000 characters, each ~2000 bytes of JSON once the newlines are escaped, are more than one 64 KiB answer
    big = []
    for i in range(60):
        st, t = mk(C3, kind="big", payload=chr(97 + i % 26) + "\n" * 999)
        big.append((s.j(t) or {}).get("id") if st == 201 else None)
    c("60 large jobs created", (201, "") if None not in big else (0, "some creates failed"), 201)
    st, t = s.req("GET", "/jobs?limit=50&state=queued", A)
    j = s.j(t)
    s.note("a page of large jobs is answered (200), not cut off or dropped", st == 200 and isinstance(j, dict) and len(j["jobs"]) >= 1 and j["next_after"] == j["jobs"][-1]["id"], "status %s, %s bytes" % (st, len(t)))
    s.note("a page stays under the 64 KiB output buffer", st == 200 and len(t) < 65000, "%s bytes" % len(t))
    seen, after, pages = [], 0, 0
    while pages < 100:
        pages += 1
        st, t = s.req("GET", "/jobs?limit=50&state=queued&after=%d" % after, A)
        j = s.j(t)
        if st != 200 or not isinstance(j, dict) or not j["jobs"]: break
        seen += [x["id"] for x in j["jobs"] if x["kind"] == "big"]
        after = j["next_after"]
    s.note("following next_after reaches all 60 large jobs once, in order", seen == [b for b in big if b], "%d seen in %d pages" % (len(seen), pages))
    c("a large job reads back whole", s.req("GET", "/jobs/%s" % big[3], A), 200, test=lambda j: j["payload"] == chr(97 + 3) + "\n" * 999)

    # 10b. a slow reader must still get a whole answer: a page that does not fit what the kernel takes plus the server's 64 KiB queue closes the
    # connection. 55 jobs whose payload is 600 control characters (one \\u0001 escape each in the request and in the answer, ~3.6 KB of JSON per job).
    import socket
    ctl = '{"kind":"ctl","payload":"' + "\\u0001" * 600 + '"}'
    made = [s.req("POST", "/jobs", B, raw_body=ctl)[0] for _ in range(55)]
    c("55 control-character jobs created", (201, "") if made.count(201) == 55 else (0, "statuses %s" % sorted(set(made))), 201)
    def slow_get(path, headers, rcvbuf=4096, pause=1.5):
        if DEAD[0] >= 2 or time.time() - T0 > 40: return 0, "<service unresponsive>"
        try:
            k = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            k.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)
            k.settimeout(8); k.connect(("127.0.0.1", s.port))
            k.sendall(("GET %s HTTP/1.1\r\nHost: x\r\nConnection: close\r\n%s\r\n" % (path, "".join("%s: %s\r\n" % kv for kv in headers.items()))).encode())
            time.sleep(pause)
            data = b""
            try:
                while True:
                    chunk = k.recv(65536)
                    if not chunk: break
                    data += chunk
            except OSError:
                pass
            k.close()
        except OSError as ex:
            return 0, "<%s>" % ex
        head, _, body = data.partition(b"\r\n\r\n")
        try: status = int(head.split(b" ")[1])
        except Exception: return 0, "<no response: %d bytes>" % len(data)
        want = [int(l.split(b":")[1]) for l in head.split(b"\r\n") if l.lower().startswith(b"content-length:")]
        if want and want[0] != len(body): return 0, "<answer cut off: %d of %d bytes>" % (len(body), want[0])
        return status, body.decode("utf-8", "replace")
    sr = slow_get("/jobs?limit=50", B)
    c("a client that reads late still gets a whole page of large jobs", sr, 200, test=lambda j: len(j["jobs"]) >= 1 and j["next_after"] == j["jobs"][-1]["id"])
    s.note("... and that page is under 64 KiB", sr[0] == 200 and len(sr[1].encode()) < 65536, "%d bytes" % len(sr[1].encode()))
    c("alive after the slow reader", s.req("GET", "/jobs", A), 200)

    # 11. methods and unknown routes never crash
    c("unknown route -> 404 (authenticated)", s.req("GET", "/nothing", A), 404)
    c("root -> 404", s.req("GET", "/", A), 404)
    c("DELETE /jobs/1 -> 404 or 405", s.req("DELETE", "/jobs/%s" % id1, A), [404, 405])
    c("PUT /jobs -> 404 or 405", s.req("PUT", "/jobs", A, {"kind": "x", "payload": "p"}), [404, 405])
    c("POST /jobs/{id} -> 404 or 405", s.req("POST", "/jobs/%s" % id1, A), [404, 405])
    c("GET /jobs/{id}/claim -> 404 or 405", s.req("GET", "/jobs/%s/claim" % id1, A), [404, 405])
    c("DELETE /jobs -> 404 or 405", s.req("DELETE", "/jobs", A), [404, 405])
    c("a refused foreign claim by GET is still 404/405, never the job", s.req("GET", "/jobs/%s/claim" % id1, B), [404, 405])
    c("still alive after all of the above", s.req("GET", "/jobs", A), 200)

try:
    run()
except Exception as ex:
    s.note("the script could not read an answer (malformed or missing body)", False, repr(ex)[:160])
s.finish()
