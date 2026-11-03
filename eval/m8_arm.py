#!/usr/bin/env python3
"""Run one arm of experiment M8 (cancho-gpu docs/roadmap-models.md section 7): the 13 hand-planned items, N runs each, a local model behind an Ollama-API endpoint.

    CANCHO=<compiler> python3 eval/m8_arm.py --arm A --model base --primer guidelines.md --out RUNS_DIR [--runs 5] [--port 11435] [--tools DIR]

Each run is `run_item.py <item> --provider ollama --plan eval/<item>/plan.json --label <arm>`, in the order of ITEMS then run number, with the settings the experiment fixes (--num-ctx 16384, --max-tokens 2048, 6 attempts, 300 s a call, one unit at a
time, complete-file replies). A run whose directory already holds `result.json` is skipped, so a killed arm resumes. Arms B and D pass no --primer. Prints one line per run (run_item's)."""
import argparse, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ITEMS = ["basics", "tokenbucket", "roman", "base64", "duration", "editdistance", "sortedmap", "jsonptr", "expr", "glob", "semver", "ini", "csv"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arm", required=True)
    ap.add_argument("--model", required=True, help="the model name the endpoint serves")
    ap.add_argument("--primer", help="the primer file (arms A and C); none for B and D")
    ap.add_argument("--out", required=True)
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--port", default="11435")
    ap.add_argument("--max-tokens", default="2048")
    ap.add_argument("--num-ctx", default="16384")
    ap.add_argument("--tools", default="/tmp/evaltools")
    ap.add_argument("--items", help="comma-separated subset")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    for item in (a.items.split(",") if a.items else ITEMS):
        for n in range(1, a.runs + 1):
            if os.path.exists(os.path.join(a.out, "%s-%s-%d" % (a.arm, item, n), "result.json")):
                continue
            cmd = [sys.executable, os.path.join(HERE, "run_item.py"), item, "--provider", "ollama", "--model", a.model, "--max-tokens", a.max_tokens,
                   "--runs", "1", "--first", str(n), "--label", a.arm, "--out", a.out, "--tools", a.tools, "--agent-arg=--num-ctx", "--agent-arg=" + a.num_ctx,
                   "--agent-arg=--port", "--agent-arg=" + a.port, "--timeout", "3600"]
            if a.primer:
                cmd += ["--primer", a.primer]
            subprocess.run(cmd, check=False)


if __name__ == "__main__":
    main()
