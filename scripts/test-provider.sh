#!/bin/sh
# The provider gate (issue #4, design §5): the Mistral agent as one native
# HTTPS call, built and — with a key — run end to end.
#
#   build   — the gate compiles against the real packages: http-client,
#             tls, x509, and the vendored fetch_io (this is the CI path;
#             no network, no key)
#   mistral — the real API, when MISTRAL_API_KEY is set in the environment:
#             the harness resolves api.mistral.ai, hands the gate the
#             system's roots, and the model's answer must fix the project
#             file so the real cancho check verifies it
#
# Exit 0 the case held; 1 it did not; 2 the environment (no compiler, no
# key where one was required).
set -u

CANCHO="${CANCHO:-cancho}"
command -v "$CANCHO" >/dev/null 2>&1 || { echo "no cancho on PATH; set CANCHO=" >&2; exit 2; }
mode="${1:-build}"

root=$(cd "$(dirname "$0")/.." && pwd)
exe=$(mktemp -t cc-prov-XXXXXX)

P="$root/vendor"
# The packages live in the compiler's checkout: CANCHO_PACKAGES names it
# (or the harness finds it next to the binary).
C="${CANCHO_PACKAGES:-}"
[ -d "$C" ] || C="$(dirname "$(dirname "$(command -v "$CANCHO")")")/packages"
[ -d "$C" ] || { echo "no cancho packages found; set CANCHO_PACKAGES to the compiler's packages/ directory" >&2; exit 2; }

"$CANCHO" build "$root/tests/programs/provider_gate.cho" \
    "$root/src/provider.cho" \
    "$P/fetch_io.cho" \
    "$C/http-client/slot.cho" "$C/http-client/wire.cho" \
    "$C/http-client/client.cho" \
    "$C/tls/tls.cho" "$C/tls/record.cho" \
    "$C/tls/message.cho" "$C/tls/slot.cho" \
    "$C/tls/client12.cho" "$C/tls/client.cho" \
    "$C/tls/hello.cho" "$C/tls/identity.cho" \
    "$C/tls/server.cho" \
    "$C/x509/verify.cho" "$C/x509/names.cho" \
    "$C/x509/x509.cho" "$C/x509/key.cho" \
    --std --backend cranelift -o "$exe" || { echo "gate did not build" >&2; exit 2; }

fail=0

# The host case: the literal, for the record.
out=$("$exe" host "$CANCHO" /tmp x 0.0.0.0 none)
echo "$out"
[ "$out" = "host api.mistral.ai" ] || { echo "FAIL: host answered '$out'" >&2; fail=1; }

if [ "$mode" = "mistral" ]; then
    [ "${MISTRAL_API_KEY:-}" != "" ] || { echo "MISTRAL_API_KEY is not set; the mistral case needs it" >&2; exit 2; }
    dir=$(mktemp -d -t cc-prov1-XXXXXX)
    printf 'edition 7;\nfn broken() -> [] int { return true; }\n' > "$dir/project.cho"
    cat >> "$dir/project.cho" <<'FIX'
fn main(world: World) -> [] int {
    let Split { io, ffi, fs, heap, args, net, clock, signals, exec } = split(world);
    release(ffi); release(fs); release(net); release(clock); release(signals); release(exec); release(args);
    release(io); release(heap);
    return 0;
}
FIX
    ip=$(getent hosts api.mistral.ai | awk '{print $1; exit}')
    [ -n "$ip" ] || { echo "could not resolve api.mistral.ai" >&2; exit 2; }
    roots=$(mktemp -t cc-roots-XXXXXX)
    cp /etc/ssl/certs/ca-certificates.crt "$roots" 2>/dev/null || cat /etc/pki/tls/certs/ca-bundle.crt > "$roots"
    out=$("$exe" mistral "$CANCHO" "$dir" "$roots" "$ip" "$MISTRAL_API_KEY")
    echo "$out"
    echo "$out" | grep -q '\[PROVIDER\] written' || { echo "FAIL: the provider did not write ($out)" >&2; fail=1; }
    # The real checker is the oracle: the model's answer must verify.
    "$CANCHO" check "$dir/project.cho" --output json --backend cranelift | grep -q '"refused": \[\]' \
        || { echo "FAIL: the model's answer does not check" >&2; "$CANCHO" check "$dir/project.cho" --backend cranelift >&2; fail=1; }
    rm -rf "$dir" "$roots"
fi

rm -f "$exe"
[ "$fail" = 0 ] && echo "provider gate: ok" || { echo "provider gate: FAILED" >&2; exit 1; }
