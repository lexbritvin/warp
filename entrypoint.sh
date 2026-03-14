#!/bin/sh

set -e

WARP_IF="CloudflareWARP"
WARP_RT=65743

handle_shutdown() {
    echo "Received $1"
    echo "Disconnecting..."
    warp-cli disconnect || true
    echo "Stopping warp-svc and dbus..."
    kill ${FIREWALL_WATCHER_PID:-} $WARP_PID $DBUS_PID || true
    echo "Finished"
    trap - EXIT
}
trap "handle_shutdown SIGTERM" SIGTERM
trap "handle_shutdown SIGINT" SIGINT
trap "handle_shutdown EXIT" EXIT

echo "Cloudflare WARP"

# Create TUN device if not present.
# Requires MKNOD capability and device_cgroup_rules 'c 10:200 rwm' (containerd >= 1.7.24 / runc >= 1.2.2
# removed TUN from the default cgroup allowlist — the node can be created but not opened without it).
if [ ! -e /dev/net/tun ]; then
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200 || {
        echo "ERROR: Cannot create /dev/net/tun. Ensure MKNOD capability and device_cgroup_rules 'c 10:200 rwm' are set."
        exit 1
    }
    chmod 600 /dev/net/tun
fi

echo "Starting dbus"
mkdir -p /run/dbus
if [ -f /run/dbus/pid ]; then
    rm /run/dbus/pid
fi
dbus-daemon --config-file=/usr/share/dbus-1/system.conf --nofork &
DBUS_PID=$!

echo "Starting warp-svc"
mkdir -p $STATE_DIRECTORY
mkdir -p $RUNTIME_DIRECTORY
mkdir -p $LOGS_DIRECTORY
warp-svc &
WARP_PID=$!

echo "Waiting for the warp-svc to start"
while ! warp-cli status > /dev/null 2>&1; do
    printf "."
    sleep 0.5
done
echo ""
echo "WARP service loaded"

# If there is no registration, make a new one.
if [ ! -f "$STATE_DIRECTORY/reg.json" ]; then
    # WARP_CONSUMER_REGISTER forces consumer registration even when mdm.xml exists.
    if [ ! -f "$STATE_DIRECTORY/mdm.xml" ] || [ -n "$WARP_CONSUMER_REGISTER" ]; then
        warp-cli registration new && echo "Warp client registered!"
        if [ -n "$WARP_LICENSE_KEY" ]; then
            warp-cli registration license "$WARP_LICENSE_KEY" && echo "License registered!"
        fi
    fi
else
    echo "Warp client already registered, skip registration"
fi

# Warp configuration.
echo "Set warp mode: $WARP_MODE"
warp-cli mode $WARP_MODE

echo "Set warp proxy port: $WARP_PROXY_PORT"
warp-cli proxy port ${WARP_PROXY_PORT}

echo "Set warp family mode: $WARP_FAMILIES_MODE"
warp-cli --accept-tos dns families "${WARP_FAMILIES_MODE}"

# Logging configuration.
if [ -z "$WARP_DEBUG_QLOG" ]; then
    warp-cli debug qlog disable
    warp-cli dns log disable
else
    warp-cli debug qlog enable
fi

echo "Connecting to WARP"
warp-cli connect

# Clamp TCP MSS to path MTU for forwarded traffic through the WARP TUN.
# Required because CloudflareWARP has a low MTU (1280); without this, large TCP
# segments (e.g. TLS handshake) get silently dropped after WARP encapsulation.
# Equivalent to: iptables -t mangle -A FORWARD -o $WARP_IF -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
nft add table inet cf-custom || true
if [ "${WARP_MSS_CLAMP:-1}" = "1" ]; then
    nft add chain inet cf-custom cf-mss "{ type filter hook forward priority mangle; }" 2>/dev/null || true
    nft add rule inet cf-custom cf-mss oifname "$WARP_IF" 'tcp flags & (syn|rst) == syn tcp option maxseg size set rt mtu' 2>/dev/null || true
else
    nft delete chain inet cf-custom cf-mss 2>/dev/null || true
fi

