#!/usr/bin/env python3
"""usage: attack.py BINARY PROJECT_CHO -- independent black-box attack on a built cancho `invoices` service (ported from lex-code backlog/items/10-invoices)."""
import json, os, socket, sys, time, http.client
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", ".."))
from svc import Svc

DEADLINE = time.time() + 38          # every script finishes well inside 60 s, however the service misbehaves


class Fast(Svc):
    def req(self, method, path, headers=None, body=None, raw_body=None):
        if time.time() > DEADLINE:
            return 0, "<deadline>"
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=4)
        h = dict(headers or {})
        data = raw_body if raw_body is not None else (json.dumps(body) if body is not None else None)
        if isinstance(data, str): data = data.encode("utf-8")
        if data is not None and "Content-Type" not in h: h["Content-Type"] = "application/json"
        try:
            c.request(method, path, body=data, headers=h)
            r = c.getresponse(); t = r.read().decode("utf-8", "replace")
            return r.status, t
        except Exception as ex:
            return 0, "<%s: %s>" % (type(ex).__name__, ex)
        finally:
            c.close()

    def big_post(self, token, nbytes):
        """POST /invoices with a body of nbytes (sent whole even if the server answers early); (status, text)."""
        if time.time() > DEADLINE:
            return 0, "<deadline>"
        body = b'{"customer":"' + b"a" * nbytes + b'","amount_cents":5,"currency":"USD"}'
        head = ("POST /invoices HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n" % (token, len(body))).encode()
        try:
            c = socket.create_connection(("127.0.0.1", self.port), 4); c.settimeout(4)
            try: c.sendall(head + body)
            except OSError: pass
            data = b""
            try:
                while b"\r\n\r\n" not in data:
                    chunk = c.recv(4096)
                    if not chunk: break
                    data += chunk
            except OSError: pass
            c.close()
            line = data.split(b"\r\n", 1)[0].decode("latin-1")
            return (int(line.split()[1]) if line.startswith("HTTP/") else 0), line
        except OSError as ex:
            return 0, "<%s>" % ex


launch = json.load(open(os.path.join(HERE, "launch.json")))
s = Fast(sys.argv[1], launch["args"], 8812, label="ATTACK", wait_s=10)
if os.environ.get("SVC_AUTHORITY_OK") == "0":
    s.note("declares only the effects a server needs", False, os.environ.get("SVC_AUTHORITY_WHY", ""))
if not s.up:
    s.note("server starts", False, "did not start"); s.finish()
A, B, C = {"Authorization": "Bearer tokA"}, {"Authorization": "Bearer tokB"}, {"Authorization": "Bearer tokC"}
c = s.check

def mk(h, customer="initech-ltd", amount=1000, cur="USD", extra=None):
    b = {"customer": customer, "amount_cents": amount, "currency": cur}; b.update(extra or {})
    return s.req("POST", "/invoices", h, b)

def inv(r):
    return s.j(r[1]) or {}

