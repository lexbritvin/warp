#!/bin/sh
# Data-plane healthcheck. Verifies real egress, not just control-plane.
#
# Design:
#   - proxy              → probe SOCKS5 (only data path).
#   - doh                → no TUN, no proxy; DNS stub is all we can probe.
#   - posture_only       → no data plane; fall back to warp-cli status.
#   - WARP_ROUTING_OVERRIDE=unmanaged (aka 1):
#         the user stripped WARP's policy and is providing their own routing;
#         the warp container itself has no egress by design. We can only
#         probe control plane — DNS stub in warp modes, status otherwise.
#   - WARP_ROUTING_OVERRIDE=router:
#         Two probes, both required:
#           1. cf-router-nat chain exists with a masquerade rule. This is the
#              one that flips red on the production martian-drop symptom —
#              when the chain is missing, peer-src packets reach warp-svc
#              un-SNAT'd and get dropped.
#           2. Plain curl through the tunnel — catches tunnel-level breakage
#              (warp-svc disconnect, edge unreachable, DNS stub dead).
#         We do NOT try to probe the forwarded path end-to-end from the warp
#         container itself — curl --interface with either an iface name or
#         a bridge IP trips kernel-level restrictions (SO_BINDTODEVICE
#         reply-iface asymmetry, or source-address validation on TUN
#         egress). Attempting it would require ip netns tricks that don't
#         belong in a 30s healthcheck. The nft check is a static proxy for
#         that path's readiness.
#   - non-router TUN modes (tunnel_only / warp / warp+doh, no override):
#         plain curl. WARP's own policy routing gets the packet to the TUN
#         with the correct source, round-trips through the tunnel.
#
# HEALTHCHECK --retries=3 already absorbs transient flakes; keep this strict.

set -e

TRACE_URL="https://cloudflare.com/cdn-cgi/trace"
WARP_IF="CloudflareWARP"
MAX_TIME=5
CONNECT_TIMEOUT=3

case "${WARP_MODE:-tunnel_only}" in
    proxy)
        curl -fsS --max-time 8 --connect-timeout "$CONNECT_TIMEOUT" \
            --socks5 "127.0.0.1:${WARP_PROXY_PORT:-40000}" \
            "$TRACE_URL" | grep -qE "warp=(plus|on)" || exit 1
        exit 0
        ;;
    doh)
        nslookup cloudflare.com 127.0.2.2 > /dev/null 2>&1 || exit 1
        exit 0
        ;;
    posture_only)
        warp-cli status > /dev/null 2>&1 || exit 1
        exit 0
        ;;
esac

# Unmanaged mode: WARP's nft/routing is stripped — the container has no
# egress of its own. Fall back to a control-plane probe.
case "${WARP_ROUTING_OVERRIDE:-0}" in
    unmanaged|1)
        case "${WARP_MODE:-}" in
            warp|warp+doh)
                nslookup cloudflare.com 127.0.2.2 > /dev/null 2>&1 || exit 1
                ;;
            *)
                warp-cli status > /dev/null 2>&1 || exit 1
                ;;
        esac
        exit 0
        ;;
esac

# TUN-bearing modes: verify the interface exists.
if ! ip link show "$WARP_IF" > /dev/null 2>&1; then
    echo "Interface $WARP_IF does not exist." >&2
    exit 1
fi

# Router mode: require the masquerade rule to be present before probing
# the tunnel. Chain absence is the production black-hole condition, even
# when the tunnel itself is healthy.
case "${WARP_ROUTING_OVERRIDE:-0}" in
    router)
        nft list chain inet cf-custom cf-router-nat 2>/dev/null \
            | grep -q masquerade || exit 1
        ;;
esac

# Plain curl through WARP's policy routing — proves the full tunnel round-trip
# (control plane up, edge reachable, DNS stub answering).
curl -fsS --max-time "$MAX_TIME" --connect-timeout "$CONNECT_TIMEOUT" \
    "$TRACE_URL" | grep -qE "warp=(plus|on)" || exit 1
