#!/usr/bin/env python3
"""The part of a cancho-code agent that is not a particular model API (scripts/agent-ollama.sh, scripts/agent-mistral.sh).

An agent is a command the driver runs with the project file as its argument; it must replace that file with a better one or exit
non-zero. What is shared, and gated once (scripts/test-agent-ollama.sh, scripts/test-agent-mistral.sh):
  - the prompt: an optional primer, the unit's task (`<file>.task`) or the instruction to fix, the checker's current refusals with
    the offending source line and a caret (`<file>.feedback`), and the file;
  - what a reply is: the program inside it (fences, `</think>` markers and prose are cut), or no sample at all (reasoning, a reply
    cut off by the generation bound);
  - three samples at most, and the project is never written over with anything that is not a program.
A particular agent supplies `ask(primer, prompt) -> (text, cut_off)`; `primer` is the language page (or "") and is kept apart from the rest
of the prompt so an API that can cache a repeated prefix is able to."""
import json, os, re, ssl, sys


# Where an operating system keeps its root certificates, for a Python that has none of its own (the python.org build for macOS ships no
# cert.pem until its "Install Certificates" script is run, and the driver's agent finds that Python on its minimal PATH).
CA_BUNDLES = ["/etc/ssl/cert.pem", "/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt",
              "/opt/homebrew/etc/openssl@3/cert.pem", "/usr/local/etc/openssl@3/cert.pem"]


def ssl_context():
    """A verifying TLS context. When this Python trusts nothing, the system's own bundles are added; verification is never turned off.
    AGENT_CA_BUNDLES (a colon-separated list) names more bundles to try first: for tests with a private CA."""
    ctx = ssl.create_default_context()
    if ctx.cert_store_stats().get("x509_ca", 0) == 0:
        for path in [p for p in os.environ.get("AGENT_CA_BUNDLES", "").split(":") if p] + CA_BUNDLES:
            if os.path.isfile(path):
                try:
                    ctx.load_verify_locations(cafile=path)
                except (ssl.SSLError, OSError):
                    pass
    return ctx


def feedback_text(file, source):
    """The checker's current refusals, one line each; if the feedback is not the JSON the checker normally prints, the text itself."""
    feedback = ""
    try:
        raw = open(file + ".feedback", encoding="utf-8").read()
        try:
            refusals = json.loads(raw).get("refused", [])
            lines = source.split("\n")
            for r in refusals[:8]:
                line, col = r["position"]["line"], r["position"]["column"]
                feedback += "- line %d, column %d: %s (rule %s)\n" % (line, col, r["message"], r["rule"])
                # The source line itself, with a caret under the column: "line 9, column 39" is hard to find by counting.
                if 1 <= line <= len(lines):
                    feedback += "    " + lines[line - 1] + "\n    " + " " * (col - 1) + "^\n"
        except (ValueError, KeyError, AttributeError):
            feedback = raw[:1500]
    except OSError:
        pass
    return feedback


def build_prompt(file, name, primer_env):
    source = open(file, encoding="utf-8").read()
    feedback = feedback_text(file, source)
    # An optional primer, first in the prompt: the language's own page for an agent (`cancho agent-guidelines > file`). A model that
    # has never seen cancho repeats the same refusal; an unreadable primer is an error, not a silent skip, so a typo in the path cannot
    # pass for a model that "did not use" it.
    primer = ""
    if os.environ.get(primer_env):
        try:
            primer = open(os.environ[primer_env], encoding="utf-8").read() + "\n\n"
        except OSError as e:
            sys.stderr.write("%s: cannot read %s: %s\n" % (name, primer_env, e))
            sys.exit(1)
    # A project unit leaves its task beside the file (docs/project.md): what to write. It goes ahead of the file.
    task = ""
    try:
        task = open(file + ".task", encoding="utf-8").read().strip()
    except OSError:
        pass
    if task:
        prompt = ("Your task, for the cancho program below:\n" + task + "\n\nReply with the complete file, with the task done, and nothing else: "
                  "no markdown fences, no explanation.\n")
    else:
        prompt = ("The cancho program below is refused by its compiler. Reply with the complete corrected file and nothing else: "
                  "no markdown fences, no explanation.\n")
    if feedback:
        prompt += "The current output of the compiler and of the checks on the file:\n" + feedback
    return primer, prompt + "---\n" + source + "---\n"


def save_raw(raw_env, text, reason):
    """<raw_env>=<file>: keep every raw reply, whole, before anything is cut out of it (the trail records only the verdict on it)."""
    path = os.environ.get(raw_env)
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write("=== reply (stopped because: %s)\n%s\n" % (reason, text))


def program(answer):
    """The file in a model's answer, or None when there is no program in it."""
    # Some models leak their reasoning markers into the answer (`</think>`): what follows the last one is the answer; when nothing there
    # is a program, the program is what precedes it (the reply ended on the tag, after a closing fence).
    if "</think>" in answer:
        head, tail = answer.rsplit("</think>", 1)
        after = program(tail) if tail.strip() else None
        return after if after is not None else program(head)
    answer = answer.replace("<think>", "")
    # A markdown fence is the one shape a model reliably adds and the checker reliably refuses, and it often explains first: when the
    # answer holds fenced blocks the file is the longest of them (the program, not the prose around it); with none it is the answer.
    blocks = re.findall(r"```[A-Za-z0-9_+-]*[ \t]*\n(.*?)```", answer, re.S)
    if blocks:
        answer = max(blocks, key=len)
    # no complete block: a fence may still be left at either end (an unopened or an unclosed one)
    answer = re.sub(r"^\s*```[A-Za-z0-9_+-]*[ \t]*\n", "", answer)
    answer = re.sub(r"\n[ \t]*```\s*$", "", answer)
    # A reply with no program in it is the model's own reasoning (one of ours thinks aloud in the answer about one call in four, until the
    # generation bound cuts it off): not a file. A preamble before the program is cut: the file starts at its `edition` line.
    m = re.search(r"^edition \d+;", answer, re.M)
    return answer[m.start():].strip("\n") if m else None


def run(file, ask, name, primer_env, raw_env, bound_env):
    """Up to three samples: a reply without a program, or cut off, is retried and never written over the project."""
    primer, prompt = build_prompt(file, name, primer_env)
    answer = None
    for attempt in range(3):
        try:
            got, cut_off = ask(primer, prompt)
        except SystemExit:
            raise
        except Exception as e:
            sys.stderr.write("%s: %s\n" % (name, e))
            sys.exit(1)
        if cut_off:
            sys.stderr.write("%s: sample %d was cut off by the generation bound (%s)\n" % (name, attempt + 1, bound_env))
            continue
        answer = program(got)
        if answer is not None:
            break
        sys.stderr.write("%s: sample %d has no program in it (reasoning, not a file)\n" % (name, attempt + 1))
    if answer is None:
        sys.exit(1)
    tmp = file + ".agent.tmp"
    open(tmp, "w", encoding="utf-8").write(answer + "\n")
    os.replace(tmp, file)
