# Two libraries: cancho-schema and cancho-web

This page is the reference for two cancho libraries, written from their documentation (their repositories are alpibrusl/cancho-schema and alpibrusl/cancho-web). A program that uses them names the modules after the other imports: `import schema;` and `import web;`. The library files are compiled into the program together with `http.server`; you do not copy them.

Both libraries follow the language's ownership rules. `Schema` and `Api` are `res` values: every function that changes one takes it BY VALUE and gives the new one back (`let (s1, node) = schema.new_int(heap, s0, 0, 150);`, `api = web.body(heap, api, op, node);`), and `schema.drop(heap, s)` / `web.drop(heap, api)` end them. To only look at one, pass a reference: `borrow sc as &sr in { ... web.openapi(heap, ar, sr, "Title", "1.0.0") ... }`; inside a function whose `app: &!a App` has a `Schema` field, `app.sc` can be passed directly where a `&Schema` is wanted.

## cancho-schema: a schema is data

A schema is built once at start-up and walked for every request. Nodes are integers (indices); `schema.int_max()` is the highest integer.

    let s0 = schema.empty(heap);
    let (s1, name) = schema.new_string(heap, s0, 1, 64);    // length in Unicode code points, min..max
    let (s2, age) = schema.new_int(heap, s1, 0, 150);        // inclusive bounds
    let (s3, user) = schema.new_object(heap, s2, true);      // true: a field the schema does not list is an error (`unknown`)
    var s = schema.add_field(heap, s3, user, "name", name, true);   // required
    s = schema.add_field(heap, s, user, "age", age, false);         // optional

Other nodes: `new_bool`, `new_number`, `new_any`, `new_array(heap, s, item, min_items, max_items)`; `add_choice(heap, s, string_node, "admin")` limits a string to listed values (call it once per value); `make_nullable(s, node)`. One node may be used by many fields and objects.

Slots: `add_field` numbers the fields in the order it is called across the WHOLE schema, starting at 0 (the first `add_field` above is slot 0 for "name", the second slot 1 for "age"). `schema.slot_count(&s)` is how many there are.

Validating a request body, with the tape from `std.json`:

    let tape = box_slice(heap, json.tape_len(body), 0);            // not a region: a tape can exceed 64 KiB
    borrow mut tape as &!tw in {
        let tp = contents(tw);
        if json.parse(body, tp) < 0 { /* not JSON at all */ } else {
            let slots = box_slice(heap, schema.slot_count(sc), 0);  // sc: &Schema
            let errs = box_slice(heap, schema.errors_len(16), 0);   // room for 16 faults; more are counted, not stored
            borrow mut slots as &!sw in { borrow mut errs as &!ew in {
                let sl = contents(sw);  let es = contents(ew);
                let n = schema.validate(sc, user, body, tp, sl, es);   // 0: the body has the shape; else the number of faults
                // n > 0: let p = schema.problem(heap, sc, body, tp, es, 422, "Unprocessable Content");  -> a buffer.Buffer
                // n == 0: sl[k] is the tape node of the value of slot k (or -1 if the optional field was absent)
            } }
        }
    }

`schema.validate` reports EVERY fault, not the first. `schema.problem` is the whole answer body, `application/problem+json` (RFC 9457):

    {"type":"about:blank","title":"Unprocessable Content","status":422,"count":2,
     "errors":[{"pointer":"/name","code":"min_length","detail":"is too short"},{"pointer":"/age","code":"maximum","detail":"is above the maximum"}]}

`pointer` is a JSON Pointer ("" is the whole body; for a missing required field it names the field). Codes: `required`, `type`, `minimum`, `maximum`, `min_length`, `max_length`, `choice`, `min_items`, `max_items`, `unknown`, `range`. No coercion: "3" is not an integer; 1.0 is. You send it with `server.reply_as(heap, out, 422, "application/problem+json", buffer.bytes(p), keep, "")` and drop the buffer afterwards.

Reading values after a successful validation: `schema.to_int(body, tape, node)` is the integer at a node; a string is read with `std.json`: `json.string_length(body, tape, node)` bytes decoded, then `json.string_into(body, tape, node, dst)` into a `box_slice` you made (escapes such as `\u00e9` are decoded; write it back with `json.put_string`, which encodes again).

`schema.json_schema(heap, sc, node)` writes the JSON Schema of a node; `web.openapi` uses it for you.

## cancho-web: declare the API once

An `Api` is the router, the parameter checks and the OpenAPI 3.1 document, all made from one declaration.

    var api = web.empty(heap);
    let (a1, list) = web.operation(heap, api, "GET", "/users", "listUsers");    // -> (Api, id of the operation)
    api = web.query_param(heap, a1, list, "limit", limit_node, false);             // name, schema node, required?
    api = web.respond(heap, api, list, 200, "a page of users", page_node);         // status, description, body schema
    api = web.respond_problem(heap, api, list, 422);

