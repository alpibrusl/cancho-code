#!/usr/bin/env python3
"""Black-box harness for a built cancho service: start the binary, send requests, check statuses and bodies the BRIEF promises.

Adapted from lex-code's backlog/svc.py (same `check` / `note` / `finish` shape, so its attack scripts port with a different constructor).

    s = Svc(binary, ["--tokens", "tokA:acme,tokB:globex"], port=8811)      # started with --port 8811 added; loopback; waits for the port
    if not s.up: s.note("server starts", False, "did not start"); s.finish()
    s.check("no token -> 401", s.req("GET", "/jobs"), 401)
    s.finish()                                                             # prints failures and `[<label>] n/m hold`; exit 0 only if all hold

A cancho service is configured by flags (cancho programs have no environment): `--port N` is always added, `--host H` only when asked for.
`label` is what the last line says (`ACCEPTANCE` for the scenarios the builder is shown, `ATTACK` for the hidden ones).
Authority: `authority_ok(source_files)` runs `cancho authority` and refuses a service that can spawn a process, write files, or call foreign code."""
import atexit, http.client, json, os, signal, socket, subprocess, sys, tempfile, time

ALLOWED_EFFECTS = {"args", "heap", "clock", "net_in", "conn_accept", "conn_read", "conn_write", "poll", "io_write", "err_write", "net_out"}

class Svc:
    def __init__(self, binary, args, port, label="ATTACK", host=None, wait_s=15):
        self.binary, self.port, self.results, self.proc, self.label = binary, port, [], None, label
        self.tmp = tempfile.mkdtemp(prefix="svc-")
        argv = [binary, "--port", str(port)] + ([] if host is None else ["--host", host]) + [a.replace("{tmp}", self.tmp) for a in args]
        self.log = open(os.path.join(self.tmp, "server.log"), "w")
        self.proc = subprocess.Popen(argv, cwd=self.tmp, env={"PATH": "/usr/bin:/bin"}, stdout=self.log, stderr=subprocess.STDOUT, start_new_session=True)
        atexit.register(self.stop)
        self.up = False
        for _ in range(int(wait_s / 0.2)):
            if self.proc.poll() is not None:
                break
            try:
                socket.create_connection(("127.0.0.1", port), 0.3).close(); self.up = True; return
            except OSError:
                time.sleep(0.2)
        print("server did not start (exit %s):" % self.proc.poll(), open(os.path.join(self.tmp, "server.log")).read()[-400:])

    def req(self, method, path, headers=None, body=None, raw_body=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=15)
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

    def raw(self, data, read=4096):
        """Send raw bytes on a fresh connection and return what comes back (for oversize bodies, malformed heads)."""
        try:
            c = socket.create_connection(("127.0.0.1", self.port), 5)
            c.sendall(data); c.settimeout(5)
            try: out = c.recv(read)
            except OSError: out = b""
            c.close(); return out.decode("utf-8", "replace")
        except OSError as ex:
            return "<%s>" % ex

    def j(self, text):
        try: return json.loads(text)
        except Exception: return None

    def check(self, name, resp, status, contains=None, excludes=None, test=None):
        st, text = resp
        ok_status = st in status if isinstance(status, (list, tuple, set)) else st == status
        why = []
        if not ok_status: why.append("status %s, expected %s" % (st, status))
        if ok_status and contains and contains not in text: why.append("body lacks %r" % contains)
        if excludes and excludes in text: why.append("body contains %r" % excludes)
        if ok_status and test:
            try:
                if not test(self.j(text)): why.append("body check failed")
            except Exception as ex: why.append("body check error %s" % ex)
        self.results.append((name, not why, "; ".join(why) + (" - %s" % text[:90] if why else "")))
        return resp

    def note(self, name, ok, why=""):
        self.results.append((name, ok, why))

    def listens_on_loopback_only(self):
        try:
            out = subprocess.run(["lsof", "-nP", "-iTCP:%d" % self.port, "-sTCP:LISTEN"], capture_output=True, text=True).stdout
        except Exception: return None
        lines = [l for l in out.splitlines()[1:] if l.strip()]
        if not lines: return None
        return all("127.0.0.1:" in l or "[::1]:" in l for l in lines)

    def stop(self):
        if self.proc and self.proc.poll() is None:
            try: os.killpg(self.proc.pid, signal.SIGTERM)
            except Exception: pass

    def finish(self):
        self.stop()
        bad = [r for r in self.results if not r[1]]
        for n, _, w in bad: print("  - %s: %s" % (n, w))
        print("[%s] %d/%d hold" % (self.label, len(self.results) - len(bad), len(self.results)))
        sys.exit(0 if not bad else 1)

def authority_ok(cancho, files):
    """(ok, why): the service's declared authority is only what a server needs. No process, no file writes, no foreign code."""
    p = subprocess.run([cancho, "authority", "--std", "--output", "json"] + list(files), capture_output=True, text=True)
    try:
        r = json.loads(p.stdout)
    except Exception:
        return False, "cancho authority gave no report: %s" % (p.stderr.strip().splitlines() or [""])[-1][:120]
    extra = sorted(set(r.get("effects", [])) - ALLOWED_EFFECTS)
    if extra: return False, "the service declares authority a server does not need: %s" % ", ".join(extra)
    return True, ""
