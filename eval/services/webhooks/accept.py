#!/usr/bin/env python3
"""usage: accept.py BINARY PROJECT.cho -- the acceptance scenarios of the `webhooks` brief (the builder sees these failures)."""
import sys, os, hmac, hashlib, json, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
from svc import Svc

SECRETS = {"alpha": "s3cret-alpha", "beta": "s3cret-beta"}
ADMIN = "adm-token-xyz"
s = Svc(sys.argv[1], ["--secrets", ",".join("%s:%s" % kv for kv in SECRETS.items()), "--admin-token", ADMIN], 18813, label="ACCEPTANCE")
if os.environ.get("SVC_AUTHORITY_OK") == "0":
    s.note("declared authority is only what a server needs", False, os.environ.get("SVC_AUTHORITY_WHY", ""))
if not s.up:
    s.note("the service starts and listens", False, "did not start")
    s.finish()
c = s.check
T0 = time.time()
_req = s.req
def _guarded(*a, **k):
    # every script ends in well under a minute, even if the service hangs
    return (0, "<script deadline>") if time.time() - T0 > 28 else _req(*a, **k)
s.req = _guarded

def sign(secret, ts, body):
    return "sha256=" + hmac.new(secret.encode(), ("%s." % ts).encode() + body, hashlib.sha256).hexdigest()

def send(source, event_id, obj=None, ts=None, secret=None, raw=None, sig=None, hdr=None):
    body = raw if raw is not None else json.dumps(obj if obj is not None else {"k": "v"}).encode()
    ts = int(time.time()) if ts is None else ts
    h = {"X-Timestamp": str(ts), "X-Event-Id": event_id}
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

# delivery and dedupe
r = c("valid delivery -> 202, duplicate false, integer id", send("alpha", "evt-1", {"a": 1}), 202, test=lambda j: j["duplicate"] is False and isinstance(j["id"], int))
id1 = (s.j(r[1]) or {}).get("id")
c("same source and event id again -> 200 duplicate with the original id", send("alpha", "evt-1", {"a": 1}), 200, test=lambda j: j["duplicate"] is True and j["id"] == id1)
c("same event id from another source -> 202 (independent)", send("beta", "evt-1", {"b": 2}), 202, test=lambda j: j["duplicate"] is False and j["id"] != id1)
ev = events()
s.note("exactly 2 events stored (the duplicate was not stored again)", ev is not None and len(ev) == 2, str(None if ev is None else len(ev)))
s.note("events come in ascending id order with source, event_id, received_at, body",
       ev is not None and len(ev) == 2 and ev[0]["id"] < ev[1]["id"] and ev[0]["source"] == "alpha" and ev[0]["event_id"] == "evt-1"
       and ev[0]["body"] == {"a": 1} and isinstance(ev[0]["received_at"], int) and abs(ev[0]["received_at"] - time.time()) < 30, str(ev))

# signature
base = events() or []
r_bad = c("wrong signature -> 401", send("alpha", "s1", sig="sha256=" + "0" * 64), 401)
r_unk = c("unknown source -> 401", send("nosuch", "s2", secret="whatever"), 401)
s.note("unknown source and wrong signature answer identically", r_bad == r_unk, "%s vs %s" % (r_bad, r_unk))
c("missing signature -> 401", send("alpha", "s3", hdr={"X-Signature": None}), 401)
c("signature without the sha256= prefix -> 401", send("alpha", "s4", sig=sign(SECRETS["alpha"], int(time.time()), b'{"k": "v"}')[7:]), 401)
c("uppercase hex signature -> 401", send("alpha", "s5", sig="sha256=" + sign(SECRETS["alpha"], int(time.time()), b'{"k": "v"}')[7:].upper()), 401)
c("signature made with another source's secret -> 401", send("alpha", "s6", secret=SECRETS["beta"]), 401)
c("signature over a different body -> 401", send("alpha", "s7", raw=b'{"k": "v"}', sig=sign(SECRETS["alpha"], int(time.time()), b'{"k": "w"}')), 401)
c("401 never contains a secret", send("alpha", "s8", sig="sha256=" + "1" * 64), 401, excludes="s3cret")
s.note("rejected requests stored nothing", len(events() or []) == len(base), "%d -> %d" % (len(base), len(events() or [])))

