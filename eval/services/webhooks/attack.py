#!/usr/bin/env python3
"""usage: attack.py BINARY PROJECT.cho -- the hidden, independent attack on a built `webhooks` service (port of lex-code backlog 11, adapted to cancho)."""
import sys, os, hmac, hashlib, json, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
from svc import Svc

SECRETS = {"hook-a": "k9 Zq/attack+1", "hook_b": "p@ss%w0rd=2", "c": "x"}
ADMIN = "Adm.tok_77-attack"
s = Svc(sys.argv[1], ["--admin-token", ADMIN, "--secrets", ",".join("%s:%s" % kv for kv in SECRETS.items())], 8813, label="ATTACK")
if os.environ.get("SVC_AUTHORITY_OK") == "0":
    s.note("declared authority is only what a server needs", False, os.environ.get("SVC_AUTHORITY_WHY", ""))
if not s.up:
    s.note("the service starts and listens", False, "did not start")
    s.finish()
c = s.check
T0 = time.time()
_req = s.req
def _guarded(*a, **k):
    return (0, "<script deadline>") if time.time() - T0 > 28 else _req(*a, **k)
s.req = _guarded
A, B = "hook-a", "hook_b"

def sign(secret, ts, body):
    return "sha256=" + hmac.new(secret.encode(), ("%s." % ts).encode() + body, hashlib.sha256).hexdigest()

def send(source, event_id, obj=None, ts=None, secret=None, raw=None, sig=None, hdr=None):
    body = raw if raw is not None else json.dumps(obj if obj is not None else {"k": "v"}).encode()
    ts = int(time.time()) if ts is None else ts
    h = {"X-Timestamp": str(ts), "X-Event-Id": event_id, "Content-Type": "application/json"}
    h["X-Signature"] = sig if sig is not None else sign(secret if secret is not None else SECRETS.get(source, "x"), ts, body)
    h.update(hdr or {})
    for k in [k for k, v in h.items() if v is None]: del h[k]
    return s.req("POST", "/hooks/%s" % source, h, raw_body=body)

import http.client
_conn = [None]
def send_keep(source, event_id, obj):
    """one delivery on a connection that is kept open (the capacity loop sends 1000 of them; a connection each would exhaust ephemeral ports)"""
    body = json.dumps(obj).encode()
    ts = int(time.time())
    h = {"X-Timestamp": str(ts), "X-Event-Id": event_id, "X-Signature": sign(SECRETS[source], ts, body)}
    if time.time() - T0 > 28: return (0, "<script deadline>")
    for attempt in (0, 1):
        try:
            if _conn[0] is None: _conn[0] = http.client.HTTPConnection("127.0.0.1", s.port, timeout=15)
            _conn[0].request("POST", "/hooks/%s" % source, body=body, headers=h)
            r = _conn[0].getresponse()
            return (r.status, r.read().decode("utf-8", "replace"))
        except Exception as ex:
            try: _conn[0].close()
            except Exception: pass
            _conn[0] = None
            err = (0, "<%s>" % ex)
    return err

AD = {"Authorization": "Bearer %s" % ADMIN}
def events(q=""):
    j = s.j(s.req("GET", "/events" + q, AD)[1])
    return j["events"] if isinstance(j, dict) and isinstance(j.get("events"), list) else None

# 1. happy path, dedupe
r = c("valid delivery -> 202 not duplicate", send(A, "evt-1", {"a": 1}), 202, test=lambda j: j["duplicate"] is False and isinstance(j["id"], int) and j["id"] >= 1)
id1 = (s.j(r[1]) or {}).get("id")
c("same event id again -> 200 duplicate with the original id", send(A, "evt-1", {"a": 1}), 200, test=lambda j: j["duplicate"] is True and j["id"] == id1)
r2 = c("same event id, a different body -> still the duplicate", send(A, "evt-1", {"other": True}), 200, test=lambda j: j["duplicate"] is True and j["id"] == id1)
c("same event id, other source -> 202 (independent)", send(B, "evt-1", {"b": 2}), 202, test=lambda j: j["duplicate"] is False)
r3 = c("second event id -> 202 with a larger id", send(A, "evt-2", {"a": 2}), 202, test=lambda j: j["id"] > id1)
c("event ids differing only in case are different events", send(A, "EVT-1", {"a": 3}), 202, test=lambda j: j["duplicate"] is False)
ev = events()
s.note("stored exactly 4 events (duplicates were not stored)", ev is not None and len(ev) == 4, str(None if ev is None else len(ev)))
s.note("events ordered by id ascending", ev is not None and [e["id"] for e in ev] == sorted(e["id"] for e in ev))
s.note("the first event keeps its original body", ev is not None and any(e["source"] == A and e["event_id"] == "evt-1" and e["body"] == {"a": 1} for e in ev), str(ev))
s.note("received_at is the current Unix time in seconds", ev is not None and all(isinstance(e["received_at"], int) and abs(e["received_at"] - time.time()) < 30 for e in ev), str(ev))
s.note("events carry exactly id, source, event_id, received_at, body", ev is not None and all(sorted(e) == ["body", "event_id", "id", "received_at", "source"] for e in ev), str(ev))

