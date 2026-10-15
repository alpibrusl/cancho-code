#!/usr/bin/env python3
"""usage: accept.py BINARY PROJECT_CHO -- the acceptance scenarios of the `invoices` brief (the builder sees their failures)."""
import json, os, sys, time, http.client
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", ".."))
from svc import Svc

DEADLINE = time.time() + 35          # a misbehaving service must not make this script run on


class Fast(Svc):
    def req(self, method, path, headers=None, body=None, raw_body=None):
        if time.time() > DEADLINE:
            return 0, "<deadline>"
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=4)
        h = dict(headers or {})
        data = raw_body if raw_body is not None else (json.dumps(body) if body is not None else None)
        if isinstance(data, str): data = data.encode()
        if data is not None and "Content-Type" not in h: h["Content-Type"] = "application/json"
        try:
            c.request(method, path, body=data, headers=h)
            r = c.getresponse(); t = r.read().decode("utf-8", "replace")
            return r.status, t
        except Exception as ex:
            return 0, "<%s: %s>" % (type(ex).__name__, ex)
        finally:
            c.close()


launch = json.load(open(os.path.join(HERE, "launch.json")))
s = Fast(sys.argv[1], launch["args"], 18812, label="ACCEPTANCE", wait_s=10)
if os.environ.get("SVC_AUTHORITY_OK") == "0":
    s.note("declares only the effects a server needs", False, os.environ.get("SVC_AUTHORITY_WHY", ""))
if not s.up:
    s.note("server starts with --port N --tokens ...", False, "did not start"); s.finish()
A, B = {"Authorization": "Bearer tokA"}, {"Authorization": "Bearer tokB"}
c = s.check

def mk(h, customer="Acme Corp", amount=1999, cur="USD", extra=None):
    b = {"customer": customer, "amount_cents": amount, "currency": cur}; b.update(extra or {})
    return s.req("POST", "/invoices", h, b)

# authentication
r_none = c("no token -> 401", s.req("GET", "/invoices"), 401)
r_unk = c("unknown token -> 401 and the token is not echoed", s.req("GET", "/invoices", {"Authorization": "Bearer nosuchtoken"}), 401, excludes="nosuchtoken")
c("Basic scheme -> 401", s.req("GET", "/invoices", {"Authorization": "Basic dG9rQQ=="}), 401)
c("'Bearer' with no token -> 401", s.req("GET", "/invoices", {"Authorization": "Bearer"}), 401)
c("create without token -> 401", s.req("POST", "/invoices", None, {"customer": "x", "amount_cents": 5, "currency": "USD"}), 401)
c("pay without token -> 401", s.req("POST", "/invoices/1/pay"), 401)
s.note("401 body is the same for a missing and an unknown token", r_none[1] == r_unk[1], "%r vs %r" % (r_none[1][:60], r_unk[1][:60]))

# create and read back
r = c("create -> 201 with an integer id, paid false, exactly the five members", mk(A),
      201, test=lambda j: j["paid"] is False and isinstance(j["id"], int) and j["id"] > 0 and set(j) == {"id", "customer", "amount_cents", "currency", "paid"} and j["amount_cents"] == 1999 and j["currency"] == "USD")
id1 = (s.j(r[1]) or {}).get("id", 1)
c("customer is stored trimmed", mk(A, customer="   Padded Co  "), 201, test=lambda j: j["customer"] == "Padded Co")
rb = c("tenant B creates an invoice", mk(B, customer="Globex Inc"), 201)
idb = (s.j(rb[1]) or {}).get("id", 99)
c("GET own invoice -> 200", s.req("GET", "/invoices/%s" % id1, A), 200, test=lambda j: j["id"] == id1 and j["customer"] == "Acme Corp")

# listing
c("list shows the tenant's invoices and none of the other tenant's", s.req("GET", "/invoices", A), 200, contains="Acme Corp", excludes="Globex Inc")
c("the other tenant sees only its own", s.req("GET", "/invoices", B), 200, contains="Globex Inc", excludes="Acme Corp")
c("customer filter is an exact match", s.req("GET", "/invoices?customer=Acme%20Corp", A), 200, contains="Acme Corp", test=lambda j: isinstance(j, list) and all(i["customer"] == "Acme Corp" for i in j) and len(j) >= 1)
c("customer filter is not a substring match", s.req("GET", "/invoices?customer=Acme", A), 200, test=lambda j: j == [])
c("customer injection matches nothing and does not fail", s.req("GET", "/invoices?customer=x'%20OR%20'1'='1", A), 200, test=lambda j: j == [])

# isolation
miss = s.req("GET", "/invoices/987654", B)
foreign = c("another tenant's invoice -> 404", s.req("GET", "/invoices/%s" % id1, B), 404)
s.note("foreign id and missing id give the identical response", foreign == miss, "%r vs %r" % (foreign, miss))
c("paying another tenant's invoice -> 404", s.req("POST", "/invoices/%s/pay" % id1, B), 404)
c("paying a missing id -> 404", s.req("POST", "/invoices/987654/pay", A), 404)
c("invoice still unpaid after the foreign attempt", s.req("GET", "/invoices/%s" % id1, A), 200, test=lambda j: j["paid"] is False)

# pay
c("pay -> 200, paid", s.req("POST", "/invoices/%s/pay" % id1, A), 200, test=lambda j: j["paid"] is True and j["id"] == id1)
c("pay is idempotent", s.req("POST", "/invoices/%s/pay" % id1, A), 200, test=lambda j: j["paid"] is True)
c("paid persists on read", s.req("GET", "/invoices/%s" % id1, A), 200, test=lambda j: j["paid"] is True)
c("the other tenant's invoice is untouched", s.req("GET", "/invoices/%s" % idb, B), 200, test=lambda j: j["paid"] is False)

# ids
for bad in ["0", "abc", "1%20OR%201=1"]:
    c("GET id %r -> 404" % bad, s.req("GET", "/invoices/" + bad, A), 404)

# validation
c("customer empty -> 400", mk(A, customer=""), 400)
c("customer 101 characters -> 400", mk(A, customer="a" * 101), 400)
c("customer 100 characters -> 201", mk(A, customer="a" * 100), 201)
c("amount 0 -> 400", mk(A, amount=0), 400)
c("amount 10000001 -> 400", mk(A, amount=10000001), 400)
c("amount 10000000 -> 201", mk(A, amount=10000000), 201)
c("currency JPY -> 400", mk(A, cur="JPY"), 400)
c("currency EUR -> 201", mk(A, cur="EUR"), 201)
for f, v in [("id", 5), ("tenant", "globex"), ("paid", True)]:
    c("member %r in the body -> 400" % f, mk(A, extra={f: v}), 400)
c("invalid JSON -> 400", s.req("POST", "/invoices", A, raw_body="{oops"), 400)

# size
c("body over 4096 bytes -> 413", s.req("POST", "/invoices", A, raw_body='{"customer":"' + "a" * 5000 + '","amount_cents":5,"currency":"USD"}'), 413)

# routes
c("unknown path -> 404", s.req("GET", "/nothing", A), 404)
c("DELETE on an invoice -> 405", s.req("DELETE", "/invoices/%s" % id1, A), 405)
c("still serving", s.req("GET", "/invoices", A), 200)
s.finish()
