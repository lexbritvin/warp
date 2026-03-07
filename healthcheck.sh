#!/bin/sh
set -e

# Proxy mode: no TUN interface is created — check SOCKS5 proxy connectivity instead.
if [ "${WARP_MODE:-}" = "proxy" ]; then
    curl -fsS --max-time 8 \
        --socks5 "127.0.0.1:${WARP_PROXY_PORT:-40000}" \
        "https://cloudflare.com/cdn-cgi/trace" | grep -qE "warp=(plus|on)" || exit 1
    exit 0
fi

# Step 1: interface exists and is up (fast, local check)
if ! ip link show "CloudflareWARP" > /dev/null 2>&1; then
    echo "Interface CloudflareWARP does not exist."
    exit 1
fi

# Step 2: in warp/warp+doh + routing override, user controls traffic routing so
# curl would show warp=off. DNS stub at 127.0.2.2 is the right thing to check.
case "${WARP_MODE:-}" in
    warp|warp+doh)
        if [ "${WARP_ROUTING_OVERRIDE:-0}" = "1" ]; then
            nslookup cloudflare.com 127.0.2.2 > /dev/null 2>&1 || exit 1
            exit 0
        fi
        ;;
esac

# Step 3: actual WARP connectivity (verifies tunnel is working)
curl -fsS "https://cloudflare.com/cdn-cgi/trace" | grep -qE "warp=(plus|on)" || exit 1