# 2. signature failures
base = events() or []
r_bad = c("wrong signature -> 401", send(A, "x1", sig="sha256=" + "0" * 64), 401)
r_unk = c("unknown source -> 401", send("nosuch", "x2", secret="whatever"), 401)
r_unk2 = c("unknown source with a structurally valid request -> 401", send("hook", "x2b", secret=SECRETS[A]), 401)
s.note("unknown source and bad signature give the identical response", r_bad == r_unk == r_unk2, "%s | %s | %s" % (r_bad, r_unk, r_unk2))
c("source names are case sensitive: HOOK-A -> 401", send("HOOK-A", "x2c", secret=SECRETS[A]), 401)
c("missing signature -> 401", send(A, "x3", hdr={"X-Signature": None}), 401)
c("empty signature -> 401", send(A, "x3b", sig=""), 401)
T = int(time.time())
good = sign(SECRETS[A], T, b'{"k": "v"}')
c("control: the unmodified signature at that timestamp is accepted", send(A, "x3c", ts=T, sig=good), 202)
base = events() or []
c("signature without prefix -> 401", send(A, "x4", ts=T, sig=good[7:]), 401)
c("signature with the wrong prefix -> 401", send(A, "x4b", ts=T, sig="sha1=" + good[7:]), 401)
c("uppercase hex signature -> 401", send(A, "x5", ts=T, sig="sha256=" + good[7:].upper()), 401)
c("signature of 63 hex characters -> 401", send(A, "x5b", ts=T, sig=good[:-1]), 401)
c("signature of 65 hex characters -> 401", send(A, "x5c", ts=T, sig=good + "0"), 401)
c("signature with a space inside -> 401", send(A, "x5d", ts=T, sig=good[:20] + " " + good[21:]), 401)
c("signature differing only in its last hex digit -> 401", send(A, "x5e", ts=T, sig=good[:-1] + ("0" if good[-1] != "0" else "1")), 401)
c("signature differing only in its first hex digit -> 401", send(A, "x5f", ts=T, sig=good[:7] + ("0" if good[7] != "0" else "1") + good[8:]), 401)
c("signature of another source's secret -> 401", send(A, "x6", secret=SECRETS[B]), 401)
c("signature valid for source B sent to source A's path -> 401", s.req("POST", "/hooks/%s" % A, {"X-Timestamp": str(int(time.time())), "X-Event-Id": "x6b", "X-Signature": sign(SECRETS[B], int(time.time()), b'{"k": "v"}')}, raw_body=b'{"k": "v"}'), 401)
c("signature over a different body -> 401", send(A, "x7", raw=b'{"k": "v"}', sig=sign(SECRETS[A], int(time.time()), b'{"k": "w"}')), 401)
c("signature over the body re-serialised with other whitespace -> 401", send(A, "x7b", raw=b'{"k":"v"}', sig=sign(SECRETS[A], int(time.time()), b'{"k": "v"}')), 401)
c("signature over a different timestamp -> 401", send(A, "x8", ts=int(time.time()), sig=sign(SECRETS[A], int(time.time()) - 5, b'{"k": "v"}')), 401)
c("signature over the body without the timestamp -> 401", send(A, "x9", raw=b'{"k": "v"}', sig="sha256=" + hmac.new(SECRETS[A].encode(), b'{"k": "v"}', hashlib.sha256).hexdigest()), 401)
c("signature using the secret's prefix as key -> 401", send(A, "x9b", secret=SECRETS[A][:-1]), 401)
c("garbage signature -> 401", send(A, "x10", sig="sha256=zz"), 401)
c("an unsigned request with a stale timestamp is 401, not 400", send(A, "x10b", ts=1000, sig="sha256=" + "0" * 64), 401)
c("an unsigned request with a bad event id is 401, not 400", send(A, "bad id", sig="sha256=" + "0" * 64), 401)
c("a 401 never echoes a secret", send(A, "x11", sig="sha256=" + "1" * 64), 401, excludes="Zq")
c("a 401 never echoes the signature or the source", send("nosuch", "x12", sig="sha256=" + "7" * 64), 401, excludes="7777")
after = events() or []
s.note("nothing was stored by any rejected request", len(after) == len(base), "%d -> %d" % (len(base), len(after)))

