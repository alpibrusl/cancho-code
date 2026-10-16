#!/usr/bin/env python3
"""usage: attack.py BINARY PROJECT_CHO  -- independent attack on a built users service (port 8815). HIDDEN: never shown to the builder.

Written for the library-use item: the service is a small JSON API over cancho-web and cancho-schema. What the checks hold the application to is what the
brief promises: the order of the checks of a POST, every fault at once with its pointer and code, problem+json on every error, the page and its total,
ids that are not reused, the capacity of 200, the OpenAPI document agreeing with what the service does (its limits are READ from the document and then
tried against the service), routing (404, 405 with Allow), and robustness (oversize, nesting, a malformed head, keep-alive). Takes about 8 seconds."""
import http.client, json, os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
from svc import Svc

binary = sys.argv[1]
s = Svc(binary, [], 8815, label="ATTACK")
if os.environ.get("SVC_AUTHORITY_OK") == "0":
    s.note("authority is only what a server needs", False, os.environ.get("SVC_AUTHORITY_WHY", ""))
if not s.up:
    s.note("service starts and listens", False, "did not start")
    s.finish()
c = s.check
EXPECTED = 147       # the checks of a full run; a crash of this script (the service answered something it did not expect) counts the checks not run as failed

def crashed(et, ev, tb):
    import traceback
    line = traceback.extract_tb(tb)[-1]
    s.note("the attack stopped at line %d (%s: %s)" % (line.lineno, et.__name__, ev), False)
    for i in range(max(0, EXPECTED - len(s.results))):
        s.results.append(("not run: the attack stopped before it", False, ""))
    s.stop()
    bad = [r for r in s.results if not r[1]]
    for n, _, w in bad[:12]: print("  - %s: %s" % (n, w))
    print("[%s] %d/%d hold" % (s.label, len(s.results) - len(bad), len(s.results)))
    sys.stdout.flush()
    os._exit(1)
sys.excepthook = crashed
PJ = "application/problem+json"
JSONH = {"Content-Type": "application/json"}

conn = [None]
def full(method, path, body=None, headers=None, raw=None):
    """(status, header dict lowercased, text) over one keep-alive connection (reconnects when the server closed it)."""
    data = raw if raw is not None else (json.dumps(body) if body is not None else None)
    if isinstance(data, str): data = data.encode()
    h = dict(headers or {})
    if data is not None and "Content-Type" not in h and not h.get("_nocT"): h["Content-Type"] = "application/json"
    h.pop("_nocT", None)
    for attempt in (0, 1):
        if conn[0] is None: conn[0] = http.client.HTTPConnection("127.0.0.1", s.port, timeout=15)
        try:
            conn[0].request(method, path, body=data, headers=h)
            r = conn[0].getresponse(); t = r.read().decode("utf-8", "replace")
            hs = {k.lower(): v for k, v in r.getheaders()}
            if hs.get("connection", "").lower() == "close": conn[0].close(); conn[0] = None
            return r.status, hs, t
        except Exception as ex:
            try: conn[0].close()
            except Exception: pass
            conn[0] = None
            if attempt: return 0, {}, "<%s: %s>" % (type(ex).__name__, ex)

def req(method, path, body=None, headers=None, raw=None):
    st, hs, t = full(method, path, body, headers, raw)
    return st, t

def js(t):
    try: return json.loads(t)
    except Exception: return None

def faults(j):
    return sorted((e["pointer"], e["code"]) for e in j["errors"])

def problem_ok(t, status):
    j = js(t)
    return isinstance(j, dict) and j.get("type") == "about:blank" and j.get("status") == status and isinstance(j.get("title"), str) and isinstance(j.get("detail", ""), str)

model = {}     # id -> {"name", "age"}: what the service should hold
state = {"next": 1, "created": 0}

def create(name, age, expect=201):
    st, hs, t = full("POST", "/users", {"name": name, "age": age})
    if st == 201 and js(t):
        model[state["next"]] = {"name": name, "age": age}; state["next"] += 1; state["created"] += 1
    return st, hs, t

