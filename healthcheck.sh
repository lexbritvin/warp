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

# Step 2: actual WARP connectivity (verifies tunnel is working)
curl -fsS "https://cloudflare.com/cdn-cgi/trace" | grep -qE "warp=(plus|on)" || exit 1
