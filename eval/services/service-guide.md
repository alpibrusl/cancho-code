# Writing a service in cancho (the application interface)

A service is two files compiled together: the fixed skeleton `main.cho` (the server loop and `main`; you never see or edit it) and YOUR `project.cho`, the application. The task text shows the interface (`App`, `app_new`, `app_handle`, `app_drop`). Rules learned the hard way:

- **No imports of the modules the skeleton already imports**: `std.buffer`, `std.bytes`, `std.http`, `std.io`, `std.json`, `std.map`, `std.option`, `std.result`, `std.route`, `std.vec` and `http.server` are imported once for the whole program; use them as `buffer.`, `bytes.`, `http.`, `json.`, `server.`... Importing one again is an error. Other std modules (`std.hmac`, `std.crypto`, `std.utf8`, ...) you import yourself at the top of project.cho.
- **State cannot grow through `app: &!a App`.** `app.items = vec.push(heap, app.items, x)` is refused (a borrowed struct cannot swap in a grown collection). Allocate fixed-size `box_slice`s in `app_new` (sized from the brief's required capacity) and write into them in place with a count kept in an int slot; free them in `app_drop` by destructuring `let App { a, b } = app;` and `unbox_slice`. Answer 503 (or what the brief says) when full.
- A function's effect row is exact: `[heap]` only if it really allocates; a pure function is `[]`. Text you build is a `buffer.Buffer`, dropped when you are done (`buffer.drop`). A response is appended to `out` by `server.reply(heap, out, status, body_bytes, keep)` or `server.failure(heap, out, status, "message", keep)` and returned; `keep` is `http.keeps_alive(table)`.
- The request is parsed for you: `http.method(request, table)`, `http.path(request, table)`, `http.query(request, table)`, headers by `http.header(request, table, "Name")` (header values arrive with surrounding whitespace trimmed). `body` is the request body (the server answers 400/413 itself for a request it cannot parse or hold; a body over 16 KiB never reaches you). The output buffer is 64 KiB: keep any one response under that.
- Answer EVERY request with something and never trap (an index out of range, an overflow, a `trap()` kills the server). Check lengths before indexing; check arithmetic before it can overflow.
- `now_ms` is Unix time in milliseconds.
- Put the decisions in small pure functions (`fn name(...) -> [] int`, no `heap`) and keep `app_handle` short: it routes, calls them, and builds the response.

## A complete small application (a counter: GET /count reads it, POST /count adds one)

```cancho
edition 7;

struct App {
    counts: Box[[int]],
}

fn app_new[&h, &c](heap: &!h Heap, config: &c [byte]) -> [heap] App {
    return App { counts: box_slice(heap, 1, 0) };
}

// the pure part: which action a method and a path name (0 none, 1 read, 2 increment)
fn counter_action[&m, &p](method: &m [byte], path: &p [byte]) -> [] int {
    if bytes.equal(path, "/count") {
        if bytes.equal(method, "GET") { return 1; }
        if bytes.equal(method, "POST") { return 2; }
    }
    return 0;
}

fn count_json[&h](heap: &!h Heap, n: int) -> [heap] buffer.Buffer {
    var w = json.writer(heap, 32);
    w = json.begin_object(heap, w);
    w = json.put_key(heap, w, "count");
    w = json.put_int(heap, w, n);
    w = json.end_object(heap, w);
    return json.finish(w);
}

fn app_handle[&h, &a, &q, &t, &b](heap: &!h Heap, app: &!a App, request: &q [byte], table: &t [int], body: &b [byte], now_ms: int, out: buffer.Buffer) -> [heap] buffer.Buffer {
    let keep = http.keeps_alive(table);
    let action = counter_action(http.method(request, table), http.path(request, table));
    if action == 0 {
        return server.failure(heap, out, 404, "not found", keep);
    }
    let cs = contents(app.counts);
    if action == 2 {
        cs[0] = cs[0] + 1;
    }
    let reply_body = count_json(heap, cs[0]);
    var answer = out;
    borrow reply_body as &rb in {
        answer = server.reply(heap, answer, 200, buffer.bytes(rb), keep);
    }
    buffer.drop(heap, reply_body);
    return answer;
}

fn app_drop[&h](heap: &!h Heap, app: App) -> [heap] int {
    let App { counts } = app;
    unbox_slice(heap, counts);
    return 0;
}
```