# 1. ids, Location, the shape of a success
st, hs, t = create("Ada", 36)
s.note("POST -> 201, Content-Type application/json, Location /users/1, the user as stored", st == 201 and hs.get("content-type") == "application/json" and hs.get("location") == "/users/1" and js(t) == {"id": 1, "name": "Ada", "age": 36}, "%s %s %s" % (st, hs.get("content-type"), hs.get("location")))
st, hs, t = create("Grace", 85)
s.note("the second user is 2 with Location /users/2", st == 201 and hs.get("location") == "/users/2" and js(t)["id"] == 2, "%s %s %s" % (st, hs.get("location"), t[:60]))
st, hs, t = create("Zero", 0)
s.note("age 0 is allowed", st == 201 and js(t)["age"] == 0, t[:60])
st, hs, t = create("Old", 150)
s.note("age 150 is allowed", st == 201 and js(t)["age"] == 150, t[:60])
s.note("a success body has exactly id, name and age", sorted(js(t)) == ["age", "id", "name"], t[:80])
st, hs, t = full("GET", "/users/4")
s.note("GET -> 200 application/json with the user", st == 200 and hs.get("content-type") == "application/json" and js(t) == {"id": 4, "name": "Old", "age": 150}, "%s %s" % (st, t[:60]))
# 2. names
for label, name, ok in (("1 character", "a", True), ("40 characters", "n" * 40, True), ("41 characters", "n" * 41, False),
                        ("40 four-byte characters (code points, not bytes)", "\U0001F600" * 40, True), ("41 four-byte characters", "\U0001F600" * 41, False),
                        ("40 two-byte characters", "é" * 40, True)):
    st, hs, t = create(name, 7)
    s.note("name of %s -> %s" % (label, "201" if ok else "422 max_length"), (st == 201 and js(t)["name"] == name) if ok else (st == 422 and faults(js(t)) == [("/name", "max_length")]), "%s %s" % (st, t[:80]))
st, hs, t = full("POST", "/users", raw='{"name":"\\ud83d\\ude00\\ud83d\\ude00","age":3}')
if st == 201: model[state["next"]] = {"name": "\U0001F600\U0001F600", "age": 3}; state["next"] += 1; state["created"] += 1
s.note("a surrogate pair escape is one character and is answered decoded", st == 201 and js(t)["name"] == "\U0001F600\U0001F600", "%s %s" % (st, t[:80]))
st, hs, t = create("tab\there \"q\" \\ back\nline ☃", 12)
s.note("a name with a tab, quotes, a backslash, a newline and a symbol round-trips", st == 201 and js(t)["name"] == "tab\there \"q\" \\ back\nline ☃", "%s %s" % (st, t[:80]))
s.note("... and is read back the same", js(req("GET", "/users/%d" % (state["next"] - 1))[1]) == {"id": state["next"] - 1, "name": "tab\there \"q\" \\ back\nline ☃", "age": 12}, "")
st, hs, t = full("POST", "/users", raw='{"name":"\\u00e9\\u0041","age":3}')
if st == 201: model[state["next"]] = {"name": "éA", "age": 3}; state["next"] += 1; state["created"] += 1
s.note("\\u escapes in the name are decoded", st == 201 and js(t)["name"] == "éA", "%s %s" % (st, t[:80]))
c("an empty name -> min_length at /name", req("POST", "/users", {"name": "", "age": 1}), 422, test=lambda j: faults(j) == [("/name", "min_length")])
# 3. ages
c("age 151 -> maximum", req("POST", "/users", {"name": "x", "age": 151}), 422, test=lambda j: faults(j) == [("/age", "maximum")])
c("age -1 -> minimum", req("POST", "/users", {"name": "x", "age": -1}), 422, test=lambda j: faults(j) == [("/age", "minimum")])
c("age 1.5 -> type", req("POST", "/users", {"name": "x", "age": 1.5}), 422, test=lambda j: faults(j) == [("/age", "type")])
c("age as text -> type", req("POST", "/users", {"name": "x", "age": "30"}), 422, test=lambda j: faults(j) == [("/age", "type")])
c("age null -> type", req("POST", "/users", {"name": "x", "age": None}), 422, test=lambda j: faults(j) == [("/age", "type")])
c("age true -> type", req("POST", "/users", {"name": "x", "age": True}), 422, test=lambda j: faults(j) == [("/age", "type")])
c("name as a number -> type", req("POST", "/users", {"name": 5, "age": 1}), 422, test=lambda j: faults(j) == [("/name", "type")])
c("name null -> type", req("POST", "/users", {"name": None, "age": 1}), 422, test=lambda j: faults(j) == [("/name", "type")])
# 4. every fault at once
r = req("POST", "/users", {})
c("{} -> both fields required, at once", r, 422, test=lambda j: j["count"] == 2 and faults(j) == [("/age", "required"), ("/name", "required")])
r = req("POST", "/users", {"name": 1, "age": "x", "extra": 1, "more": 2})
c("four faults in one body are four errors", r, 422, test=lambda j: j["count"] == 4 and faults(j) == [("/age", "type"), ("/extra", "unknown"), ("/more", "unknown"), ("/name", "type")])
c("name and age both out of range -> both", req("POST", "/users", {"name": "", "age": 999}), 422, test=lambda j: j["count"] == 2 and faults(j) == [("/age", "maximum"), ("/name", "min_length")])
c("a missing name with a bad age -> both", req("POST", "/users", {"age": -5}), 422, test=lambda j: faults(j) == [("/age", "minimum"), ("/name", "required")])
c("a valid body with one unknown field -> unknown only", req("POST", "/users", {"name": "x", "age": 1, "role": "admin"}), 422, test=lambda j: faults(j) == [("/role", "unknown")])
for label, body in (("an array", [1]), ("a string", "x"), ("a number", 5), ("null", None), ("true", True)):
    c("%s as the body -> type at the root" % label, req("POST", "/users", raw=json.dumps(body)), 422, test=lambda j: faults(j) == [("", "type")])