# 1. authentication
r_none = c("no token -> 401", s.req("GET", "/invoices"), 401)
r_unk = c("unknown token -> 401, token not echoed", s.req("GET", "/invoices", {"Authorization": "Bearer zz-secret-guess"}), 401, excludes="zz-secret-guess")
c("Basic -> 401", s.req("GET", "/invoices", {"Authorization": "Basic dG9rQQ=="}), 401)
c("scheme only -> 401", s.req("GET", "/invoices", {"Authorization": "Bearer"}), 401)
c("scheme and empty token -> 401", s.req("GET", "/invoices", {"Authorization": "Bearer "}), 401)
c("token that is a prefix of a real one -> 401", s.req("GET", "/invoices", {"Authorization": "Bearer tok"}), 401)
c("real token plus extra characters -> 401", s.req("GET", "/invoices", {"Authorization": "Bearer tokAA"}), 401)
c("two tokens joined by a comma -> 401", s.req("GET", "/invoices", {"Authorization": "Bearer tokA,tokB"}), 401)
c("tenant name as a token -> 401", s.req("GET", "/invoices", {"Authorization": "Bearer acme"}), 401)
c("token:tenant pair as a token -> 401", s.req("GET", "/invoices", {"Authorization": "Bearer tokA:acme"}), 401)
c("two spaces after Bearer -> 401", s.req("GET", "/invoices", {"Authorization": "Bearer  tokA"}), 401)
c("token that is 3000 bytes long -> 401, no crash", s.req("GET", "/invoices", {"Authorization": "Bearer " + "q" * 3000}), 401)
c("trailing space must not crash (200 or 401)", s.req("GET", "/invoices", {"Authorization": "Bearer tokA "}), [200, 401])
c("POST create without token -> 401", s.req("POST", "/invoices", None, {"customer": "x", "amount_cents": 5, "currency": "USD"}), 401)
c("pay without token -> 401", s.req("POST", "/invoices/1/pay"), 401)
c("GET one without token -> 401", s.req("GET", "/invoices/1"), 401)
c("no token and a bad id -> 401 (authentication comes first)", s.req("GET", "/invoices/abc"), 401)
c("no token and a bad body -> 401", s.req("POST", "/invoices", None, raw_body="{nope"), 401)
s.note("missing and unknown token give the identical 401 body", r_none[1] == r_unk[1], "%r vs %r" % (r_none[1][:50], r_unk[1][:50]))

# 2. create and read back
r = c("create -> 201, unpaid, with an id", mk(A, customer="initech-ltd"), 201, test=lambda j: j["paid"] is False and isinstance(j["id"], int) and j["id"] >= 1)
id1 = inv(r).get("id", 1)
r2 = c("a second create gets a larger id", mk(A, customer="initech-two"), 201, test=lambda j: j["id"] > id1)
c("create response has exactly five members and no tenant", mk(A), 201, test=lambda j: sorted(j) == ["amount_cents", "currency", "customer", "id", "paid"], excludes="acme")
c("create never echoes a token", mk(A), 201, excludes="tokA")
rb = c("B creates its own invoice (secret customer name)", mk(B, customer="zzq-secret-b"), 201)
idb = inv(rb).get("id", 99)
rc = c("C (same tenant as A) creates an invoice", mk(C, customer="from-token-c"), 201)
idc = inv(rc).get("id", 98)
c("GET own invoice -> 200", s.req("GET", "/invoices/%d" % id1, A), 200, contains="initech-ltd", test=lambda j: j["amount_cents"] == 1000 and j["currency"] == "USD")
c("GET with a query string on the id route -> 200", s.req("GET", "/invoices/%d?x=1" % id1, A), 200, test=lambda j: j["id"] == id1)

# 3. listing
c("bare list -> 200 array of the tenant's invoices", s.req("GET", "/invoices", A), 200, contains="initech-ltd", excludes="zzq-secret-b", test=lambda j: isinstance(j, list))
c("list shows only the caller's tenant", s.req("GET", "/invoices", B), 200, contains="zzq-secret-b", excludes="initech")
c("list is in ascending id order", s.req("GET", "/invoices", A), 200, test=lambda j: [i["id"] for i in j] == sorted(i["id"] for i in j))
c("two tokens of one tenant see the same invoices", s.req("GET", "/invoices", C), 200, contains="initech-ltd", test=lambda j: any(i["customer"] == "from-token-c" for i in j))
c("A sees the invoice created through C's token", s.req("GET", "/invoices/%d" % idc, A), 200, contains="from-token-c")
c("C can pay what A created", s.req("POST", "/invoices/%d/pay" % id1, C), 200, test=lambda j: j["paid"] is True)
c("customer filter exact match", s.req("GET", "/invoices?customer=initech-ltd", A), 200, contains="initech-ltd", test=lambda j: all(i["customer"] == "initech-ltd" for i in j) and len(j) >= 1)
c("customer filter is exact (no substring match)", s.req("GET", "/invoices?customer=initech", A), 200, test=lambda j: j == [])
c("customer filter is case sensitive", s.req("GET", "/invoices?customer=INITECH-LTD", A), 200, test=lambda j: j == [])
c("other parameters are ignored", s.req("GET", "/invoices?foo=bar&customer=initech-ltd&x=1", A), 200, contains="initech-ltd")
c("customer SQL injection matches nothing and never errors", s.req("GET", "/invoices?customer=x'%20OR%20'1'='1", A), 200, test=lambda j: j == [])
c("customer UNION injection returns nothing", s.req("GET", "/invoices?customer=x'%20UNION%20SELECT%20*%20FROM%20invoices--", A), [200, 400], excludes="zzq-secret-b")
c("customer wildcard is literal", s.req("GET", "/invoices?customer=%25", A), 200, test=lambda j: j == [])
c("customer=' OR 1=1 --", s.req("GET", "/invoices?customer=%27%20OR%201%3D1%20--", A), 200, test=lambda j: j == [])
c("filter by another tenant's customer name shows nothing", s.req("GET", "/invoices?customer=zzq-secret-b", A), 200, excludes="zzq-secret-b")
c("empty customer parameter lists nothing", s.req("GET", "/invoices?customer=", A), 200, test=lambda j: j == [])
c("invalid percent-encoding in the filter -> 400", s.req("GET", "/invoices?customer=%zz", A), 400)
c("filter longer than 1024 bytes -> 400", s.req("GET", "/invoices?customer=" + "a" * 1100, A), 400)

