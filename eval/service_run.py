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

def service_files(cancho, project):
    """What a service is built from: the project's application, the fixed skeleton (the server loop and `main`), and the http-server package."""
    pk = os.environ.get("CANCHO_PACKAGES", "")
    if not os.path.isdir(pk):
        bin_ = subprocess.run(["which", cancho], capture_output=True, text=True).stdout.strip() or cancho
        for up in (2, 3):
            cand = os.path.join(os.path.dirname(os.path.realpath(bin_)), *([".."] * up), "packages")
            if os.path.isdir(cand): pk = os.path.normpath(cand); break
    return [project, os.path.join(HERE, "services", "skeleton", "main.cho"), os.path.join(pk, "http-server", "server.cho")]

def main():
    if len(sys.argv) < 4 or sys.argv[1] not in ("accept", "attack"):
        sys.exit("usage: service_run.py accept|attack <service> <project.cho>")
    mode, service, project = sys.argv[1], sys.argv[2], os.path.abspath(sys.argv[3])
    cancho = os.environ.get("CANCHO", "cancho")
    script = os.path.join(HERE, "services", service, "accept.py" if mode == "accept" else "attack.py")
    if not os.path.exists(script):
        sys.exit("service_run: no %s" % script)
    out = tempfile.mkdtemp(prefix="svcbuild-")
    binary = os.path.join(out, "service")
    files = service_files(cancho, project)
    b = subprocess.run([cancho, "build", "--std", "--backend", "cranelift"] + files + ["-o", binary], capture_output=True, text=True)
    if b.returncode != 0:
        first = next((l for l in b.stderr.splitlines() if "error" in l), b.stderr.strip()[-300:])
        print("the project does not build: %s" % first)
        print("[%s] 0/1 hold" % ("ACCEPTANCE" if mode == "accept" else "ATTACK"))
        sys.exit(1)
    sys.path.insert(0, HERE)
    import svc
    ok, why = svc.authority_ok(cancho, files)
    env = dict(os.environ, CANCHO=cancho, SVC_AUTHORITY_OK="1" if ok else "0", SVC_AUTHORITY_WHY=why)
    p = subprocess.run([sys.executable, script, binary, project], env=env)
    sys.exit(p.returncode)

if __name__ == "__main__":
    main()