r = req("POST", "/users", {"name": "x", "age": 1, **{"f%02d" % i: i for i in range(30)}})
c("30 unknown fields are counted: count 30", r, 422, test=lambda j: j["count"] == 30 and 1 <= len(j["errors"]) <= 30 and all(e["code"] == "unknown" for e in j["errors"]))
def shape(t):
    j = js(t)
    return isinstance(j, dict) and j.get("type") == "about:blank" and j.get("title") == "Unprocessable Content" and j.get("status") == 422 and isinstance(j.get("count"), int) and j["count"] == len(j["errors"]) and all(set(e) == {"pointer", "code", "detail"} and all(isinstance(v, str) for v in e.values()) for e in j["errors"])
st, hs, t = full("POST", "/users", {"name": "", "age": 999})
s.note("a 422 for a body is application/problem+json with type, title, status, count and errors {pointer, code, detail}", st == 422 and hs.get("content-type") == PJ and shape(t), "%s %s %s" % (st, hs.get("content-type"), t[:100]))
# 5. the order of the checks and the other POST errors
st, hs, t = full("POST", "/users", raw="{not json")
s.note("invalid JSON -> 400 problem document", st == 400 and hs.get("content-type") == PJ and problem_ok(t, 400) and js(t).get("title") == "Bad Request", "%s %s %s" % (st, hs.get("content-type"), t[:80]))
for label, raw in (("an empty body", ""), ("trailing text after the object", '{"name":"x","age":1} x'), ("an unterminated string", '{"name":"x'), ("a lone comma", '{"name":"x",}')):
    c("%s -> 400" % label, req("POST", "/users", raw=raw), 400, test=lambda j: j["status"] == 400)