# 4. isolation (the original false-success finding lives here)
miss = s.req("GET", "/invoices/999999", B)
c("B cannot read A's invoice: 404", s.req("GET", "/invoices/%d" % id1, B), 404)
fr = s.req("GET", "/invoices/%d" % id1, B)
s.note("foreign id and missing id give the identical response", fr == miss, "%s vs %s" % (fr, miss))
prf, prm = s.req("POST", "/invoices/%d/pay" % idb, A), s.req("POST", "/invoices/999999/pay", A)
c("A cannot pay B's invoice: 404", prf, 404)
s.note("foreign pay and missing pay give the identical response", prf == prm, "%s vs %s" % (prf, prm))
c("pay a missing id: 404 (not a false 200)", prm, 404)
c("B's invoice still unpaid after A's attempt", s.req("GET", "/invoices/%d" % idb, B), 200, test=lambda j: j["paid"] is False)
c("B cannot pay A's second invoice: 404", s.req("POST", "/invoices/%d/pay" % inv(r2).get("id", 2), B), 404)
c("foreign id with a query string still 404", s.req("GET", "/invoices/%d?customer=initech-ltd" % id1, B), 404)

# 5. pay
c("pay again is idempotent -> 200", s.req("POST", "/invoices/%d/pay" % id1, A), 200, test=lambda j: j["paid"] is True and j["id"] == id1)
c("paid state persists on read", s.req("GET", "/invoices/%d" % id1, A), 200, test=lambda j: j["paid"] is True)
c("paid state shows in the list", s.req("GET", "/invoices?customer=initech-ltd", A), 200, test=lambda j: any(i["id"] == id1 and i["paid"] for i in j))
c("pay ignores a request body", s.req("POST", "/invoices/%d/pay" % inv(r2).get("id", 2), A, {"paid": False, "customer": "hijack"}), 200, test=lambda j: j["paid"] is True and j["customer"] == "initech-two")
c("B's invoice is not affected by A's pay", s.req("GET", "/invoices/%d" % idb, B), 200, test=lambda j: j["paid"] is False)

# 6. path ids
for bad in ["0", "-1", "abc", "007", "1%20OR%201=1", "..%2Fetc%2Fpasswd", "99999999999999999999", "1234567890", "1.5", "%27", "+1", "1e2", "0x1"]:
    c("GET path id %r -> 404" % bad, s.req("GET", "/invoices/" + bad, A), 404)
    c("pay path id %r -> 404" % bad, s.req("POST", "/invoices/%s/pay" % bad, A), 404)
c("leading zero on an existing own id -> 404", s.req("GET", "/invoices/0%d" % id1, A), 404)
c("leading zero on pay of an existing own id -> 404", s.req("POST", "/invoices/00%d/pay" % idc, C), 404)
c("literal ../ in the path -> 404", s.req("GET", "/invoices/../etc/passwd", A), 404)
c("empty id (//pay) -> 404", s.req("POST", "/invoices//pay", A), 404)
c("trailing slash on /invoices/ -> 404", s.req("GET", "/invoices/", A), 404)
c("/invoices/N/pay/ -> 404", s.req("POST", "/invoices/%d/pay/" % id1, A), 404)

