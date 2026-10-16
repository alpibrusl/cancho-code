#!/usr/bin/env python3
"""Canned JSON-RPC for the MCP gate (scripts/test-mcp.sh). A test client only.

    cases.py schema <tools.json>           requests: every tool called with each known and a few unknown property names, value 123
    cases.py schema-check <tools.json> <responses>
    cases.py names                          requests: bad run names and unit names to every tool that takes them
    cases.py names-check <responses>
    cases.py paths                          requests: bad brief paths
    cases.py paths-check <responses>
"""
import json, sys

def req(i, name, args):
    return json.dumps({"jsonrpc": "2.0", "id": i, "method": "tools/call", "params": {"name": name, "arguments": args}})

def tool_json(line):
    r = json.loads(line)
    return r["result"]["isError"], json.loads(r["result"]["content"][0]["text"])

EXTRAS = ["force", "key_file", "provider", "model", "path", "command"]
BAD_NAMES = ["..", "../x", "a/b", "-x", "", ".hidden", "a b", "a;b", "$(id)", "a\u0000b", "x" * 65, "a..b", "a\nb", "café", "a`id`", "/etc"]
BAD_PATHS = ["../x", "/etc/passwd", "a/../b", "-x", "a b", "x;y", "$(id)", "a//b", "./a", ".hid/en", "a/", "a\u0000b", "x" * 201, "a/-b", "..", "a\\b"]

def main():
    mode = sys.argv[1]
    if mode == "schema":
        tools = json.load(open(sys.argv[2]))["tools"]
        i = 0
        for t in tools:
            props = list(t["inputSchema"]["properties"])
            for k in props + EXTRAS:
                i += 1
                print(req(i, t["name"], {k: 123}))
    elif mode == "schema-check":
        tools = json.load(open(sys.argv[2]))["tools"]
        lines = [l for l in open(sys.argv[3]) if l.strip()]
        i, bad = 0, 0
        for t in tools:
            props = list(t["inputSchema"]["properties"])
            for k in props + EXTRAS:
                err, body = tool_json(lines[i]); i += 1
                want = "mcp.wrong-type" if k in props else "mcp.unknown-argument"
                if not err or body["error"]["rule"] != want:
                    print("%s with %s: wanted %s, got %s" % (t["name"], k, want, body)); bad += 1
        print("BAD" if bad else "OK")
    elif mode == "names":
        i = 0
        for n in BAD_NAMES:
            for tool in ["cancho_build_start", "cancho_status", "cancho_stop", "cancho_result"]:
                i += 1
                a = {"name": n}
                if tool == "cancho_build_start":
                    a["brief_text"] = "hi"
                print(req(i, tool, a))
            for tool in ["cancho_unit_story", "cancho_retry", "cancho_patch"]:
                for which in ("name", "unit"):
                    i += 1
                    a = {"name": "ok1", "unit": "u1"}
                    a[which] = n
                    if tool == "cancho_patch":
                        a["code"] = "fn f() -> [] int { return 1; }"
                    print(req(i, tool, a))
    elif mode == "names-check":
        lines = [l for l in open(sys.argv[2]) if l.strip()]
        want = len(BAD_NAMES) * (4 + 6)
        bad = 0 if len(lines) == want else 1
        for l in lines:
            err, body = tool_json(l)
            if not err or body["error"]["rule"] != "mcp.bad-name":
                print("not refused as a bad name:", l[:200]); bad += 1
        print("BAD" if bad else "OK")
    elif mode == "call":
        # cases.py call <tool> key=value ... (values are strings; @file reads the value from a file)
        args = {}
        for kv in sys.argv[3:]:
            k, v = kv.split("=", 1)
            args[k] = open(v[1:]).read() if v.startswith("@") else v
        print(req(1, sys.argv[2], args))
    elif mode == "paths":
        for i, p in enumerate(BAD_PATHS):
            print(req(i + 1, "cancho_build_start", {"name": "pp", "brief_path": p}))
    elif mode == "paths-check":
        lines = [l for l in open(sys.argv[2]) if l.strip()]
        bad = 0 if len(lines) == len(BAD_PATHS) else 1
        for l in lines:
            err, body = tool_json(l)
            if not err or body["error"]["rule"] != "mcp.bad-path":
                print("not refused as a bad path:", l[:200]); bad += 1
        print("BAD" if bad else "OK")

main()