st, hs, t = full("POST", "/users", raw='{"name":"x","age":1}', headers={"Content-Type": "text/plain"})
s.note("Content-Type text/plain -> 415 problem document", st == 415 and hs.get("content-type") == PJ and problem_ok(t, 415) and js(t).get("title") == "Unsupported Media Type", "%s %s" % (st, t[:80]))
st, hs, t = full("POST", "/users", raw='{"name":"x","age":1}', headers={"_nocT": 1})
s.note("no Content-Type at all -> 415", st == 415, "%s %s" % (st, t[:80]))
c("415 comes before 400: bad JSON with a wrong type", req("POST", "/users", raw="{nope", headers={"Content-Type": "text/plain"}), 415)
c("415 comes before 422: a bad body with a wrong type", req("POST", "/users", raw='{"name":""}', headers={"Content-Type": "text/plain"}), 415)
for ct in ("application/jsonx", "application/json-patch+json", "application", "json", "text/json"):
    c("Content-Type %r -> 415" % ct, req("POST", "/users", raw='{"name":"x","age":1}', headers={"Content-Type": ct}), 415)
for ct in ("APPLICATION/JSON", "Application/Json", "application/json;charset=utf-8", "application/json; charset=utf-8", "application/json ;x=1"):
    st, hs, t = full("POST", "/users", raw=json.dumps({"name": "ct", "age": 2}), headers={"Content-Type": ct})
    if st == 201: model[state["next"]] = {"name": "ct", "age": 2}; state["next"] += 1; state["created"] += 1
    s.note("Content-Type %r is accepted" % ct, st == 201, "%s %s" % (st, t[:80]))
c("a duplicate key: the body is still judged (no crash)", req("POST", "/users", raw='{"name":"a","name":"b","age":1,"age":2,"extra":1}'), 422)
# 6. the page
def check_page(path, n, name):
    st, hs, t = full("GET", path)
    j = js(t)
    live = sorted(model)
    want = [{"id": i, **model[i]} for i in live[:n]]
    s.note(name, st == 200 and hs.get("content-type") == "application/json" and j == {"total": len(live), "items": want}, "%s %s" % (st, t[:150]))
check_page("/users?limit=1", 1, "limit=1 -> the first user, total counts all of them")
check_page("/users?limit=3", 3, "limit=3 -> the first three, ordered by id")
check_page("/users?limit=100", 100, "limit=100 is allowed and returns every user (fewer than 100)")
check_page("/users", 20, "no limit -> the default of 20 (there are more than 20 users)")
check_page("/users?limit=20", 20, "limit=20 equals the default")
check_page("/users?limit=19", 19, "limit=19 -> 19 users")
for q, label in (("limit=0", "0"), ("limit=101", "101"), ("limit=-3", "-3"), ("limit=abc", "abc"), ("limit=", "empty"), ("limit=1.5", "1.5"), ("limit=1e1", "1e1"), ("limit=%20", "a space")):
    st, hs, t = full("GET", "/users?" + q)
    j = js(t)
    s.note("limit %s -> 422 at /query/limit, problem+json" % label, st == 422 and hs.get("content-type") == PJ and j and shape(t) and [p for p, _ in faults(j)] == ["/query/limit"], "%s %s" % (st, t[:100]))
c("limit twice -> 422 at /query/limit", req("GET", "/users?limit=1&limit=2"), 422, test=lambda j: [p for p, _ in faults(j)] == ["/query/limit"])
c("an unknown query parameter -> 422 unknown", req("GET", "/users?offset=1"), 422, test=lambda j: faults(j) == [("/query/offset", "unknown")])
c("a valid limit with an unknown parameter -> 422 unknown only", req("GET", "/users?limit=2&x=1"), 422, test=lambda j: faults(j) == [("/query/x", "unknown")])
# 7. get and delete
for i in ("0", "-1", "abc", "1.5", "1e1", "99999999999999999999"):
    st, hs, t = full("GET", "/users/" + i)
    j = js(t)
    s.note("GET /users/%s -> 422 at /path/id" % i, st == 422 and hs.get("content-type") == PJ and j and [p for p, _ in faults(j)] == ["/path/id"], "%s %s" % (st, t[:90]))
    s.note("DELETE /users/%s -> 422 at /path/id and nothing is deleted" % i, req("DELETE", "/users/" + i)[0] == 422 and len(js(req("GET", "/users?limit=100")[1])["items"]) == len(model) if len(model) <= 100 else True, "")
