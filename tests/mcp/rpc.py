#!/usr/bin/env python3
"""The gate's pipe driver (scripts/test-mcp.sh): run the server once, feed it a file of request lines on standard input, close the input,
and write what it printed to a file. It is a test client only; the server has no Python on its path.

    rpc.py <timeout seconds> <response file> <request file> -- <server command...>

Exit status: the server's, or 124 when it did not end within the timeout (it is then killed), or 125 when it printed more than 8 MiB
(a server that never ends its loop on end of input). Standard error of the server is appended to <response file>.err.
"""
import subprocess, sys, threading, time

timeout, resp, req = float(sys.argv[1]), sys.argv[2], sys.argv[3]
cmd = sys.argv[sys.argv.index("--") + 1:]
data = open(req, "rb").read() if req != "-" else b""
err = open(resp + ".err", "ab")
p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err)

def feed():
    try:
        p.stdin.write(data)
        p.stdin.close()
    except BrokenPipeError:
        pass
threading.Thread(target=feed, daemon=True).start()

out, size, flooded = open(resp, "wb"), 0, False
deadline = time.time() + timeout
killer_done = False
def watchdog():
    while p.poll() is None:
        if time.time() > deadline or flooded:
            p.kill()
            return
        time.sleep(0.05)
threading.Thread(target=watchdog, daemon=True).start()
while True:
    chunk = p.stdout.read1(65536)
    if not chunk:
        break
    size += len(chunk)
    if size > 8 * 1024 * 1024:
        flooded = True
        p.kill()
        break
    out.write(chunk)
out.close()
rc = p.wait()
if flooded:
    sys.exit(125)
if time.time() > deadline:
    sys.exit(124)
sys.exit(rc)
