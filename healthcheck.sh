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

# Autoheal state and thresholds. Independent of Docker's HEALTHCHECK config
# (which is runtime-overridable) — anchoring to it would be a false guarantee.
HEAL_STATE=/dev/shm/warp-heal.last_ok
DOWN_L1=90    # seconds without success before warp-cli disconnect/connect
DOWN_L2=180   # seconds without success before SIGTERM warp-svc (container restart)

run_probe() {
    case "${WARP_MODE:-tunnel_only}" in
        proxy)
            curl -fsS --max-time 8 --connect-timeout "$CONNECT_TIMEOUT" \
                --socks5 "127.0.0.1:${WARP_PROXY_PORT:-40000}" \
                "$TRACE_URL" | grep -qE "warp=(plus|on)" || return 1
            return 0
            ;;
        doh)
            nslookup cloudflare.com 127.0.2.2 > /dev/null 2>&1 || return 1
            return 0
            ;;
        posture_only)
            warp-cli status > /dev/null 2>&1 || return 1
            return 0
            ;;
    esac

    # Unmanaged mode: WARP's nft/routing is stripped — the container has no
    # egress of its own. Fall back to a control-plane probe.
    case "${WARP_ROUTING_OVERRIDE:-0}" in
        unmanaged|1)
            case "${WARP_MODE:-}" in
                warp|warp+doh)
                    nslookup cloudflare.com 127.0.2.2 > /dev/null 2>&1 || return 1
                    ;;
                *)
                    warp-cli status > /dev/null 2>&1 || return 1
                    ;;
            esac
            return 0
            ;;
    esac

    # TUN-bearing modes: verify the interface exists.
    if ! ip link show "$WARP_IF" > /dev/null 2>&1; then
        echo "Interface $WARP_IF does not exist." >&2
        return 1
    fi

    # Router mode: require the masquerade rule to be present before probing
    # the tunnel. Chain absence is the production black-hole condition, even
    # when the tunnel itself is healthy.
    case "${WARP_ROUTING_OVERRIDE:-0}" in
        router)
            nft list chain inet cf-custom cf-router-nat 2>/dev/null \
                | grep -q masquerade || return 1
            ;;
    esac

    # Plain curl through WARP's policy routing — proves the full tunnel round-trip
    # (control plane up, edge reachable, DNS stub answering).
    curl -fsS --max-time "$MAX_TIME" --connect-timeout "$CONNECT_TIMEOUT" \
        "$TRACE_URL" | grep -qE "warp=(plus|on)" || return 1
    return 0
}

NOW=$(date +%s)

if run_probe; then
    [ "${WARP_AUTOHEAL:-1}" != "0" ] && echo "$NOW" > "$HEAL_STATE"
    exit 0
fi

# Legacy bit-for-bit identity: with autoheal off, no state file, no side effects.
[ "${WARP_AUTOHEAL:-1}" = "0" ] && exit 1

LAST_OK=$(cat "$HEAL_STATE" 2>/dev/null || echo 0)
case "$LAST_OK" in ''|*[!0-9]*) LAST_OK=0 ;; esac

# Never-healthy guard: don't heal blindly during startup or no-internet-at-all.
[ "$LAST_OK" = "0" ] && exit 1

DOWN_SECS=$((NOW - LAST_OK))

# Heal actions are backgrounded so the script returns within HEALTHCHECK
# --timeout=10s. warp-cli is wrapped in `timeout 10` because it can hang on a
# broken dbus socket.
if [ "$DOWN_SECS" -ge "$DOWN_L2" ]; then
    echo "$(date '+%Y-%m-%dT%H:%M:%S') autoheal L2: SIGTERM warp-svc after ${DOWN_SECS}s" >&2
    pkill -TERM warp-svc &
elif [ "$DOWN_SECS" -ge "$DOWN_L1" ]; then
    echo "$(date '+%Y-%m-%dT%H:%M:%S') autoheal L1: warp-cli reconnect after ${DOWN_SECS}s" >&2
    (timeout 10 warp-cli disconnect; sleep 2; timeout 10 warp-cli connect) >&2 &
fi

exit 1
