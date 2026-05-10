# Cloudflare WARP Container image

The smallest, most complete way to run [Cloudflare WARP](https://developers.cloudflare.com/cloudflare-one/connections/connect-devices/warp/) in a container.

**Image tags combine the upstream Cloudflare WARP binary version with a semver for the image itself**: `<warp-version>-<image-version>` (e.g. `2024.6.474.0-1.0.0`). The image version is driven by git tags (`v1.0.0`, `v1.0.1`, …) — bump it when entrypoint, healthcheck, or packaging logic changes. A daily CI build also rebuilds on new WARP releases keeping the current image version, so `latest` always points at the freshest combination. Mutable aliases: `<warp-version>` (newest image for that WARP) and `latest`.

[![Build](https://github.com/lexbritvin/warp/actions/workflows/build.yml/badge.svg)](https://github.com/lexbritvin/warp/actions/workflows/build.yml)
[![Image](https://img.shields.io/badge/ghcr.io-lexbritvin%2Fwarp-blue?logo=docker)](https://ghcr.io/lexbritvin/warp)

---

- **Tiny scratch-based image** — binaries extracted from Cloudflare's official `.deb`, stripped, running on a minimal Void Linux glibc runtime. No Ubuntu, no package manager overhead.
- **Bare TUN or NAT router** — `WARP_ROUTING_OVERRIDE=unmanaged` strips WARP's nftables policy and routing table for full manual control (sing-box, custom routing daemons). `WARP_ROUTING_OVERRIDE=router` keeps WARP's policy intact and adds source-NAT so peer containers on a Docker bridge can route through the WARP tunnel.
- **Shared DNS and SOCKS5 without a sidecar** — `WARP_DNS_EXPOSE` and `WARP_PROXY_EXPOSE` use nftables DNAT to make Cloudflare DNS and the WARP SOCKS5 proxy available across the shared network namespace.
- **Full tunnel, proxy, or DNS-only** — six `WARP_MODE` values cover every WARP operating mode, switchable without rebuilding.
- **Zero Trust via MDM** — mount `mdm.xml` for managed enrollment; falls back to consumer registration automatically.
- **Multi-arch** — `linux/amd64` and `linux/arm64`.

Any container that needs WARP connectivity adds `network_mode: service:warp` and `depends_on: condition: service_healthy` — and inherits the full tunnel without host-level changes.

---

## Quick start

```yaml
services:
  warp:
    image: ghcr.io/lexbritvin/warp:latest
    restart: unless-stopped
    device_cgroup_rules:
      - 'c 10:200 rwm'
    cap_add:
      - NET_ADMIN
    sysctls:
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv4.conf.all.src_valid_mark=1

  myapp:
    image: myapp
    network_mode: "service:warp"
    depends_on:
      warp:
        condition: service_healthy
```

```sh
docker exec warp curl -fsS https://cloudflare.com/cdn-cgi/trace | grep warp
```

---

## Modes (`WARP_MODE`)

| Value | Traffic | DNS | Notes |
|---|---|---|---|
| `tunnel_only` _(default)_ | Full tunnel | OS resolver | Best for containers with their own DNS |
| `warp` | Full tunnel | Forced to Cloudflare (`127.0.2.2`) | Use `WARP_DNS_EXPOSE=1` to share |
| `proxy` | Explicit only | None | SOCKS5 on `WARP_PROXY_PORT`. MASQUE required. |
| `doh` | None | Cloudflare DoH | DNS filtering only |
| `warp+doh` | Full tunnel | Cloudflare DoH | — |
| `posture_only` | None | None | Zero Trust compliance reporting only |

| I want to… | Config |
|---|---|
| Route all traffic, manage DNS myself _(default)_ | `WARP_MODE=tunnel_only` |
| Route all traffic + Cloudflare DNS | `WARP_MODE=warp` |
| SOCKS5 proxy, no system tunnel | `WARP_MODE=proxy` |
| DNS filtering only | `WARP_MODE=doh` |
| Bare tunnel, full manual routing control | `WARP_MODE=tunnel_only` + `WARP_ROUTING_OVERRIDE=unmanaged` |
| NAT gateway for peer containers on a Docker bridge | `WARP_MODE=warp` + `WARP_ROUTING_OVERRIDE=router` |

---

## Feature flags

### `WARP_MSS_CLAMP=1`

Clamps TCP MSS to the path MTU for forwarded traffic through the WARP TUN interface. Required because the CloudflareWARP interface has a low MTU (~1280 bytes); without this, large TCP segments (e.g. TLS handshakes) are silently dropped after WARP encapsulation. Enabled by default. Set to `0` only if your routing daemon handles MSS clamping itself.

### `WARP_ROUTING_OVERRIDE`

Semantic mode selector controlling how warp interacts with Cloudflare's own nftables policy and routing.

| Value | Behavior |
|---|---|
| `none` (default) — also `0`, unset | No intervention. Cloudflare manages its own firewall and routing. |
| `unmanaged` — also `1` | Strips all WARP-managed nftables chains (`input`, `output`, `tun` in `inet cloudflare-warp`) and flushes WARP's policy routing table (65743). The tunnel stays up — only the kernel routing rules are removed, giving you a clean slate to apply your own routing policy. Re-applies on every reconnect via `nft monitor`. Pair with `net.ipv4.ip_forward=1` and `net.ipv6.conf.all.forwarding=1` when attaching containers that need TUN-based routing (e.g. sing-box in TUN mode). |
| `router` | Leaves Cloudflare's nftables policy and routing table 65743 fully intact (Zero Trust split-tunnel, whitelist, and `warp-cli tunnel ip add` rules keep working). Installs a single source-NAT chain (`cf-router-nat`) that masquerades peer-container traffic leaving `CloudflareWARP` to warp's TUN address — both IPv4 and IPv6. Works with `WARP_MODE=warp`, `warp+doh`, or `tunnel_only` (warp-svc populates table 65743 the same way in all three). No-ops under `proxy` / `doh` modes (no TUN). |

Backward compatibility: `1` continues to mean `unmanaged` and `0` continues to mean `none`. Any unrecognized value is treated as `none`.

**Security note.** `router` mode makes warp an **open NAT gateway** on the Docker network it is attached to. Any container that can reach warp's bridge IP can egress through the WARP tunnel with no authentication. Fine for a single-host dev setup; audit carefully before using on a shared or multi-tenant host, and prefer a dedicated Docker network for the warp + peer containers.

**`router` mode prerequisites** (set externally on the warp container):

```yaml
sysctls:
  - net.ipv4.ip_forward=1
  - net.ipv4.conf.all.rp_filter=0      # asymmetric path: in via eth0, out via CloudflareWARP
  - net.ipv6.conf.all.forwarding=1
  - net.ipv6.conf.all.accept_ra=2      # forwarding disables RA processing; =2 re-enables it
```

### `WARP_ROUTER_ROUTES`

Static routes installed in the warp container for return traffic in `router` mode. Needed when a peer container forwards traffic from a downstream subnet that isn't directly connected to warp's bridge — e.g. another routing daemon (sing-box, a WireGuard server, a nested NAT) whose clients live on a private subnet behind it. Replies come back through the WARP tunnel, get un-masqueraded to the client address, and warp has no route back — so return packets go to the default gateway and are lost.

Format: semicolon-separated entries, each `dst=CIDR,via=GW`. Family (IPv4/IPv6) is auto-detected from the destination. The format is strict: no whitespace around `=`, no extra fields. Malformed entries, obviously broken CIDRs, and any attempt to install a default route (`0.0.0.0/0`, `::/0`, `default`, or any `/0` prefix) are logged and skipped — not fatal. Rejecting default routes is deliberate: `ip route replace` would otherwise clobber the container/host's own default and silently break egress.

```
WARP_ROUTER_ROUTES=dst=10.99.0.0/24,via=192.0.2.1; dst=fd99::/64,via=2001:db8::1
```

Routes are installed via `ip route replace` inside the same watcher that maintains the router-mode NAT chain, so they're re-applied every ~2 s and survive any `warp-svc` route rewrites. Ignored with a warning outside `router` mode.

### `WARP_DNS_EXPOSE=1`

DNATs port 53 (UDP + TCP) to `127.0.2.2:53`, making the Cloudflare DNS resolver available to attached containers. Most useful with `WARP_MODE=warp` or `warp+doh`.

### `WARP_PROXY_EXPOSE=1`

DNATs `WARP_PROXY_PORT` (TCP) to `127.0.0.1:WARP_PROXY_PORT`, making the SOCKS5 proxy accessible via Docker port mapping (`-p`). Requires `net.ipv4.conf.all.route_localnet=1` sysctl. Not needed when using `network_mode: service:warp`.

### `WARP_CONSUMER_REGISTER=1`

Forces consumer account registration even when `mdm.xml` is present. Normally, the presence of `mdm.xml` causes registration to be skipped (assumes Zero Trust enrollment).

### `WARP_DEBUG_QLOG=1`

Enables WARP qlog debug output. Disabled by default.

### `WARP_TUNNEL_PROTOCOL` / `WARP_MASQUE_OPTIONS`

Pass-through to `warp-cli tunnel protocol` and `warp-cli tunnel masque-options`. Both unset = leave warp-cli's own default in place. Defaults observed in the bundled warp-cli (`warp-cli tunnel protocol set --help`, `warp-cli tunnel masque-options set --help`): `MASQUE` for protocol, `h3-with-h2-fallback` for MASQUE options.

| Variable | Value | Behavior |
|---|---|---|
| `WARP_TUNNEL_PROTOCOL` | `MASQUE` _(default)_ | MASQUE over HTTP/3 or HTTP/2 connect-ip |
| | `WireGuard` | Legacy WG transport |
| | `reset` | Revert to client default |
| `WARP_MASQUE_OPTIONS` | `h3-only` | Pure HTTP/3, no TCP fallback |
| | `h2-only` | MASQUE over HTTP/2 only |
| | `h3-with-h2-fallback` _(default)_ | Try HTTP/3, fall back to HTTP/2 if it fails |
| | `reset` | Revert to client default |

Both values are persisted by warp-svc inside `STATE_DIRECTORY`, so they survive container restarts that mount the same volume — env vars matter primarily for **fresh deploys / reproducible builds** where the volume might start empty. The entrypoint re-applies on every start, so a mounted volume + env-var combo always converges to the env-var value (env wins on every boot, idempotently).

Both subcommands are marked **Consumer only** by warp-cli. On a Zero Trust registration the underlying setter exits non-zero; the entrypoint logs `WARNING:` and continues — startup does not fail. Older warp-cli builds without the `tunnel protocol` / `tunnel masque-options` subcommands are also handled gracefully (logged-and-skipped, not fatal).

Pin to MASQUE + h3-only when you want pure QUIC end-to-end — useful when an upstream service negotiates differently against H3 vs H2 racing, or for QUIC-specific diagnostics where the racing fallback would obscure which path is in use:

```yaml
environment:
  WARP_TUNNEL_PROTOCOL: "MASQUE"
  WARP_MASQUE_OPTIONS: "h3-only"
```

### `WARP_AUTOHEAL=1`

Self-recovery for the production "stuck data plane" symptom: the H2 socket to a Cloudflare edge stays `ESTABLISHED` with bidirectional keep-alives, but no application traffic flows. `warp-cli status` reports healthy because it tracks the control-plane socket; only the data-plane probe in [healthcheck.sh](healthcheck.sh) catches it. Enabled by default.

When the data-plane probe (e.g. `curl https://cloudflare.com/cdn-cgi/trace` through the TUN, or the mode-equivalent control-plane probe) has been failing continuously, the healthcheck escalates:

- **L1 — after ~90 s without success**: `warp-cli disconnect; sleep 2; warp-cli connect`. Forces a new 5-tuple, usually unsticks a pinned CF anycast bucket. Registration is preserved.
- **L2 — after ~180 s without success**: `SIGTERM` to `warp-svc`. The entrypoint's existing shutdown trap cleans up and tini exits 0 — your `restart` policy must bring the container back up. **Pair with `restart: unless-stopped` (or stricter)** for L2 to be effective; without a restart policy, L2 just stops the container.

Heal actions run in the background so the healthcheck still returns within Docker's `--timeout=10s`. Set `WARP_AUTOHEAL=0` to disable (useful when debugging unexpected restarts) — with autoheal off, the script is bit-for-bit identical to the pre-autoheal behaviour.

---

## Environment variable reference

| Variable | Default | Description |
|---|---|---|
| `WARP_MODE` | `tunnel_only` | WARP operating mode. See [Modes](#modes-warp_mode). |
| `WARP_LICENSE_KEY` | _(empty)_ | WARP+ or Teams license key. Applied after registration. |
| `WARP_PROXY_PORT` | `40000` | SOCKS5 proxy port. |
| `WARP_FAMILIES_MODE` | `off` | DNS families filtering: `off`, `full`, `malware`. |
| `WARP_ROUTING_OVERRIDE` | `none` | Routing override mode: `none` (default), `unmanaged` (= legacy `1`, strip WARP nft + table 65743), or `router` (NAT gateway for peer containers). |
| `WARP_ROUTER_ROUTES` | _(empty)_ | Static return routes for `router` mode. Semicolon-separated `dst=CIDR,via=GW` entries; family auto-detected. |
| `WARP_MSS_CLAMP` | `1` | Clamp TCP MSS to path MTU for forwarded traffic. Disable only if your routing daemon handles this. |
| `WARP_AUTOHEAL` | `1` | Auto-recover stuck data plane: `warp-cli` reconnect after ~90 s, `SIGTERM warp-svc` after ~180 s (relies on container restart policy). `0` to disable. |
| `WARP_DNS_EXPOSE` | `0` | DNAT port 53 to Cloudflare DNS. Set to `1` to enable. |
| `WARP_PROXY_EXPOSE` | `0` | DNAT SOCKS5 port to loopback for port mapping. Set to `1` to enable. |
| `WARP_CONSUMER_REGISTER` | _(empty)_ | Force consumer registration even when `mdm.xml` exists. |
| `WARP_DEBUG_QLOG` | _(empty)_ | Enable WARP qlog debug output. |
| `WARP_TUNNEL_PROTOCOL` | _(unset → client default)_ | Pin tunnel protocol: `MASQUE`, `WireGuard`, or `reset`. Consumer accounts only. See [WARP_TUNNEL_PROTOCOL / WARP_MASQUE_OPTIONS](#warp_tunnel_protocol--warp_masque_options). |
| `WARP_MASQUE_OPTIONS` | _(unset → client default)_ | MASQUE transport: `h3-only`, `h2-only`, `h3-with-h2-fallback`, or `reset`. Consumer accounts only. |
| `STATE_DIRECTORY` | `/var/lib/cloudflare-warp` | warp-svc persistent state. Mount a volume here to persist registration across restarts. |
| `RUNTIME_DIRECTORY` | `/run/cloudflare-warp` | warp-svc runtime socket directory. |
| `LOGS_DIRECTORY` | `/run/log/cloudflare-warp` | warp-svc log directory. |

---

## Recipes

### 1. Attach a container to WARP

```yaml
services:
  warp:
    image: ghcr.io/lexbritvin/warp:latest
    restart: unless-stopped
    device_cgroup_rules:
      - 'c 10:200 rwm'
    cap_add:
      - NET_ADMIN
    sysctls:
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv4.conf.all.src_valid_mark=1

  myapp:
    image: myapp
    network_mode: "service:warp"
    depends_on:
      warp:
        condition: service_healthy
```

### 2. Expose SOCKS5 proxy via port mapping

```yaml
services:
  warp:
    image: ghcr.io/lexbritvin/warp:latest
    restart: unless-stopped
    device_cgroup_rules:
      - 'c 10:200 rwm'
    ports:
      - "40000:40000"
    environment:
      WARP_MODE: "proxy"
      WARP_PROXY_EXPOSE: "1"
    cap_add:
      - NET_ADMIN
    sysctls:
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv4.conf.all.route_localnet=1
```

```sh
curl --socks5 localhost:40000 https://cloudflare.com/cdn-cgi/trace
```

### 3. Bare tunnel + sing-box with custom routing

```yaml
services:
  warp:
    image: ghcr.io/lexbritvin/warp:latest
    restart: unless-stopped
    device_cgroup_rules:
      - 'c 10:200 rwm'
    environment:
      WARP_ROUTING_OVERRIDE: "1"
    cap_add:
      - NET_ADMIN
    sysctls:
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv4.ip_forward=1
      - net.ipv6.conf.all.forwarding=1

  singbox:
    image: ghcr.io/sagernet/sing-box:latest
    network_mode: "service:warp"
    depends_on:
      warp:
        condition: service_healthy
    volumes:
      - ./config/singbox:/etc/sing-box
```

### 4. NAT gateway: peer containers route through WARP

```yaml
services:
  warp:
    image: ghcr.io/lexbritvin/warp:latest
    restart: unless-stopped
    device_cgroup_rules:
      - 'c 10:200 rwm'
    environment:
      WARP_MODE: "warp"
      WARP_ROUTING_OVERRIDE: "router"
    cap_add:
      - NET_ADMIN
    sysctls:
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.rp_filter=0
      - net.ipv6.conf.all.forwarding=1
      - net.ipv6.conf.all.accept_ra=2
    networks:
      warp-net:

  peer:
    image: curlimages/curl
    cap_add:
      - NET_ADMIN
    user: "0:0"
    sysctls:
      - net.ipv4.conf.all.rp_filter=0
    depends_on:
      warp:
        condition: service_healthy
    networks:
      warp-net:
    entrypoint: ["sh", "-c"]
    command:
      - |
        ip route replace default via $$(getent hosts warp | awk '{print $$1}')
        curl -fsS https://cloudflare.com/cdn-cgi/trace

networks:
  warp-net:
    enable_ipv6: true
    ipam:
      config:
        - subnet: fd00:dead:beef::/64
```

Unlike Recipe 1 (`network_mode: service:warp`, where peer shares warp's netns), this pattern keeps each peer container in its own netns on a Docker bridge and uses warp purely as a NAT gateway. WARP's own Zero Trust split-tunnel and `warp-cli tunnel ip add` rules continue to work because we don't strip its nftables policy.

### 5. Zero Trust enrollment

```yaml
services:
  warp:
    image: ghcr.io/lexbritvin/warp:latest
    restart: unless-stopped
    device_cgroup_rules:
      - 'c 10:200 rwm'
    cap_add:
      - NET_ADMIN
    sysctls:
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv4.conf.all.src_valid_mark=1
    volumes:
      - ./mdm.xml:/var/lib/cloudflare-warp/mdm.xml:ro
```

---

## Comparison

| Feature | this image | [warp-docker](https://github.com/cmj2002/warp-docker) | [wasque](https://github.com/Diniboy1123/wasque) |
|---|---|---|---|
| Base image | scratch (Void Linux runtime) | ubuntu:22.04 | scratch (Void Linux) |
| Proxy | WARP native SOCKS5 | GOST | WARP native SOCKS5 |
| Firewall override | Clean slate | Additive (beta) | No |
| DNS expose | Yes | No | No |
| Proxy port mapping | nft DNAT | GOST | LD_PRELOAD |
| Healthcheck | 2-step (interface + trace) | HTTP trace | None |
| NAT gateway | No | Yes | No |
| Zero Trust | Yes | Yes | No |
| Multi-arch | Yes (amd64 + arm64) | Yes | Yes |

---

## Verification

```sh
# Run all integration tests (builds image from current directory)
bash test.sh

# Spot checks against a running container
docker exec warp curl -fsS https://cloudflare.com/cdn-cgi/trace | grep warp
docker exec warp nft list table inet cloudflare-warp   # absent in unmanaged mode, present in router/none
docker exec warp nft list chain inet cf-custom cf-router-nat   # present in router mode
docker inspect warp --format '{{.State.Health.Status}}'
```

CI runs `test.sh` automatically before any image push. A failing test prevents publication.