st, hs, t = full("GET", "/users/100000")
s.note("GET of an id that never existed -> 404 problem document", st == 404 and hs.get("content-type") == PJ and problem_ok(t, 404) and js(t).get("title") == "Not Found", "%s %s" % (st, t[:80]))
st, hs, t = full("DELETE", "/users/100000")
s.note("DELETE of an id that never existed -> 404 problem document", st == 404 and hs.get("content-type") == PJ and problem_ok(t, 404), "%s %s" % (st, t[:80]))
st, hs, t = full("DELETE", "/users/2")
model.pop(2, None)
s.note("DELETE /users/2 -> 204 with no body", st == 204 and t == "", "%s %r" % (st, t[:40]))
c("GET of the deleted user -> 404", req("GET", "/users/2"), 404, test=lambda j: problem_ok(json.dumps(j), 404))
c("DELETE of the deleted user -> 404", req("DELETE", "/users/2"), 404, test=lambda j: problem_ok(json.dumps(j), 404))
check_page("/users?limit=3", 3, "the page skips the deleted user and the total went down")
check_page("/users?limit=100", 100, "the full page after the delete")
c("the user before and after it are intact", req("GET", "/users/3"), 200, test=lambda j: j == {"id": 3, "name": "Zero", "age": 0})
st, hs, t = create("after-delete", 44)
s.note("a new user after a delete takes a new id, not the freed one", st == 201 and js(t)["id"] == state["next"] - 1 and js(t)["id"] > 12 and hs.get("location") == "/users/%d" % js(t)["id"], "%s %s" % (st, t[:60]))
last = state["next"] - 1
st, _, _ = full("DELETE", "/users/%d" % last); model.pop(last, None)
st2, hs2, t2 = create("after-delete-last", 45)
s.note("an id is not reused even when the last user was deleted", st == 204 and st2 == 201 and js(t2)["id"] == last + 1, "%s %s %s" % (st, st2, t2[:60]))
check_page("/users", 20, "the default page after the churn")
# 8. routing
for method, path, allow in (("GET", "/nope", None), ("GET", "/", None), ("GET", "/users/1/extra", None), ("GET", "/user", None), ("GET", "/openapi", None)):
    st, hs, t = full(method, path)
    s.note("%s %s -> 404" % (method, path), st == 404, "%s %s" % (st, t[:60]))
for method, path, want in (("PUT", "/users", {"GET", "POST"}), ("DELETE", "/users", {"GET", "POST"}), ("POST", "/users/1", {"GET", "DELETE"}), ("PUT", "/users/1", {"GET", "DELETE"}), ("POST", "/openapi.json", {"GET"})):
    st, hs, t = full(method, path, {"name": "x", "age": 1} if method in ("POST", "PUT") else None)
    got = {m.strip() for m in hs.get("allow", "").split(",")} - {""}
    s.note("%s %s -> 405 with Allow %s" % (method, path, "+".join(sorted(want))), st == 405 and want <= got and not (got - want - {"HEAD", "OPTIONS"}), "%s %s" % (st, hs.get("allow")))
# 9. the OpenAPI document
st, hs, t = full("GET", "/openapi.json")
doc = js(t)
s.note("GET /openapi.json -> 200 application/json, an OpenAPI 3.1 document", st == 200 and hs.get("content-type") == "application/json" and isinstance(doc, dict) and str(doc.get("openapi", "")).startswith("3.1"), "%s %s" % (st, t[:60]))
doc = doc if isinstance(doc, dict) else {}
def ref(x):
    seen = 0
    while isinstance(x, dict) and "$ref" in x and seen < 5:
        node = doc
        try:
            for part in x["$ref"].lstrip("#/").split("/"): node = node[part.replace("~1", "/").replace("~0", "~")]
        except Exception:
            return {}
        x = node; seen += 1
    return x