# replay window and headers
now = int(time.time())
c("timestamp 400 s in the past -> 400", send("alpha", "t1", ts=now - 400), 400)
c("timestamp 400 s in the future -> 400", send("alpha", "t2", ts=now + 400), 400)
c("timestamp 250 s in the past -> 202", send("alpha", "t3", ts=now - 250), 202)
c("timestamp 250 s in the future -> 202", send("alpha", "t4", ts=now + 250), 202)
c("validly signed non-integer timestamp -> 400", send("alpha", "t5", hdr={"X-Timestamp": "yesterday"}, sig=sign(SECRETS["alpha"], "yesterday", b'{"k": "v"}')), 400)
c("validly signed absent timestamp -> 400", send("alpha", "t6", hdr={"X-Timestamp": None}, sig=sign(SECRETS["alpha"], "", b'{"k": "v"}')), 400)
c("event id with a space -> 400", send("alpha", "bad id"), 400)
c("event id of 65 characters -> 400", send("alpha", "e" * 65), 400)
c("event id of 64 characters -> 202", send("alpha", "e" * 64), 202)
c("missing event id -> 400", send("alpha", "z", hdr={"X-Event-Id": None}), 400)

# body rules
c("array body (signed) -> 400", send("alpha", "b1", raw=b"[1,2]"), 400)
c("invalid JSON body (signed) -> 400", send("alpha", "b2", raw=b"{nope"), 400)
c("empty body (signed) -> 400", send("alpha", "b3", raw=b""), 400)
c("unsigned array body -> 401, not 400", send("alpha", "b4", raw=b"[1]", sig="sha256=" + "0" * 64), 401)
c("body of 257 bytes -> 413", send("alpha", "big1", raw=b'{"p":"' + b"a" * 249 + b'"}'), 413)
c("body of exactly 256 bytes -> 202", send("alpha", "big2", raw=b'{"p":"' + b"a" * 248 + b'"}'), 202)
c("body of 20000 bytes -> 413", send("alpha", "big3", raw=b'{"p":"' + b"a" * 19990 + b'"}'), [413, 0])

# reading
c("GET /events without token -> 401", s.req("GET", "/events"), 401)
c("GET /events with a wrong token -> 401", s.req("GET", "/events", {"Authorization": "Bearer nope"}), 401, excludes="nope")
c("GET /events with Basic auth -> 401", s.req("GET", "/events", {"Authorization": "Basic YWRtaW4="}), 401)
c("401 on GET /events even with a bad query", s.req("GET", "/events?limit=0"), 401)
c("source filter returns only that source", s.req("GET", "/events?source=beta", AD), 200, test=lambda j: j["events"] and all(e["source"] == "beta" for e in j["events"]))
c("unconfigured source -> 400", s.req("GET", "/events?source=gamma", AD), 400)
c("source injection -> 400", s.req("GET", "/events?source=a'%20OR%20'1'='1", AD), 400)
c("limit=0 -> 400", s.req("GET", "/events?limit=0", AD), 400)
c("limit=101 -> 400", s.req("GET", "/events?limit=101", AD), 400)
c("limit=abc -> 400", s.req("GET", "/events?limit=abc", AD), 400)
c("limit=2 -> exactly the first 2 events", s.req("GET", "/events?limit=2", AD), 200, test=lambda j: len(j["events"]) == 2 and j["events"][0]["id"] < j["events"][1]["id"])
c("no response contains a secret or the admin token", s.req("GET", "/events", AD), 200, excludes="s3cret")

# routing
c("unknown path -> 404", s.req("GET", "/nothing"), 404)
c("GET /hooks/alpha -> 405", s.req("GET", "/hooks/alpha"), 405)
c("POST /events -> 405", s.req("POST", "/events", AD, raw_body=b"{}"), 405)

# capacity: the store holds 1000 events, the 1001st new one is 503
code, n, last_id = 202, 0, None
while code == 202 and n < 1100:
    r = send_keep("beta", "fill-%d" % n, {"n": n})
    code = r[0]
    if code == 202: last_id = (s.j(r[1]) or {}).get("id")
    n += 1
s.note("the 1001st new event -> 503", code == 503, "last status %s after %d requests" % (code, n))
s.note("the store held exactly 1000 events (last accepted id 1000)", last_id == 1000, "last accepted id %s" % last_id)
c("a duplicate is still 200 when the store is full", send("beta", "fill-0", {"n": 0}), 200, test=lambda j: j["duplicate"] is True)
c("still alive after all of the above", s.req("GET", "/events", AD), 200)
s.finish()