- `web.operation(heap, api, METHOD, "/users/:id", operationId)` registers a route (`:id` is a path parameter, written `{id}` in the document). Operation ids are 1, 2, 3 ... in the order of declaration; you compare what `dispatch` answers with them. `web.internal(heap, api, "GET", "/openapi.json")` routes a path without documenting it.
- Parameters of operation `op`: `web.path_param(heap, api, op, "id", node)`, `web.query_param(heap, api, op, "limit", node, required)`, `web.header_param(...)`. A declared query parameter has a default: `borrow s as &sr in { api = web.default_int(heap, api, sr, op, "limit", 20); }` (the value then fills the slot when the request has none, and is in the document).
- Bodies and answers: `web.body(heap, api, op, node)` (the request body schema), `web.respond(heap, api, op, status, "text", node)`, `web.respond_empty(heap, api, op, status, "text")`, `web.respond_problem(heap, api, op, status)`, `web.response_header(heap, api, op, "Location")` (on the latest response declared).
- `web.component(heap, api, "NewUser", node)` names a schema node: the document uses a `$ref` to it and lists it under `components.schemas`. `web.respond_problem` refers to the shared problem response `components.responses.Problem`, which exists in the document only when a component named `Problem` has been declared (a schema node for the problem document: `type`, `title`, `status`, `detail`, `count` and `errors`).
- `web.openapi(heap, &api, &schema, "Title", "1.0.0")` -> a `buffer.Buffer` with the document (OpenAPI 3.1, `paths`, `components`). The limits it shows (`minLength`, `maximum`, `required`, `additionalProperties`, a parameter's `default`) are generated from the same nodes the validator runs.

Dispatching a request: build three tables once, then call `web.dispatch` for every request in place of routing by hand.

    borrow api as &ar in {
        widest = web.most_params(ar);      // at least 1
        wide = web.most_args(ar);
    }
    let params = box_slice(heap, 2 * widest, 0);          // routing table
    let args = box_slice(heap, wide, 0);                  // the values of the declared parameters of the matched operation
    let scratch = box_slice(heap, 256, byte_of(0));       // room to decode one value
    // per request, with api and sc borrowed (`&Api`, `&Schema`) and the three tables as `contents(..)` of their boxes:
    let (out2, op) = web.dispatch(heap, api, sc, request, table, contents(params), contents(args), contents(scratch), out, keep);

`op` is the operation id of the route that matched, whose declared path and query parameters are all valid. Otherwise `op == web.answered()` and `out2` already holds the complete answer: 404 (no such path), 405 (with an `Allow` header) or 422 (the faults of the parameters, as above, with pointers `/query/limit`, `/path/id`; an unknown or repeated query parameter is a fault too). Return `out2` unchanged in that case. Declared parameters are read from `args` by slot: learn the slot once, `let slot = web.slot(ar, op, "limit");`, then per request `web.int_arg(contents(args), slot)` (an integer parameter or its default), `web.bool_arg`, `web.present(args, slot)`. Dispatch does not read or validate request bodies: that is `schema.validate`, called by your handler for the operations that have a body.

## A complete small application

A notes service: `POST /notes` with `{"title": 1 to 30 characters, "stars": 0 to 5}` and `GET /notes/{id}`, in the application shape the service skeleton asks for (the same `App`, `app_new`, `app_handle`, `app_drop`). It is complete and builds; it keeps no notes, to stay short (a real handler stores what it validated and answers it).

```cancho
import schema;
import web;

// A notes service: POST /notes {"title": text 1..30, "stars": 0..5} -> 201 {"id", "title", "stars"}; GET /notes/:id -> 200 or 404.

struct App {
    sc: schema.Schema,
    api: web.Api,
    doc: buffer.Buffer,
    new_note: int,
    id_slot: int,
    params: Box[[int]],
    args: Box[[int]],
    scratch: Box[[byte]],
    meta: Box[[int]],
}

fn op_create() -> [] int {
    return 1;
}

fn op_get() -> [] int {
    return 2;
}

fn op_doc() -> [] int {
    return 3;
}

fn app_new[&h, &c](heap: &!h Heap, config: &c [byte]) -> [heap] App {
    // 1. the schema: every call takes the Schema by value and gives it back
    let s0 = schema.empty(heap);
    let (s1, title) = schema.new_string(heap, s0, 1, 30);
    let (s2, stars) = schema.new_int(heap, s1, 0, 5);
    let (s3, new_note) = schema.new_object(heap, s2, true);
    var sc = schema.add_field(heap, s3, new_note, "title", title, true);
    sc = schema.add_field(heap, sc, new_note, "stars", stars, true);
    let (s4, id) = schema.new_int(heap, sc, 1, schema.int_max());
    let (s5, note) = schema.new_object(heap, s4, true);
    sc = schema.add_field(heap, s5, note, "id", id, true);
    sc = schema.add_field(heap, sc, note, "title", title, true);
    sc = schema.add_field(heap, sc, note, "stars", stars, true);
    // the shared problem document that web.respond_problem points at (declared as the component "Problem" below)
    let (s6, text) = schema.new_string(heap, sc, 0, schema.int_max());
    let (s7, status) = schema.new_int(heap, s6, 100, 599);
    let (s8, problem) = schema.new_object(heap, s7, true);
    sc = schema.add_field(heap, s8, problem, "title", text, true);
    sc = schema.add_field(heap, sc, problem, "status", status, true);

    // 2. the API: operations in the order of the ids the handler tests (1, 2, 3, ...)
    var api = web.empty(heap);
    let (a1, create) = web.operation(heap, api, "POST", "/notes", "createNote");
    api = web.body(heap, a1, create, new_note);
    api = web.respond(heap, api, create, 201, "the note", note);
    api = web.respond_problem(heap, api, create, 422);
    let (a2, get) = web.operation(heap, api, "GET", "/notes/:id", "getNote");
    api = web.path_param(heap, a2, get, "id", id);
    api = web.respond(heap, api, get, 200, "the note", note);
    api = web.respond_problem(heap, api, get, 404);
    let (a3, doc_op) = web.internal(heap, api, "GET", "/openapi.json");
    api = a3;
    api = web.component(heap, api, "NewNote", new_note);
    api = web.component(heap, api, "Note", note);
    api = web.component(heap, api, "Problem", problem);

    // 3. the document, written once
    var doc = buffer.empty(heap, 16);
    borrow api as &ar in {
        borrow sc as &sr in {
            buffer.drop(heap, doc);
            doc = web.openapi(heap, ar, sr, "Notes", "1.0.0");
        }
    }
    var widest = 1;
    var wide = 2;
    var id_slot = 0;
    borrow api as &ar in {
        if web.most_params(ar) > 1 {
            widest = web.most_params(ar);
        }
        wide = web.most_args(ar);
        id_slot = web.slot(ar, op_get(), "id");
    }
    return App { sc: sc, api: api, doc: doc, new_note: new_note, id_slot: id_slot, params: box_slice(heap, 2 * widest, 0), args: box_slice(heap, wide, 0), scratch: box_slice(heap, 256, byte_of(0)), meta: box_slice(heap, 1, 0) };
}

fn app_handle[&h, &a, &q, &t, &b](heap: &!h Heap, app: &!a App, request: &q [byte], table: &t [int], body: &b [byte], now_ms: int, out: buffer.Buffer) -> [heap] buffer.Buffer {
    let keep = http.keeps_alive(table);
    // dispatch routes, checks the declared parameters, and on a 404, 405 or 422 writes the answer itself
    let (routed, op) = web.dispatch(heap, app.api, app.sc, request, table, contents(app.params), contents(app.args), contents(app.scratch), out, keep);
    if op == web.answered() {
        return routed;
    }
    if op == op_doc() {
        return server.reply(heap, routed, 200, buffer.bytes(app.doc), keep);
    }
    if op == op_get() {
        let n = web.int_arg(contents(app.args), app.id_slot);
        if n > contents(app.meta)[0] {
            return server.failure(heap, routed, 404, "no such note", keep);
        }
        return server.reply(heap, routed, 200, "{}", keep);
    }
    if op == op_create() {
        let tape = box_slice(heap, json.tape_len(body), 0);
        var answer = routed;
        borrow mut tape as &!tw in {
            let tp = contents(tw);
            if json.parse(body, tp) < 0 {
                answer = server.failure(heap, answer, 400, "not JSON", keep);
            } else {
                let slots = box_slice(heap, schema.slot_count(app.sc), 0);
                let errs = box_slice(heap, schema.errors_len(16), 0);
                borrow mut slots as &!sw in {
                    borrow mut errs as &!ew in {
                        let sl = contents(sw);
                        let es = contents(ew);
                        if schema.validate(app.sc, app.new_note, body, tp, sl, es) > 0 {
                            let p = schema.problem(heap, app.sc, body, tp, es, 422, "Unprocessable Content");
                            borrow p as &pb in {
                                answer = server.reply_as(heap, answer, 422, "application/problem+json", buffer.bytes(pb), keep, "");
                            }
                            buffer.drop(heap, p);
                        } else {
                            contents(app.meta)[0] = contents(app.meta)[0] + 1;
                            answer = server.reply(heap, answer, 201, "{}", keep);
                        }
                    }
                }
                unbox_slice(heap, errs);
                unbox_slice(heap, slots);
            }
        }
        unbox_slice(heap, tape);
        return answer;
    }
    return server.failure(heap, routed, 404, "no handler", keep);
}

fn app_drop[&h](heap: &!h Heap, app: App) -> [heap] int {
    let App { sc, api, doc, new_note, id_slot, params, args, scratch, meta } = app;
    schema.drop(heap, sc);
    web.drop(heap, api);
    buffer.drop(heap, doc);
    unbox_slice(heap, params);
    unbox_slice(heap, args);
    unbox_slice(heap, scratch);
    unbox_slice(heap, meta);
    return 0;
}
```