# Export DNS for attached containers.
if [ "${WARP_DNS_EXPOSE:-0}" = "1" ]; then
    echo "Expose local Cloudflare DNS server port"
    nft add chain inet cf-custom cf-dns-prerouting "{ type nat hook prerouting priority -100; }"
    nft add rule inet cf-custom cf-dns-prerouting ip protocol udp udp dport 53 dnat to 127.0.2.2:53
    nft add rule inet cf-custom cf-dns-prerouting ip protocol tcp tcp dport 53 dnat to 127.0.2.2:53
    nft add chain inet cf-custom cf-dns-forward "{ type filter hook forward priority -100; }"
    nft add rule inet cf-custom cf-dns-forward ip protocol udp ip daddr 127.0.2.2 udp dport 53 accept
    nft add rule inet cf-custom cf-dns-forward ip protocol tcp ip daddr 127.0.2.2 tcp dport 53 accept
else
    nft del chain inet cf-custom cf-dns-prerouting || true
    nft del chain inet cf-custom cf-dns-forward || true
fi

# Export SOCKS5 proxy for port-mapped access.
# Requires net.ipv4.conf.all.route_localnet=1 sysctl.
if [ "${WARP_PROXY_EXPOSE:-0}" = "1" ]; then
    echo "Expose WARP SOCKS5 proxy port"
    nft add chain inet cf-custom cf-proxy-prerouting "{ type nat hook prerouting priority -100; }"
    nft add rule inet cf-custom cf-proxy-prerouting ip protocol tcp tcp dport ${WARP_PROXY_PORT} dnat to 127.0.0.1:${WARP_PROXY_PORT}
else
    nft del chain inet cf-custom cf-proxy-prerouting || true
fi

# Routing override: strip all WARP nftables chains and routing policy table.
cf_nft_rules_exist() {
    nft list table inet cloudflare-warp > /dev/null 2>&1
}

disable_firewall() {
    cf_nft_rules_exist || return 0
    echo "Cleaning Cloudflare nftables and routing rules"
    # Flush all rules first (base chains with drop policy can't be deleted non-empty)
    nft flush table inet cloudflare-warp 2>/dev/null || true
    # Delete chains individually (required before table delete on some nft versions)
    nft delete chain inet cloudflare-warp forward 2>/dev/null || true
    nft delete chain inet cloudflare-warp tun 2>/dev/null || true
    nft delete chain inet cloudflare-warp output 2>/dev/null || true
    nft delete chain inet cloudflare-warp input 2>/dev/null || true
    nft delete table inet cloudflare-warp 2>/dev/null || true
    ip route flush table $WARP_RT 2>/dev/null || true
    case "${WARP_MODE:-}" in
        warp|warp+doh)
            # resolv.conf is locked to 127.0.2.2 by warp-svc; the DNS stub needs
            # table 65743 to forward queries to Cloudflare. Restore the Cloudflare
            # subnet route and keep ip rules so warp-svc's fwmarked traffic still
            # reaches its upstream resolvers via the TUN interface.
            ip route add table $WARP_RT 162.159.0.0/17 dev $WARP_IF proto static scope link 2>/dev/null || true
            ;;
        *)
            while ip rule list 2>/dev/null | grep -q "lookup $WARP_RT"; do
                ip rule del lookup $WARP_RT 2>/dev/null || true
            done
            ;;
    esac
}

watch_firewall() {
    # Polling fallback: handles events missed by monitor (e.g. table created between
    # disable_firewall return and nft monitor start)
    (while true; do disable_firewall; sleep 2; done) &
    # Event-driven: react immediately when WARP modifies its rules
    disable_firewall
    while true; do
        nft monitor 2>/dev/null | while IFS= read -r line; do
            case "$line" in
                *cloudflare-warp*) disable_firewall ;;
            esac
        done
        disable_firewall
        sleep 1
    done
}

if [ "${WARP_ROUTING_OVERRIDE:-0}" = "1" ]; then
    echo "Watching Cloudflare firewall to override"
    watch_firewall &
    FIREWALL_WATCHER_PID=$!
fi

echo "Successfully started"
wait $WARP_PID
