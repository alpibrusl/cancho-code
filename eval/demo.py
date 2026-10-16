#!/usr/bin/env python3
"""The demo step: build a service project, start it, walk through a scripted session, show every request as a curl command with the real response.

    CANCHO=<compiler> python3 eval/demo.py <service> <project.cho> [--port N] [--keep]

The session is eval/services/<service>/demo.json: {"intro": "...", "steps": [{"title", "method", "path", "headers": {}, "body": <json or string>, "save": {"name": "key"}}]}.
`save` keeps a top-level key of a JSON response; `{ts}` is the current Unix time in seconds; a step with `hmac` ({header, secret, over, prefix}) gets a header holding the HMAC-SHA256 of `over` (with `{ts}` and `{body}` replaced); `{name}` in a later path, header or body is replaced by it. `--keep` leaves the server running on the port
and prints how to stop it; otherwise it is stopped when the session ends. Exit 0 when the service started and every step got an HTTP answer (the demo shows
behaviour; judging it is the acceptance and the attack)."""
import argparse, hashlib, hmac, http.client, json, os, shlex, signal, socket, subprocess, sys, tempfile, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import service_run

def sub(x, env):
    if isinstance(x, str):
        for k, v in env.items(): x = x.replace("{%s}" % k, str(v))
        return x
    if isinstance(x, dict): return {k: sub(v, env) for k, v in x.items()}
    if isinstance(x, list): return [sub(v, env) for v in x]
    return x

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("service"); ap.add_argument("project")
    ap.add_argument("--port", type=int, default=8080); ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    cancho = os.environ.get("CANCHO", "cancho")
    sdir = os.path.join(HERE, "services", a.service)
    demo = json.load(open(os.path.join(sdir, "demo.json")))
    launch = json.load(open(os.path.join(sdir, "launch.json")))
    project = os.path.abspath(a.project)
    files = service_run.service_files(cancho, project, False, a.service)
    out = tempfile.mkdtemp(prefix="demo-"); binary = os.path.join(out, "service")
    b = subprocess.run([cancho, "build", "--std", "--backend", "cranelift"] + files + ["-o", binary], capture_output=True, text=True)
    if b.returncode != 0:
        print("the project does not build:\n" + "\n".join(l for l in b.stderr.splitlines() if "error" in l)[:600]); sys.exit(1)
    argv = [binary, "--port", str(a.port)] + [x.replace("{tmp}", out) for x in launch["args"]]
    log = open(os.path.join(out, "server.log"), "w")
    proc = subprocess.Popen(argv, cwd=out, env={"PATH": "/usr/bin:/bin"}, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    up = False
    for _ in range(75):
        if proc.poll() is not None: break
        try: socket.create_connection(("127.0.0.1", a.port), 0.3).close(); up = True; break
        except OSError: time.sleep(0.2)
    if not up:
        print("the service did not start:", open(os.path.join(out, "server.log")).read()[-300:]); sys.exit(1)
    print("== %s ==\n%s\n$ %s\n" % (a.service, demo.get("intro", ""), " ".join(shlex.quote(x) for x in [os.path.basename(binary)] + argv[1:])))
    env = {}; bad = 0
    for st in demo["steps"]:
        env["ts"] = str(int(time.time()))
        st = sub(st, env)
        h = dict(st.get("headers", {})); body = st.get("body")
        data = None if body is None else (body if isinstance(body, str) else json.dumps(body))
        if "hmac" in st:
            m = st["hmac"]
            over = m["over"].replace("{body}", data or "")
            h[m["header"]] = m.get("prefix", "") + hmac.new(m["secret"].encode(), over.encode(), hashlib.sha256).hexdigest()
        if data is not None and "Content-Type" not in h: h["Content-Type"] = "application/json"
        curl = "curl -s -i -X %s http://127.0.0.1:%d%s" % (st["method"], a.port, st["path"]) + "".join(" -H %s" % shlex.quote("%s: %s" % kv) for kv in h.items()) + ("" if data is None else " -d %s" % shlex.quote(data))
        print("# %s\n$ %s" % (st.get("title", ""), curl))
        c = http.client.HTTPConnection("127.0.0.1", a.port, timeout=10)
        try:
            c.request(st["method"], st["path"], body=data.encode() if data is not None else None, headers=h)
            r = c.getresponse(); text = r.read().decode("utf-8", "replace"); print("HTTP %d\n%s\n" % (r.status, text.strip()))
            try: j = json.loads(text)
            except Exception: j = None
            for name, key in st.get("save", {}).items():
                if isinstance(j, dict) and key in j: env[name] = j[key]
        except Exception as ex:
            bad += 1; print("no answer: %s\n" % ex)
        finally: c.close()
    if a.keep:
        print("The service keeps running on http://127.0.0.1:%d (pid %d). Stop it with: kill %d" % (a.port, proc.pid, proc.pid))
        sys.exit(1 if bad else 0)
    os.killpg(proc.pid, signal.SIGTERM)
    print("(stopped)")
    sys.exit(1 if bad else 0)

if __name__ == "__main__":
    main()