# 3. replay window and header validation (signed correctly, so they reach those checks)
now = int(time.time())
c("timestamp 400 s in the past -> 400", send(A, "t1", ts=now - 400), 400)
c("timestamp 400 s in the future -> 400", send(A, "t2", ts=now + 400), 400)
c("timestamp 310 s in the past -> 400", send(A, "t2b", ts=now - 310), 400)
c("timestamp 310 s in the future -> 400", send(A, "t2c", ts=now + 310), 400)
c("timestamp 290 s in the past -> accepted", send(A, "t3", ts=now - 290), 202)
c("timestamp 290 s in the future -> accepted", send(A, "t4", ts=now + 290), 202)
c("timestamp 0 -> 400", send(A, "t4b", ts=0), 400)
c("a stale duplicate is 400, not a duplicate answer", send(A, "evt-1", ts=now - 1000), 400)
c("non-integer timestamp (signed) -> 400", send(A, "t5", hdr={"X-Timestamp": "12.5"}, sig=sign(SECRETS[A], "12.5", b'{"k": "v"}')), 400)
c("negative timestamp (signed) -> 400", send(A, "t5b", hdr={"X-Timestamp": "-5"}, sig=sign(SECRETS[A], "-5", b'{"k": "v"}')), 400)
c("timestamp with a plus sign (signed) -> 400", send(A, "t5c", hdr={"X-Timestamp": "+%d" % now}, sig=sign(SECRETS[A], "+%d" % now, b'{"k": "v"}')), 400)
c("a 13-digit timestamp (signed) -> 400", send(A, "t5d", hdr={"X-Timestamp": "1" + "0" * 12}, sig=sign(SECRETS[A], "1" + "0" * 12, b'{"k": "v"}')), 400)
c("absent timestamp with a signature over the empty text -> 400", send(A, "t6", hdr={"X-Timestamp": None}, sig=sign(SECRETS[A], "", b'{"k": "v"}')), 400)
c("absent timestamp with a signature over a real one -> 401", send(A, "t6b", hdr={"X-Timestamp": None}), 401)
c("event id with a space -> 400", send(A, "bad id"), 400)
c("event id with a dot -> 400", send(A, "a.b"), 400)
c("event id of 65 characters -> 400", send(A, "e" * 65), 400)
c("event id of 64 characters -> 202", send(A, "f" * 64), 202)
c("event id of 1 character -> 202", send(A, "7"), 202)
c("missing event id -> 400", send(A, "z", hdr={"X-Event-Id": None}), 400)
c("empty event id -> 400", send(A, "", hdr={"X-Event-Id": ""}), 400)