def all_refs(x):
    if isinstance(x, dict):
        for k, v in x.items():
            if k == "$ref" and isinstance(v, str): yield v
            else: yield from all_refs(v)
    elif isinstance(x, list):
        for v in x: yield from all_refs(v)

def resolves(r):
    node = doc
    try:
        for part in r.lstrip("#/").split("/"): node = node[part.replace("~1", "/").replace("~0", "~")]
        return True
    except Exception:
        return False

def safe(f, default=None):
    try: return f()
    except Exception: return default
paths = doc.get("paths", {})
refs = sorted(set(all_refs(doc)))
s.note("every $ref of the document resolves (the shared problem document is declared)", all(resolves(r) for r in refs), "dangling: %s" % [r for r in refs if not resolves(r)])
s.note("the paths are /users and /users/{id} only", sorted(paths) == ["/users", "/users/{id}"], str(sorted(paths)))
ops = {}
for p, item in paths.items():
    for m, o in item.items():
        if m in ("get", "post", "delete", "put", "patch"): ops[(m, p)] = o
s.note("the operations are get and post of /users, get and delete of /users/{id}", sorted(ops) == [("delete", "/users/{id}"), ("get", "/users"), ("get", "/users/{id}"), ("post", "/users")], str(sorted(ops)))
s.note("the operationIds are listUsers, createUser, getUser, deleteUser", [ops.get(k, {}).get("operationId") for k in (("get", "/users"), ("post", "/users"), ("get", "/users/{id}"), ("delete", "/users/{id}"))] == ["listUsers", "createUser", "getUser", "deleteUser"], "")
codes = lambda k: sorted(ops.get(k, {}).get("responses", {}))
s.note("listUsers answers 200 and 422", codes(("get", "/users")) == ["200", "422"], str(codes(("get", "/users"))))
s.note("createUser answers 201, 400, 415, 422 and 503", codes(("post", "/users")) == ["201", "400", "415", "422", "503"], str(codes(("post", "/users"))))
s.note("getUser answers 200, 404 and 422", codes(("get", "/users/{id}")) == ["200", "404", "422"], str(codes(("get", "/users/{id}"))))
s.note("deleteUser answers 204, 404 and 422", codes(("delete", "/users/{id}")) == ["204", "404", "422"], str(codes(("delete", "/users/{id}"))))
params = ops.get(("get", "/users"), {}).get("parameters", [])
lim = safe(lambda: [ref(p) for p in params if ref(p)["name"] == "limit"][0], {})
lsch = ref(lim.get("schema", {})) if lim else {}
s.note("the limit parameter: query, not required, integer, minimum 1, maximum 100, default 20", safe(lambda: lim["in"] == "query" and not lim.get("required", False) and lsch["type"] == "integer" and lsch["minimum"] == 1 and lsch["maximum"] == 100 and lsch["default"] == 20, False), str(lim)[:120])
idp = [ref(p) for p in paths.get("/users/{id}", {}).get("parameters", [])] + [ref(p) for o in ("get", "delete") for p in ops.get((o, "/users/{id}"), {}).get("parameters", [])]
idp = [p for p in idp if p.get("name") == "id"]
s.note("the id parameter: in the path, required, an integer with minimum 1", bool(idp) and safe(lambda: idp[0]["in"] == "path" and idp[0]["required"] is True and ref(idp[0]["schema"])["type"] == "integer" and ref(idp[0]["schema"])["minimum"] == 1, False), str(idp)[:100])
body = safe(lambda: ref(ops[("post", "/users")]["requestBody"]["content"]["application/json"]["schema"]), {})
props = {k: ref(v) for k, v in body.get("properties", {}).items()}
s.note("the request body: an object, name and age required, no additional properties", body.get("type") == "object" and sorted(body.get("required", [])) == ["age", "name"] and body.get("additionalProperties") is False and sorted(props) == ["age", "name"], str(body)[:120])
s.note("name: string, minLength 1, maxLength 40; age: integer, minimum 0, maximum 150", safe(lambda: props["name"]["type"] == "string" and props["name"]["minLength"] == 1 and props["name"]["maxLength"] == 40 and props["age"]["type"] == "integer" and props["age"]["minimum"] == 0 and props["age"]["maximum"] == 150, False), str(props)[:150])
okr = safe(lambda: ref(ops[("post", "/users")]["responses"]["201"]), {})
s.note("the 201 documents the Location header and a user body", "Location" in okr.get("headers", {}) or "location" in {k.lower() for k in okr.get("headers", {})}, str(okr)[:100])
usr = safe(lambda: ref(okr["content"]["application/json"]["schema"]), {})
s.note("the user schema: id (integer), name, age, all required", safe(lambda: sorted(usr["required"]) == ["age", "id", "name"] and ref(usr["properties"]["id"])["type"] == "integer", False), str(usr)[:100])
page = safe(lambda: ref(ops[("get", "/users")]["responses"]["200"]["content"]["application/json"]["schema"]), {})
s.note("the page schema: total (integer) and items (array of users), both required", safe(lambda: sorted(page["required"]) == ["items", "total"] and ref(page["properties"]["items"])["type"] == "array" and ref(page["properties"]["total"])["type"] == "integer", False), str(page)[:100])
errs_of = lambda: [json.dumps(ops.get(("post", "/users"), {}).get("responses", {}).get(code), sort_keys=True) for code in ("400", "415", "422", "503")]
s.note("the error responses of createUser are one shared description (the same $ref), not four", len(set(errs_of())) == 1 and "$ref" in errs_of()[0], errs_of()[0][:100])
s.note("a 422 of createUser names application/problem+json", "application/problem+json" in json.dumps(ref(ops.get(("post", "/users"), {}).get("responses", {}).get("422", {}))), "")
s.note("the document is the same on every request", req("GET", "/openapi.json")[1] == t, "")
# what the document says is what the service does: the limits are read from the document and tried against the service
mx = safe(lambda: props["name"]["maxLength"]); mn = safe(lambda: props["name"]["minLength"]); amax = safe(lambda: props["age"]["maximum"]); amin = safe(lambda: props["age"]["minimum"])
if None not in (mx, mn, amax, amin) and mx <= 1000:
    st1, _, _ = create("n" * mx, 1); st2 = req("POST", "/users", {"name": "n" * (mx + 1), "age": 1})[0]
    st3 = req("POST", "/users", {"name": "n" * mn, "age": 1})[0] if mn > 0 else 201
    st4 = req("POST", "/users", {"name": "n" * (mn - 1), "age": 1})[0] if mn > 0 else 422
    if st3 == 201: model[state["next"]] = {"name": "n" * mn, "age": 1}; state["next"] += 1; state["created"] += 1
    s.note("the service accepts the document's maxLength and minLength of name and refuses one beyond", (st1, st2, st3, st4) == (201, 422, 201, 422), str((st1, st2, st3, st4)))
    st5, _, _ = create("a", amax); st6 = req("POST", "/users", {"name": "a", "age": amax + 1})[0]
    st7, _, _ = create("a", amin); st8 = req("POST", "/users", {"name": "a", "age": amin - 1})[0]
    s.note("the service accepts the document's age bounds and refuses one beyond", (st5, st6, st7, st8) == (201, 422, 201, 422), str((st5, st6, st7, st8)))
