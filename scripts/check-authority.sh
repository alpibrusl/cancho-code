#!/bin/bash
# Pin the authority report (design §8). `cancho authority` says what a program can do: the capabilities it
# performs, with their arguments, whether the report is bounded, and the foreign symbols it calls.
# `docs/authority*.json` is that report as of the last time a person approved it. This script regenerates it
# from the sources and fails on any difference, so a new capability, a new argument or a new foreign call is
# a red diff that only a commit of the new file turns green: that commit is the approval.
#
#   scripts/check-authority.sh             compare the `fix` front door to docs/authority.json
#   scripts/check-authority.sh --project   compare the project driver (it spawns the checker and the agent, reads and writes the work directory; no network) to docs/authority-project.json
#   scripts/check-authority.sh --plan      compare the plan checker (it reads one file and prints; no process, no network) to docs/authority-plan.json
#   scripts/check-authority.sh --provider  compare the provider (the one reachable host class) to docs/authority-provider.json
#   scripts/check-authority.sh --agent     compare the native agent (src/cancho_agent.cho: reads its files, writes the project, one TLS host class) to docs/authority-agent.json
#   scripts/check-authority.sh --update    write the file (after reading what changed); combine with --provider
#   scripts/check-authority.sh --prove     prove the pin can fail: perturb a copy of the pinned file and require a red diff
#
#   CANCHO           the compiler binary         (default: cancho on PATH; the commit in .cancho-rev)
#   CANCHO_PACKAGES  the compiler's packages/    (default: next to the binary; --provider only)
#
# What `fix` is pinned over: tests/programs/fix.cho with the driver and its modules. It has no network and no
# foreign code; it can spawn one directory's worth of programs (`exec("")`) and read and write files, and the
# report cannot bound which: those arguments are the run's own (the checker's path, the project file), so the
# report says `""` and the tests cover the rest. Said plainly here, as the other cancho tools say it.
# What is left out of the pinned file: the list of provably pure functions and the three counts. They change
# with every function anyone adds and say nothing about authority.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
CANCHO=${CANCHO:-cancho}
command -v "$CANCHO" >/dev/null 2>&1 || { echo "check-authority: no cancho on PATH; set CANCHO=" >&2; exit 2; }

mode=compare
variant=fix
for arg in "$@"; do
  case "$arg" in
    --update) mode=update ;;
    --prove) mode=prove ;;
    --provider) variant=provider ;;
    --agent) variant=agent ;;
    --plan) variant=plan ;;
    --project) variant=project ;;
    *) echo "usage: $0 [--update | --prove] [--provider | --agent | --plan | --project]" >&2; exit 2 ;;
  esac
done

if [ "$variant" = provider ]; then
  pinned=$here/docs/authority-provider.json
  C="${CANCHO_PACKAGES:-}"
  [ -d "$C" ] || C="$(dirname "$(dirname "$(command -v "$CANCHO")")")/packages"
  [ -d "$C" ] || { echo "check-authority: no cancho packages found; set CANCHO_PACKAGES" >&2; exit 2; }
  files=("$here/tests/programs/provider_gate.cho" "$here/src/provider.cho" "$here/vendor/fetch_io.cho"
    "$C"/http-client/*.cho "$C"/tls/*.cho "$C"/x509/*.cho)
elif [ "$variant" = agent ]; then
  pinned=$here/docs/authority-agent.json
  C="${CANCHO_PACKAGES:-}"
  [ -d "$C" ] || C="$(dirname "$(dirname "$(command -v "$CANCHO")")")/packages"
  [ -d "$C" ] || { echo "check-authority: no cancho packages found; set CANCHO_PACKAGES" >&2; exit 2; }
  files=("$here/src/cancho_agent.cho" "$here/src/anthropic.cho" "$here/src/ollama.cho" "$here/src/prompt.cho" "$here/src/planprompt.cho" "$here/src/plan.cho" "$here/src/provider.cho" "$here/src/reply.cho"
    "$here/vendor/fetch_io.cho" "$C"/http-client/*.cho "$C"/tls/*.cho "$C"/x509/*.cho)
elif [ "$variant" = plan ]; then
  pinned=$here/docs/authority-plan.json
  files=("$here/tests/programs/plancheck.cho" "$here/src/plan.cho")
elif [ "$variant" = project ]; then
  pinned=$here/docs/authority-project.json
  files=("$here/tests/programs/project.cho" "$here/src/project.cho" "$here/src/plan.cho" "$here/src/driver.cho" "$here/src/checker.cho"
    "$here/src/signature.cho" "$here/src/loop_check.cho" "$here/src/snapshot.cho" "$here/src/trail.cho" "$here/src/acceptance.cho")
else
  pinned=$here/docs/authority.json
  files=("$here/tests/programs/fix.cho" "$here/src/driver.cho" "$here/src/checker.cho" "$here/src/signature.cho"
    "$here/src/loop_check.cho" "$here/src/snapshot.cho" "$here/src/trail.cho" "$here/src/acceptance.cho")
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

"$CANCHO" authority "${files[@]}" --std --output json > "$work/raw.json"
python3 - "$work/raw.json" > "$work/report.json" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
if "unbounded_by" not in report:
    sys.exit("check-authority: this compiler's report has no `unbounded_by`; use the compiler in .cancho-rev")
for volatile in ("pure", "folded_operators", "folded_calls", "functions"):
    report.pop(volatile, None)
print(json.dumps(report, indent=2))
PY

if [ "$mode" = update ]; then
  cp "$work/report.json" "$pinned"
  echo "check-authority: wrote ${pinned#"$here"/}" >&2
  exit 0
fi

[ -f "$pinned" ] || { echo "check-authority: ${pinned#"$here"/} does not exist; run $0 --update and commit it" >&2; exit 1; }

if [ "$mode" = prove ]; then
  # A stray effect: the pin with one more capability must differ from the report.
  python3 - "$pinned" > "$work/perturbed.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
r["effects"] = sorted(r["effects"] + ["net_out"])
r["labels"] = r["labels"] + [{"name": "net_out", "argument": "", "bounded": True}]
print(json.dumps(r, indent=2))
PY
  if diff -q "$work/perturbed.json" "$work/report.json" >/dev/null; then
    echo "check-authority: the pin did not fail on a stray net_out" >&2; exit 1
  fi
  echo "check-authority: a stray net_out fails the pin (${pinned#"$here"/})" >&2
  exit 0
fi

if diff -u "$pinned" "$work/report.json" > "$work/diff"; then
  echo "check-authority: the authority report is the committed one (${pinned#"$here"/})" >&2
  exit 0
fi
cat "$work/diff"
echo >&2
echo "check-authority: the authority report changed. If it is intended, read the diff, run $0 --update$([ "$variant" = provider ] && echo " --provider")$([ "$variant" = agent ] && echo " --agent")$([ "$variant" = plan ] && echo " --plan")$([ "$variant" = project ] && echo " --project")" >&2
echo "and commit ${pinned#"$here"/}: that commit is the approval." >&2
exit 1