# 4. body rules (after the signature)
c("array body -> 400", send(A, "b1", raw=b"[1,2]"), 400)
c("string body -> 400", send(A, "b2", raw=b'"hello"'), 400)
c("number body -> 400", send(A, "b2b", raw=b"42"), 400)
c("null body -> 400", send(A, "b2c", raw=b"null"), 400)
c("invalid JSON body (validly signed) -> 400", send(A, "b3", raw=b"{nope"), 400)
c("object followed by garbage -> 400", send(A, "b3b", raw=b'{"a":1} x'), 400)
c("unsigned string body -> 401, not 400", send(A, "b4a", raw=b'"hello"', sig="sha256=" + "0" * 64), 401)
c("unsigned invalid JSON -> 401, not 400", send(A, "b4b", raw=b"{nope", sig="sha256=" + "0" * 64), 401)
c("unknown source with an array body -> 401, not 400", send("nosuch", "b4c", raw=b"[1]"), 401)
c("empty body (validly signed) -> 400", send(A, "b4", raw=b""), 400)
c("nested object with hostile strings accepted", send(A, "b5", {"n": {"x": [1, 2, {"y": "it's ' OR '1'='1 <script>"}], "u": "café 日"}}), 202)
big = b'{"p":"' + b"a" * 300 + b'"}'
c("body over 256 bytes (257) -> 413 even validly signed", send(A, "big0", raw=b'{"p":"' + b"a" * 249 + b'"}'), 413)
c("body of 306 bytes -> 413 even validly signed", send(A, "big1", raw=big), 413)
c("oversize body with a wrong signature -> 413", send(A, "big2", raw=big, sig="sha256=" + "0" * 64), 413)
c("oversize body for an unknown source -> 413", send("nosuch", "big2b", raw=big), 413)
c("body over the server's input buffer (17000 bytes) -> 413", send(A, "big2c", raw=b'{"p":"' + b"a" * 17000 + b'"}'), [413, 0])
c("body of exactly 256 bytes validly signed -> 202", send(A, "big3", raw=b'{"p":"' + b"b" * 248 + b'"}'), 202)
c("body of 255 bytes validly signed -> 202", send(A, "big4", raw=b'{"p":"' + b"b" * 247 + b'"}'), 202)
c("the 256-byte body is stored whole", s.req("GET", "/events?source=%s&limit=100" % A, AD), 200, test=lambda j: any(e["event_id"] == "big3" and e["body"] == {"p": "b" * 248} for e in j["events"]))
c("hostile nested body round-trips", s.req("GET", "/events?source=%s&limit=100" % A, AD), 200, test=lambda j: any(e["event_id"] == "b5" and e["body"]["n"]["x"][2]["y"] == "it's ' OR '1'='1 <script>" and e["body"]["n"]["u"] == "café 日" for e in j["events"]))

# 5. reading events
c("GET /events without token -> 401", s.req("GET", "/events"), 401)
c("GET /events with a wrong token -> 401", s.req("GET", "/events", {"Authorization": "Bearer nope"}), 401, excludes="nope")
c("GET /events with Basic auth -> 401", s.req("GET", "/events", {"Authorization": "Basic YWRtaW4="}), 401)
c("GET /events with lowercase bearer -> 401", s.req("GET", "/events", {"Authorization": "bearer %s" % ADMIN}), 401)
c("GET /events with the bare token and no scheme -> 401", s.req("GET", "/events", {"Authorization": ADMIN}), 401)
c("GET /events with the token plus a character -> 401", s.req("GET", "/events", {"Authorization": "Bearer %sx" % ADMIN}), 401)
c("GET /events with the token minus a character -> 401", s.req("GET", "/events", {"Authorization": "Bearer %s" % ADMIN[:-1]}), 401)
c("GET /events with two spaces before the token -> 401", s.req("GET", "/events", {"Authorization": "Bearer  %s" % ADMIN}), 401)
c("GET /events with the token and a second word -> 401", s.req("GET", "/events", {"Authorization": "Bearer %s extra" % ADMIN}), 401)
c("GET /events with 'Bearer' alone -> 401", s.req("GET", "/events", {"Authorization": "Bearer"}), 401)
c("GET /events with a source secret as token -> 401", s.req("GET", "/events", {"Authorization": "Bearer %s" % SECRETS["c"]}), 401)
c("401 beats a bad query on GET /events", s.req("GET", "/events?source=zzz&limit=0", {"Authorization": "Bearer nope"}), 401)
c("source filter -> only that source", s.req("GET", "/events?source=%s" % B, AD), 200, test=lambda j: j["events"] and all(e["source"] == B for e in j["events"]))
c("a configured source with no events -> 200 and none", s.req("GET", "/events?source=c", AD), 200, test=lambda j: j["events"] == [])
c("unconfigured source -> 400", s.req("GET", "/events?source=gamma", AD), 400)
c("empty source -> 400", s.req("GET", "/events?source=", AD), 400)
c("source in the wrong case -> 400", s.req("GET", "/events?source=HOOK-A", AD), 400)
c("source prefix of a configured one -> 400", s.req("GET", "/events?source=hook", AD), 400)
c("source percent-encoded is not decoded -> 400", s.req("GET", "/events?source=hook%2Da", AD), 400)
c("source SQL injection -> 400", s.req("GET", "/events?source=a'%20OR%20'1'='1", AD), 400)
c("limit=0 -> 400", s.req("GET", "/events?limit=0", AD), 400)
c("limit=101 -> 400", s.req("GET", "/events?limit=101", AD), 400)
c("limit=abc -> 400", s.req("GET", "/events?limit=abc", AD), 400)
c("limit=-1 -> 400", s.req("GET", "/events?limit=-1", AD), 400)
c("limit=1.5 -> 400", s.req("GET", "/events?limit=1.5", AD), 400)
c("limit=05 -> 400", s.req("GET", "/events?limit=05", AD), 400)
c("limit= (empty) -> 400", s.req("GET", "/events?limit=", AD), 400)
c("limit=100 -> 200", s.req("GET", "/events?limit=100", AD), 200)
c("limit=1 -> exactly the lowest id", s.req("GET", "/events?limit=1", AD), 200, test=lambda j: len(j["events"]) == 1 and j["events"][0]["id"] == id1)
c("limit applies after the source filter", s.req("GET", "/events?source=%s&limit=2" % B, AD), 200, test=lambda j: len(j["events"]) == 1 and j["events"][0]["source"] == B)
c("default limit is 50 and the list is complete below it", s.req("GET", "/events", AD), 200, test=lambda j: len(j["events"]) >= 10 and len(j["events"]) <= 50)
c("no response contains a secret or the admin token", s.req("GET", "/events", AD), 200, excludes="Zq")