else:
    s.note("the service accepts the document's limits of name and age and refuses one beyond", False, "the document has no such limits")
# 10. keep-alive and robustness
cc = http.client.HTTPConnection("127.0.0.1", s.port, timeout=10)
okk = True
try:
    for i in range(6):
        cc.request("GET", "/users?limit=1"); r = cc.getresponse(); r.read(); okk = okk and r.status == 200
        cc.request("POST", "/users", body="{bad", headers=JSONH); r = cc.getresponse(); r.read(); okk = okk and r.status == 400
except Exception as ex:
    okk = False
cc.close()
s.note("12 requests, errors included, on one keep-alive connection", okk, "")
out = s.raw(b"GARBAGE\r\n\r\n")
s.note("a malformed request line is answered 400", "400" in out.split("\r\n")[0], out[:60])
st, hs, t = full("POST", "/users", raw=b'{"name":"' + b"a" * 20000 + b'","age":1}')
s.note("a body over the server's input buffer is refused (413) and the service lives", st in (413, 400, 422) or st == 0, "%s" % st)
conn[0] = None
st, hs, t = full("POST", "/users", raw=b"[" * 5000 + b"]" * 5000)
s.note("a deeply nested body is refused without trapping (400 or 422)", st in (400, 422), "%s %s" % (st, t[:80]))
st, hs, t = full("POST", "/users", raw=b'{"name":"' + b"a" * 9000 + b'","age":1}')
s.note("a 9000-character name -> 422 max_length", st == 422 and faults(js(t)) == [("/name", "max_length")], "%s %s" % (st, t[:80]))
st, hs, t = full("POST", "/users", raw=b'{"name":"\xff\xfe","age":1}')
s.note("invalid UTF-8 in a name does not kill the service (201, 400 or 422)", st in (201, 400, 422), "%s %s" % (st, t[:80]))
if st == 201: model[state["next"]] = None; state["next"] += 1; state["created"] += 1; model.pop(state["next"] - 1)
# 11. capacity: 200 users are ever created, deleted ones included
c("the service is alive before the capacity test", req("GET", "/users?limit=1"), 200)
n = js(req("GET", "/users?limit=1")[1])["total"]
total_ever = state["next"] - 1
# the one request above may have created an unmodelled user (invalid UTF-8): ask the service for the highest id by creating one
st, hs, t = full("POST", "/users", {"name": "probe", "age": 1})
base = js(t)["id"] if st == 201 else None
s.note("the probe user is created", st == 201 and base is not None, "%s %s" % (st, t[:60]))
if base is not None:
    model = {k: v for k, v in model.items()}
    fill = 200 - base
    bad = []
    for i in range(fill):
        st, hs, t = full("POST", "/users", {"name": "fill%03d" % i, "age": i % 100})
        if st != 201: bad.append((i, st, t[:50])); break
        base += 1
    s.note("every POST up to the 200th user is 201 (%d more)" % fill, not bad and base == 200, str(bad[:1]))
    st, hs, t = full("POST", "/users", {"name": "one too many", "age": 1})
    s.note("the 201st POST -> 503 problem document", st == 503 and hs.get("content-type") == PJ and problem_ok(t, 503) and js(t).get("title") == "Service Unavailable", "%s %s" % (st, t[:80]))
    st, _, _ = full("DELETE", "/users/200")
    st2, hs2, t2 = full("POST", "/users", {"name": "after delete", "age": 1})
    s.note("a delete does not make room: a POST after it is still 503", st == 204 and st2 == 503, "%s %s" % (st, st2))
    c("a bad body when full is 422 (the checks of the body come first)", req("POST", "/users", {"name": "", "age": 1}), 422)
    c("a body that is not JSON when full is 400", req("POST", "/users", raw="{x"), 400)
    c("a wrong Content-Type when full is 415", req("POST", "/users", raw='{"name":"x","age":1}', headers={"Content-Type": "text/plain"}), 415)
    c("a read still works when full", req("GET", "/users/199"), 200, test=lambda j: j["id"] == 199)
    c("the last page works when full: limit=100 gives 100 items and the total is 198 live users", req("GET", "/users?limit=100"), 200, test=lambda j: len(j["items"]) == 100 and j["total"] == js(req("GET", "/users?limit=1")[1])["total"] and j["items"][0]["id"] == 1)
    big = js(req("GET", "/users?limit=100")[1])
    s.note("a page of 100 users fits one answer and is in id order", big is not None and [u["id"] for u in big["items"]] == sorted(u["id"] for u in big["items"]), "")
st, hs, t = full("GET", "/users?limit=100")
s.note("... and the service answers it whole (it did not cut the page)", st == 200 and js(t) is not None, "%s %s" % (st, t[-60:]))
c("still alive after all of the above", req("GET", "/openapi.json"), 200)
s.finish()
