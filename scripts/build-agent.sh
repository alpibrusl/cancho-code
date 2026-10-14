#!/bin/sh
# Build the native agent to build/cancho-agent: CANCHO (the compiler) and its packages/ (CANCHO_PACKAGES, or next to the binary).
set -eu
CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "build-agent: no cancho on PATH; set CANCHO=" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
C="${CANCHO_PACKAGES:-}"
[ -d "$C" ] || C="$(dirname "$(dirname "$(command -v "$CANCHO")")")/packages"
[ -d "$C" ] || C="$(dirname "$(dirname "$(dirname "$(command -v "$CANCHO")")")")/packages"
[ -d "$C" ] || { echo "build-agent: no cancho packages found; set CANCHO_PACKAGES" >&2; exit 2; }
mkdir -p "$root/build"
exec "$CANCHO" build "$root/src/cancho_agent.cho" "$root/src/anthropic.cho" "$root/src/ollama.cho" "$root/src/prompt.cho" "$root/src/provider.cho" "$root/src/reply.cho" \
    "$root/vendor/fetch_io.cho" "$C"/http-client/*.cho "$C"/tls/*.cho "$C"/x509/*.cho --std --backend cranelift -o "$root/build/cancho-agent"