# 7. validation
c("customer empty -> 400", mk(A, customer=""), 400)
c("customer whitespace only (tabs, newlines) -> 400", mk(A, customer=" \t\n\r "), 400)
c("customer 101 chars -> 400", mk(A, customer="a" * 101), 400)
c("customer 100 chars -> 201", mk(A, customer="a" * 100), 201)
c("customer padded to 100 after trim -> 201, stored trimmed", mk(A, customer="  " + "b" * 100 + "  "), 201, test=lambda j: j["customer"] == "b" * 100)
c("customer 101 after trim -> 400", mk(A, customer="  " + "b" * 101 + "  "), 400)
c("customer of 100 two-byte characters (200 bytes) -> 201", mk(A, customer="é" * 100), 201, test=lambda j: j["customer"] == "é" * 100)
c("customer of 101 two-byte characters -> 400", mk(A, customer="é" * 101), 400)
c("customer of 100 four-byte characters -> 201", mk(A, customer="😀" * 100), 201)
c("customer with JSON escapes is decoded and stored", s.req("POST", "/invoices", A, raw_body='{"customer":"caf\\u00e9 \\"q\\" \\\\ x","amount_cents":7,"currency":"EUR"}'), 201, test=lambda j: j["customer"] == 'café "q" \\ x')
c("customer escape only whitespace (\\u0020) -> 400", s.req("POST", "/invoices", A, raw_body='{"customer":"\\u0020\\u0020","amount_cents":7,"currency":"EUR"}'), 400)
c("customer invalid UTF-8 -> 400", s.req("POST", "/invoices", A, raw_body=b'{"customer":"a\xff","amount_cents":7,"currency":"EUR"}'), 400)
c("customer a number -> 400", mk(A, customer=5), 400)
c("customer null -> 400", mk(A, customer=None), 400)
c("amount 0 -> 400", mk(A, amount=0), 400)
c("amount -5 -> 400", mk(A, amount=-5), 400)
c("amount 10000001 -> 400", mk(A, amount=10000001), 400)
c("amount 10000000 -> 201", mk(A, amount=10000000), 201)
c("amount 1 -> 201", mk(A, amount=1), 201)
c("amount float -> 400", mk(A, amount=1.5), 400)
c("amount 5.0 -> 400", s.req("POST", "/invoices", A, raw_body='{"customer":"x","amount_cents":5.0,"currency":"USD"}'), 400)
c("amount 1e3 -> 400", s.req("POST", "/invoices", A, raw_body='{"customer":"x","amount_cents":1e3,"currency":"USD"}'), 400)
c("amount string -> 400", mk(A, amount="5"), 400)
c("amount null -> 400", mk(A, amount=None), 400)
c("amount huge (20 digits) -> 400", s.req("POST", "/invoices", A, raw_body='{"customer":"x","amount_cents":99999999999999999999,"currency":"USD"}'), 400)
for cur in ["JPY", "usd", "Usd", "", "EURO", " USD", "USD "]: c("currency %r -> 400" % cur, mk(A, cur=cur), 400)
c("currency a number -> 400", mk(A, cur=1), 400)
for cur in ["USD", "EUR", "GBP"]: c("currency %s -> 201" % cur, mk(A, cur=cur), 201, test=lambda j, cur=cur: j["currency"] == cur)
for f, v in [("id", 5), ("tenant", "globex"), ("tenant_id", 2), ("paid", True), ("extra", 1), ("owner", "globex")]:
    c("unknown/forbidden member %r -> 400" % f, mk(A, extra={f: v}), 400)
