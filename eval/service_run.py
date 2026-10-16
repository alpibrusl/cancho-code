#!/usr/bin/env python3
"""Build a service project and run its scenarios.

    CANCHO=<compiler> python3 eval/service_run.py accept|attack <service> <project.cho>

<service> is a directory eval/services/<service>/ holding `accept.py` (the scenarios the builder is shown: they are the brief's own, and their failures
are the feedback to the builder) and `attack.py` (hidden: written before any run, never shown). Each is called as `python3 accept.py <binary> <project.cho>`
and prints failures then `[ACCEPTANCE] n/m hold` / `[ATTACK] n/m hold`; exit 0 only if all hold.

This is what `fix`'s acceptance hook runs for a service (docs/parity.md P7): `fix <checker> project.cho <agent> <attempts> <secs> "python3 eval/service_run.py accept <service>" 600 "<skeleton main.cho> <server.cho>"` (the driver appends the project file to the acceptance command).
A program that checks but does not build, or builds but does not serve, fails here with the reason."""
import os, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
LIMIT = 3500

def service_libs(service):
    """The library source files a service is built with, beside http-server: the lines of eval/services/<service>/libs.txt (paths relative to the
    repository root), absolute. A service with no libs.txt has none."""
    p = os.path.join(HERE, "services", service or "", "libs.txt")
    if not service or not os.path.exists(p): return []
    return [os.path.join(os.path.dirname(HERE), l.strip()) for l in open(p) if l.strip() and not l.startswith("#")]

def service_files(cancho, project, bare=False, service=None):
    """What a service is built from: the project's application, the fixed skeleton (the server loop and `main`), and the http-server package and the service's libraries (its libs.txt).
    `bare`: the project imports what it uses (a decomposed service, docs/project.md), so the skeleton is main_bare.cho, main.cho without its imports."""
    pk = os.environ.get("CANCHO_PACKAGES", "")
    if not os.path.isdir(pk):
        bin_ = subprocess.run(["which", cancho], capture_output=True, text=True).stdout.strip() or cancho
        for up in (2, 3):
            cand = os.path.join(os.path.dirname(os.path.realpath(bin_)), *([".."] * up), "packages")
            if os.path.isdir(cand): pk = os.path.normpath(cand); break
    return [project, os.path.join(HERE, "services", "skeleton", "main_bare.cho" if bare else "main.cho"), os.path.join(pk, "http-server", "server.cho")] + service_libs(service)

def main():
    argv = [a for a in sys.argv[1:] if a != "--bare"]
    bare = len(argv) != len(sys.argv) - 1
    if len(argv) < 3 or argv[0] not in ("accept", "attack"):
        sys.exit("usage: service_run.py accept|attack [--bare] <service> <project.cho>")
    mode, service, project = argv[0], argv[1], os.path.abspath(argv[2])
    cancho = os.environ.get("CANCHO", "cancho")
    script = os.path.join(HERE, "services", service, "accept.py" if mode == "accept" else "attack.py")
    if not os.path.exists(script):
        sys.exit("service_run: no %s" % script)
    out = tempfile.mkdtemp(prefix="svcbuild-")
    binary = os.path.join(out, "service")
    files = service_files(cancho, project, bare, service)
    b = subprocess.run([cancho, "build", "--std", "--backend", "cranelift"] + files + ["-o", binary], capture_output=True, text=True)
    if b.returncode != 0:
        first = next((l for l in b.stderr.splitlines() if "error" in l), b.stderr.strip()[-300:])
        print("the project does not build: %s" % first[:600])
        print("[%s] 0/1 hold" % ("ACCEPTANCE" if mode == "accept" else "ATTACK"))
        sys.exit(1)
    sys.path.insert(0, HERE)
    import svc
    ok, why = svc.authority_ok(cancho, files)
    env = dict(os.environ, CANCHO=cancho, SVC_AUTHORITY_OK="1" if ok else "0", SVC_AUTHORITY_WHY=why)
    if mode == "accept":
        # the output is the builder's feedback and the driver caps what it reads (4096 bytes)
        p = subprocess.run([sys.executable, script, binary, project], env=env, capture_output=True, text=True)
        text = p.stdout + p.stderr
        if len(text) > LIMIT: text = text[:LIMIT - 400] + "\n... (output cut)\n" + text[-380:]   # the head names the first failures, the tail is the result line
        sys.stdout.write(text)
        sys.exit(p.returncode)
    p = subprocess.run([sys.executable, script, binary, project], env=env)
    sys.exit(p.returncode)

if __name__ == "__main__":
    main()
