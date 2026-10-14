#!/bin/sh
# The agent command for the driver: scripts/cancho-agent.sh --provider anthropic --model <m> --key-file <f> [options] <project.cho>
#
# The agent is a cancho program (src/cancho_agent.cho). It does not resolve names and does not know where a system keeps its CA bundle,
# because a resolver is a policy and a trust store is the operator's. This wrapper is that policy, and nothing else: it finds the address of
# the provider's host and a PEM bundle and puts them in front of the arguments. A flag the caller wrote after them wins (the agent takes
# the last value), so `--ip` / `--host` / `--roots` in the command are honoured.
#
# There is no default provider and no default model: both are the caller's. The only provider-to-host mapping here is that anthropic is
# api.anthropic.com. The driver gives its agent no environment, so these variables are for tests and unusual installs, not for normal use:
#   CANCHO_AGENT_BIN    the built agent             (build/cancho-agent, from scripts/build-agent.sh)
#   CANCHO_AGENT_HOST   the host to reach instead of the provider's own
#   CANCHO_AGENT_ROOTS  a PEM bundle to trust instead of the system's
set -u
here=$(cd "$(dirname "$0")" && pwd)
bin="${CANCHO_AGENT_BIN:-$here/../build/cancho-agent}"
[ -x "$bin" ] || { echo "cancho-agent.sh: $bin is not built; run scripts/build-agent.sh" >&2; exit 2; }

provider=""
prev=""
for a in "$@"; do
    [ "$prev" = "--provider" ] && provider="$a"
    prev="$a"
done
case "$provider" in
    anthropic) host="${CANCHO_AGENT_HOST:-api.anthropic.com}" ;;
    *) exec "$bin" "$@" ;;   # the agent refuses a missing or unknown provider itself (exit 2)
esac

ip=$(dscacheutil -q host -a name "$host" 2>/dev/null | awk '/^ip_address:/ {print $2; exit}')
[ -n "$ip" ] || ip=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}')
[ -n "$ip" ] || { echo "cancho-agent.sh: cannot resolve $host" >&2; exit 1; }

roots="${CANCHO_AGENT_ROOTS:-}"
if [ -z "$roots" ]; then
    for f in /etc/ssl/cert.pem /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
        [ -f "$f" ] && { roots=$f; break; }
    done
fi
[ -n "$roots" ] || { echo "cancho-agent.sh: no CA bundle found; name one with --roots" >&2; exit 1; }

exec "$bin" --host "$host" --ip "$ip" --roots "$roots" "$@"