c("missing customer -> 400", s.req("POST", "/invoices", A, {"amount_cents": 5, "currency": "USD"}), 400)
c("missing amount -> 400", s.req("POST", "/invoices", A, {"customer": "x", "currency": "USD"}), 400)
c("missing currency -> 400", s.req("POST", "/invoices", A, {"customer": "x", "amount_cents": 5}), 400)
c("duplicate member -> 400", s.req("POST", "/invoices", A, raw_body='{"customer":"a","customer":"b","amount_cents":5,"currency":"USD"}'), 400)
c("duplicate member with one missing -> 400", s.req("POST", "/invoices", A, raw_body='{"customer":"a","customer":"b","amount_cents":5}'), 400)
c("invalid JSON -> 400", s.req("POST", "/invoices", A, raw_body="{not json"), 400)
c("truncated JSON -> 400", s.req("POST", "/invoices", A, raw_body='{"customer":"a","amount_cents":5,"currency":"USD"'), 400)
c("trailing garbage after the object -> 400", s.req("POST", "/invoices", A, raw_body='{"customer":"a","amount_cents":5,"currency":"USD"} x'), 400)
c("JSON array body -> 400", s.req("POST", "/invoices", A, raw_body="[1]"), 400)
c("JSON string body -> 400", s.req("POST", "/invoices", A, raw_body='"hello"'), 400)
c("empty body -> 400", s.req("POST", "/invoices", A, raw_body=""), 400)
c("customer with quotes stored verbatim", mk(A, customer="O'Brien \"x\" ' OR '1'='1"), 201, test=lambda j: j["customer"] == "O'Brien \"x\" ' OR '1'='1")
c("a rejected body creates nothing", s.req("GET", "/invoices?customer=hijack", A), 200, test=lambda j: j == [])

# 8. size limit
def padded(n):
    core = '{"customer":"edge","amount_cents":5,"currency":"USD"}'
    return core + " " * (n - len(core))
c("body of exactly 4096 bytes is accepted", s.req("POST", "/invoices", A, raw_body=padded(4096)), 201)
c("body of 4097 bytes -> 413", s.req("POST", "/invoices", A, raw_body=padded(4097)), 413)
c("oversize body that is not JSON gets 413, not 400 (rejected before parsing)", s.req("POST", "/invoices", A, raw_body="{" * 5000), 413)
c("body of 5000 bytes -> 413", s.big_post("tokA", 5000), 413)
c("body of 12000 bytes -> 413", s.big_post("tokA", 12000), 413)
c("body of 200000 bytes -> 413", s.big_post("tokA", 200000), 413)
c("still alive after the oversize bodies", s.req("GET", "/invoices", A), 200)

# 9. robustness
c("unknown route -> 404", s.req("GET", "/nothing", A), 404)
c("unknown route without a token -> 404", s.req("GET", "/nothing"), 404)
c("root -> 404", s.req("GET", "/", A), 404)
c("DELETE /invoices/N -> 405", s.req("DELETE", "/invoices/%d" % id1, A), 405)
c("PUT /invoices -> 405", s.req("PUT", "/invoices", A, {"customer": "x"}), 405)
c("GET /invoices/N/pay -> 405", s.req("GET", "/invoices/%d/pay" % id1, A), 405)
c("POST /invoices/N -> 405", s.req("POST", "/invoices/%d" % id1, A, {}), 405)
c("errors are JSON objects with an error member", s.req("GET", "/invoices/999999", A), 404, test=lambda j: isinstance(j.get("error"), str))

# 10. capacity: at least 1000 invoices
made = 0
for i in range(1000):
    st, _ = mk(C, customer="bulk-%d" % i, amount=i + 1)
    made += st == 201
    if st != 201: break
s.note("1000 more invoices can be created", made == 1000, "only %d were accepted" % made)
c("a list of the tenant's 1000+ invoices is served whole", s.req("GET", "/invoices", A), 200, test=lambda j: len(j) >= 1000 and j[-1]["customer"] == "bulk-999")
c("the filter finds one of the bulk invoices", s.req("GET", "/invoices?customer=bulk-500", C), 200, test=lambda j: len(j) == 1 and j[0]["amount_cents"] == 501)
c("the other tenant still sees none of them", s.req("GET", "/invoices?customer=bulk-500", B), 200, test=lambda j: j == [])
c("still alive at the end", s.req("GET", "/invoices", B), 200, contains="zzq-secret-b")
s.finish()