# 6. routing
c("unknown path -> 404", s.req("GET", "/nothing"), 404)
c("/hooks/ with no source -> 404", s.req("POST", "/hooks/", raw_body=b"{}"), 404)
c("/hooks/a/b -> 404", s.req("POST", "/hooks/%s/x" % A, raw_body=b"{}"), 404)
c("GET /hooks/hook-a -> 405", s.req("GET", "/hooks/%s" % A), 405)
c("PUT /hooks/hook-a -> 405", s.req("PUT", "/hooks/%s" % A, raw_body=b"{}"), 405)
c("POST /events -> 405", s.req("POST", "/events", AD, raw_body=b"{}"), 405)
c("DELETE /events -> 405", s.req("DELETE", "/events", AD), 405)

# 7. capacity: 1000 events in all, then 503; a duplicate is still 200
code, n, last_id, first_fill = 202, 0, None, None
while code == 202 and n < 1100:
    r = send_keep(B, "cap-%d" % n, {"n": n})
    code = r[0]
    if code == 202:
        last_id = (s.j(r[1]) or {}).get("id")
        first_fill = first_fill or last_id
    n += 1
s.note("the 1001st new event -> 503", code == 503, "last status %s after %d requests" % (code, n))
s.note("exactly 1000 events were stored", last_id == 1000, "last accepted id %s" % last_id)
c("a duplicate of an old event is 200 while the store is full", send(A, "evt-1", {"a": 1}), 200, test=lambda j: j["id"] == id1)
c("a new event is still 503 while the store is full", send(A, "cap-new", {"n": 1}), 503)
c("a rejected request is still 401 while the store is full", send(A, "cap-bad", sig="sha256=" + "0" * 64), 401)
c("the oldest events are still readable while the store is full", s.req("GET", "/events?limit=1", AD), 200, test=lambda j: j["events"][0]["id"] == id1)
c("default page is 50 events once more exist", s.req("GET", "/events", AD), 200, test=lambda j: len(j["events"]) == 50)
c("limit=100 returns 100 events, ids ascending, within the answer size", s.req("GET", "/events?limit=100", AD), 200, test=lambda j: len(j["events"]) == 100 and [e["id"] for e in j["events"]] == sorted(e["id"] for e in j["events"]))
c("still alive after all of the above", s.req("GET", "/events", AD), 200)
s.finish()
