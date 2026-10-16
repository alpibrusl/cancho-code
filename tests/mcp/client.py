#!/usr/bin/env python3
"""A minimal MCP client for checking a registration by hand (a test client; the server has no Python on its path).

    client.py <.mcp.json> <server name> [tool [json arguments]]

Starts the server as the file says (command, args, env), does the handshake of revision 2025-11-25 (initialize, then the initialized
notification), lists the tools, and, when a tool is named, calls it and prints the text it returned. Every message is one line.
"""
import json, os, subprocess, sys

cfg = json.load(open(sys.argv[1]))["mcpServers"][sys.argv[2]]
env = dict(os.environ); env.update(cfg.get("env", {}))
p = subprocess.Popen([cfg["command"]] + cfg.get("args", []), stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env, text=True)
n = 0
def call(method, params=None):
    global n
    n += 1
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": n, "method": method, "params": params or {}}) + "\n"); p.stdin.flush()
    r = json.loads(p.stdout.readline())
    assert r["id"] == n, r
    return r
r = call("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "client.py", "version": "1"}})
print("initialize:", r["result"]["protocolVersion"], r["result"]["serverInfo"], list(r["result"]["capabilities"]))
p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n"); p.stdin.flush()
r = call("tools/list")
print("tools:", ", ".join(t["name"] for t in r["result"]["tools"]))
if len(sys.argv) > 3:
    r = call("tools/call", {"name": sys.argv[3], "arguments": json.loads(sys.argv[4]) if len(sys.argv) > 4 else {}})
    print("isError:", r["result"]["isError"])
    print(r["result"]["content"][0]["text"])
p.stdin.close()
print("server exit:", p.wait())
