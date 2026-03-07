# Cloudflare WARP Container image

The smallest, most complete way to run [Cloudflare WARP](https://developers.cloudflare.com/cloudflare-one/connections/connect-devices/warp/) in a container.

**Image tags follow the official Cloudflare WARP binary version.** A daily CI build checks for new WARP releases and publishes a matching tag (e.g. `2024.6.474.0`) plus `latest` automatically — no manual tracking needed.

[![Build](https://github.com/lexbritvin/warp/actions/workflows/build.yml/badge.svg)](https://github.com/lexbritvin/warp/actions/workflows/build.yml)
[![Image](https://img.shields.io/badge/ghcr.io-lexbritvin%2Fwarp-blue?logo=docker)](https://ghcr.io/lexbritvin/warp)

---

- **Tiny scratch-based image** — binaries extracted from Cloudflare's official `.deb`, stripped, running on a minimal Void Linux glibc runtime. No Ubuntu, no package manager overhead.
- **Bare TUN for custom routing** — `WARP_ROUTING_OVERRIDE` removes WARP's nftables policy and routing table, leaving a clean TUN interface you control. Compose in sing-box or any routing daemon without fighting WARP's defaults.
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
| Bare tunnel, full manual routing control | `WARP_MODE=tunnel_only` + `WARP_ROUTING_OVERRIDE=1` |

---

## Feature flags

### `WARP_ROUTING_OVERRIDE=1`

Strips all WARP-managed nftables chains (`input`, `output`, `tun` in `inet cloudflare-warp`) and flushes WARP's policy routing table (65743). The tunnel stays up — only the kernel routing rules are removed, giving you a clean slate to apply your own routing policy.

Re-applies on every reconnect via `nft monitor`. Pair with `net.ipv4.ip_forward=1` and `net.ipv6.conf.all.forwarding=1` sysctls when attaching containers that need TUN-based routing (e.g. sing-box in TUN mode).

### `WARP_DNS_EXPOSE=1`

DNATs port 53 (UDP + TCP) to `127.0.2.2:53`, making the Cloudflare DNS resolver available to attached containers. Most useful with `WARP_MODE=warp` or `warp+doh`.

### `WARP_PROXY_EXPOSE=1`

DNATs `WARP_PROXY_PORT` (TCP) to `127.0.0.1:WARP_PROXY_PORT`, making the SOCKS5 proxy accessible via Docker port mapping (`-p`). Requires `net.ipv4.conf.all.route_localnet=1` sysctl. Not needed when using `network_mode: service:warp`.

### `WARP_CONSUMER_REGISTER=1`

Forces consumer account registration even when `mdm.xml` is present. Normally, the presence of `mdm.xml` causes registration to be skipped (assumes Zero Trust enrollment).

### `WARP_DEBUG_QLOG=1`

Enables WARP qlog debug output. Disabled by default.

---

## Environment variable reference

| Variable | Default | Description |
|---|---|---|
| `WARP_MODE` | `tunnel_only` | WARP operating mode. See [Modes](#modes-warp_mode). |
| `WARP_LICENSE_KEY` | _(empty)_ | WARP+ or Teams license key. Applied after registration. |
| `WARP_PROXY_PORT` | `40000` | SOCKS5 proxy port. |
| `WARP_FAMILIES_MODE` | `off` | DNS families filtering: `off`, `full`, `malware`. |
| `WARP_ROUTING_OVERRIDE` | `0` | Strip WARP nftables and routing table. Set to `1` to enable. |
| `WARP_DNS_EXPOSE` | `0` | DNAT port 53 to Cloudflare DNS. Set to `1` to enable. |
| `WARP_PROXY_EXPOSE` | `0` | DNAT SOCKS5 port to loopback for port mapping. Set to `1` to enable. |
| `WARP_CONSUMER_REGISTER` | _(empty)_ | Force consumer registration even when `mdm.xml` exists. |
| `WARP_DEBUG_QLOG` | _(empty)_ | Enable WARP qlog debug output. |
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

### 4. Zero Trust enrollment

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
docker exec warp nft list table inet cloudflare-warp   # fails when WARP_ROUTING_OVERRIDE=1
docker inspect warp --format '{{.State.Health.Status}}'
```

CI runs `test.sh` automatically before any image push. A failing test prevents publication.
