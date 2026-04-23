#!/bin/sh

set -e

WARP_IF="CloudflareWARP"
WARP_RT=65743

. /router-routes.sh

handle_shutdown() {
    echo "Received $1"
    echo "Disconnecting..."
    warp-cli disconnect || true
    echo "Stopping warp-svc and dbus..."
    kill ${FIREWALL_WATCHER_PID:-} $WARP_PID $DBUS_PID ${WARP_LOG_FILTER_PID:-} || true
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

# warp-svc's power_notifier module subscribes to systemd-logind for desktop
# suspend/resume. Containers have no logind (and often no system D-Bus
# socket either), so it retries every ~3s and floods docker logs with WARN
# and DEBUG lines referencing the power_notifier module. Drop those; other
# dbus errors (if any appear) stay visible.
# Named pipe keeps $! = warp-svc (signal handling stays correct) — a bare
# `warp-svc | grep` would give us grep's PID instead.
WARP_LOG_FIFO="$RUNTIME_DIRECTORY/warp-svc.log.fifo"
rm -f "$WARP_LOG_FIFO"
mkfifo -m 0600 "$WARP_LOG_FIFO"
grep -vE 'power_notifier|login1' < "$WARP_LOG_FIFO" >&2 &
WARP_LOG_FILTER_PID=$!
warp-svc > "$WARP_LOG_FIFO" 2>&1 &
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

# Routing override mode. Backward compat: 1=unmanaged, 0=none.
case "${WARP_ROUTING_OVERRIDE:-0}" in
    unmanaged|1) WARP_ROUTING_MODE=unmanaged ;;
    router)      WARP_ROUTING_MODE=router ;;
    *)           WARP_ROUTING_MODE=none ;;
esac

# Router mode needs kernel forwarding and relaxed reverse-path filter because
# peer-container traffic enters on the bridge and leaves on CloudflareWARP.
# Warn loudly once at startup — misconfigured sysctls fail silently at runtime
# (masquerade installs fine but packets get dropped).
if [ "$WARP_ROUTING_MODE" = "router" ]; then
    check_sysctl() {
        name=$1; want=$2
        path="/proc/sys/$(echo "$name" | tr . /)"
        got=$(cat "$path" 2>/dev/null || echo "?")
        [ "$got" = "$want" ] || echo "WARNING: router mode needs $name=$want (got: $got)"
    }
    check_sysctl net.ipv4.ip_forward 1
    check_sysctl net.ipv4.conf.all.rp_filter 0
    check_sysctl net.ipv6.conf.all.forwarding 1
fi

WARP_ROUTER_ROUTES_LIST=
if [ -n "${WARP_ROUTER_ROUTES:-}" ]; then
    if [ "$WARP_ROUTING_MODE" != "router" ]; then
        echo "WARNING: WARP_ROUTER_ROUTES is set but WARP_ROUTING_OVERRIDE is not 'router' — ignoring"
    else
        parse_router_routes "$WARP_ROUTER_ROUTES"
    fi
fi

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

# Router mode: make warp act as a router for traffic forwarded from peer
# containers via a Docker bridge. Cloudflare's own nftables policy already
# permits forward (chain forward has policy accept) and table 65743 is already
# populated with subnet decomposition covering public IPs via the TUN, so the
# only thing missing is source NAT: rewrite the peer's bridge source IP to
# warp's TUN IP so the inner packet has the source Cloudflare expects.
# Idempotent — re-runs every watch cycle to refresh the rule with the current
# TUN address (warp-svc may rotate it on reconnect). Silently no-ops in modes
# without a TUN (proxy, doh).
configure_router_mode() {
    warp_ip4=$(ip -4 addr show "$WARP_IF" 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)
    [ -n "$warp_ip4" ] || return 0
    warp_ip6=$(ip -6 addr show "$WARP_IF" scope global 2>/dev/null | awk '/inet6/{print $2; exit}' | cut -d/ -f1)

    # Single atomic transaction: create the chain if missing, flush, add rules.
    # Observers never see an empty chain mid-cycle even though the watcher and
    # its polling fallback both call this every ~2s.
    {
        echo 'add chain inet cf-custom cf-router-nat { type nat hook postrouting priority 100; }'
        echo 'flush chain inet cf-custom cf-router-nat'
        echo "add rule inet cf-custom cf-router-nat oifname \"$WARP_IF\" ip saddr != $warp_ip4 masquerade"
        [ -n "$warp_ip6" ] && \
            echo "add rule inet cf-custom cf-router-nat oifname \"$WARP_IF\" ip6 saddr != $warp_ip6 masquerade"
    } | nft -f - 2>/dev/null || true

    apply_router_routes
}

routing_override_apply() {
    case "$WARP_ROUTING_MODE" in
        unmanaged) disable_firewall ;;
        router)    configure_router_mode ;;
    esac
}

watch_firewall() {
    # Polling fallback: handles events missed by monitor (e.g. table created between
    # routing_override_apply return and nft monitor start)
    (while true; do routing_override_apply; sleep 2; done) &
    while true; do
        nft monitor 2>/dev/null | while IFS= read -r line; do
            case "$line" in
                *cloudflare-warp*) routing_override_apply ;;
            esac
        done
        routing_override_apply
        sleep 1
    done
}

# Wait for CloudflareWARP to have a usable address. Without this, the first
# configure_router_mode() call returns early (no warp_ip4) and peer traffic
# reaches warp-svc before cf-router-nat is installed → martian drops +
# un-masqueraded conntrack entries that outlive the race window.
wait_for_tun_ready() {
    [ "$WARP_ROUTING_MODE" = "router" ] || return 0
    i=0
    while [ $i -lt 20 ]; do
        if ip -4 addr show "$WARP_IF" 2>/dev/null | grep -q 'inet '; then
            return 0
        fi
        sleep 0.5
        i=$((i + 1))
    done
    echo "WARNING: $WARP_IF has no IPv4 address after 10s — cf-router-nat will install on next watcher cycle"
}

if [ "$WARP_ROUTING_MODE" != "none" ]; then
    echo "Routing override mode: $WARP_ROUTING_MODE"
    # Synchronous first pass: close the start-up race before peers (gated on
    # healthcheck) start forwarding traffic. The watcher handles reconnects
    # and any later WARP-side rule changes.
    wait_for_tun_ready
    routing_override_apply
    watch_firewall &
    FIREWALL_WATCHER_PID=$!
fi

echo "Successfully started"
wait $WARP_PID
