#!/usr/bin/env python3
"""usage: accept.py BINARY PROJECT_CHO  -- the acceptance scenarios of the users brief (what the builder is shown).

Port 18815. Takes about 2 seconds."""
import json, os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
from svc import Svc

binary = sys.argv[1]
s = Svc(binary, [], 18815, label="ACCEPTANCE")
if os.environ.get("SVC_AUTHORITY_OK") == "0":
    s.note("authority is only what a server needs", False, os.environ.get("SVC_AUTHORITY_WHY", ""))
if not s.up:
    s.note("service starts and listens", False, "did not start")
    s.finish()
c = s.check
PJ = "application/problem+json"

def post(body, headers=None):
    return s.req("POST", "/users", headers, body)

def ctype(path, method="GET", body=None, headers=None):
    import http.client
    h = http.client.HTTPConnection("127.0.0.1", s.port, timeout=15)
    try:
        h.request(method, path, body=json.dumps(body) if body is not None else None, headers=dict(headers or {}, **({"Content-Type": "application/json"} if body is not None else {})))
        r = h.getresponse(); r.read(); return r.status, r.getheader("Content-Type"), r.getheader("Location"), r.getheader("Allow")
    finally:
        h.close()

def faults(j):
    return sorted((e["pointer"], e["code"]) for e in j["errors"])

# create and read
c("POST a user -> 201 {id, name, age}", post({"name": "Ada", "age": 36}), 201, test=lambda j: j == {"id": 1, "name": "Ada", "age": 36})
st, ct, loc, _ = ctype("/users", "POST", {"name": "Grace", "age": 85})
s.note("the second POST is 201 with Content-Type application/json and Location /users/2", (st, ct, loc) == (201, "application/json", "/users/2"), "%s %s %s" % (st, ct, loc))
c("GET /users/1 -> the user", s.req("GET", "/users/1"), 200, test=lambda j: j == {"id": 1, "name": "Ada", "age": 36})
c("GET /users/3 -> 404 problem document", s.req("GET", "/users/3"), 404, test=lambda j: j["status"] == 404 and j["title"] == "Not Found" and j["type"] == "about:blank")
s.note("the 404 is application/problem+json", ctype("/users/3")[1] == PJ, str(ctype("/users/3")[1]))
c("a name with a quote, an accent and an escape round-trips", post({"name": "Zoë \"Z\" ☃", "age": 0}), 201, test=lambda j: j["name"] == "Zoë \"Z\" ☃" and j["id"] == 3)
c("... and is read back the same", s.req("GET", "/users/3"), 200, test=lambda j: j["name"] == "Zoë \"Z\" ☃")
# validation: every fault at once
r = c("an empty name and an age of 151 -> 422 with both faults", post({"name": "", "age": 151}), 422, test=lambda j: j["status"] == 422 and j["count"] == 2 and faults(j) == [("/age", "maximum"), ("/name", "min_length")])
s.note("the 422 is application/problem+json", ctype("/users", "POST", {"name": "", "age": 151})[1] == PJ, "")
c("a missing field and an unknown one -> both reported", post({"name": "x", "foo": 1}), 422, test=lambda j: j["count"] == 2 and faults(j) == [("/age", "required"), ("/foo", "unknown")])
c("a name of 41 characters -> max_length at /name", post({"name": "n" * 41, "age": 5}), 422, test=lambda j: faults(j) == [("/name", "max_length")])
c("a name of 40 characters is fine", post({"name": "n" * 40, "age": 5}), 201)
c("an age that is text -> type at /age", post({"name": "x", "age": "5"}), 422, test=lambda j: faults(j) == [("/age", "type")])
c("an age of -1 -> minimum at /age", post({"name": "x", "age": -1}), 422, test=lambda j: faults(j) == [("/age", "minimum")])
c("a body that is not an object -> type at the root", post([1, 2]), 422, test=lambda j: faults(j) == [("", "type")])
c("a body that is not JSON -> 400 problem document", s.req("POST", "/users", None, raw_body="{not json"), 400, test=lambda j: j["status"] == 400)
c("a Content-Type that is not JSON -> 415", s.req("POST", "/users", {"Content-Type": "text/plain"}, raw_body='{"name":"x","age":1}'), 415, test=lambda j: j["status"] == 415)
c("Content-Type with a charset is accepted", s.req("POST", "/users", {"Content-Type": "application/json; charset=utf-8"}, raw_body='{"name":"cs","age":1}'), 201)
# list
n = s.req("GET", "/users?limit=2")
c("GET /users?limit=2 -> the first two users", n, 200, test=lambda j: j["total"] == 5 and [u["id"] for u in j["items"]] == [1, 2])
c("GET /users -> at most 20 (the default)", s.req("GET", "/users"), 200, test=lambda j: j["total"] == 5 and len(j["items"]) == 5)
c("limit=0 -> 422 at /query/limit", s.req("GET", "/users?limit=0"), 422, test=lambda j: faults(j) == [("/query/limit", "minimum")])
c("limit=abc -> 422 at /query/limit", s.req("GET", "/users?limit=abc"), 422, test=lambda j: faults(j) == [("/query/limit", "type")])
c("an unknown query parameter -> 422", s.req("GET", "/users?color=red"), 422, test=lambda j: faults(j) == [("/query/color", "unknown")])
# delete
c("DELETE /users/2 -> 204", s.req("DELETE", "/users/2"), 204)
c("GET /users/2 -> 404", s.req("GET", "/users/2"), 404)
c("DELETE /users/2 again -> 404", s.req("DELETE", "/users/2"), 404)
c("the list no longer has it, total is 4", s.req("GET", "/users?limit=100"), 200, test=lambda j: j["total"] == 4 and 2 not in [u["id"] for u in j["items"]])
c("the next id is not 2", post({"name": "next", "age": 9}), 201, test=lambda j: j["id"] == 6)
c("GET /users/0 -> 422 at /path/id", s.req("GET", "/users/0"), 422, test=lambda j: faults(j) == [("/path/id", "minimum")])
c("GET /users/abc -> 422 at /path/id", s.req("GET", "/users/abc"), 422, test=lambda j: faults(j) == [("/path/id", "type")])
# routing
c("an unknown path -> 404", s.req("GET", "/nope"), 404)
st, ct, loc, allow = ctype("/users", "PUT", {"name": "x", "age": 1})
s.note("PUT /users -> 405 with Allow GET and POST", st == 405 and allow is not None and "GET" in allow and "POST" in allow, "%s %s" % (st, allow))
# the document
doc = s.req("GET", "/openapi.json")
c("GET /openapi.json -> an OpenAPI 3.1 document with the four operations", doc, 200,
  test=lambda j: j["openapi"].startswith("3.1") and sorted(j["paths"]) == ["/users", "/users/{id}"] and sorted(j["paths"]["/users"]) == ["get", "post"] and sorted(k for k in j["paths"]["/users/{id}"] if k != "parameters") == ["delete", "get"])
s.finish()
