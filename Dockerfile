# syntax=docker/dockerfile:1
FROM --platform=$BUILDPLATFORM alpine:latest AS debextract

ARG TARGETARCH

RUN <<EOF
    apk add --no-cache curl tar binutils
    case "$TARGETARCH" in
        amd64) PKG_ARCH="amd64" ;;
        arm64) PKG_ARCH="arm64" ;;
        *) echo "Unsupported architecture: $TARGETARCH" && exit 1 ;;
    esac
    curl -fsSL "https://pkg.cloudflareclient.com/dists/noble/main/binary-${PKG_ARCH}/Packages.gz" \
        | gunzip | awk '/Filename: / {print $2; exit}' \
        | xargs -I{} curl -o warp.deb "https://pkg.cloudflareclient.com/{}"
    mkdir -p /warp-extracted
    ar x warp.deb
    tar -C /warp-extracted -xf data.tar.*
    find /warp-extracted/bin /warp-extracted/usr/bin -maxdepth 1 -type f \
        -exec strip --strip-all {} \; 2>/dev/null || true
EOF


FROM ghcr.io/void-linux/void-glibc-busybox:latest AS fs

RUN <<EOF
    xbps-install -Syu xbps
    xbps-install -y dbus-libs nspr nss libgcc dbus nftables curl tini iproute2
    rm -rf /var/cache/xbps/*
EOF

COPY --from=debextract /warp-extracted /tmp/warp-extracted
RUN <<EOF
    for entry in /tmp/warp-extracted/*; do
        name=$(basename "$entry")
        if [ -d "/$name" ]; then
            cp -a "$entry/." "/$name/"
        else
            cp -a "$entry" "/"
        fi
    done
    rm -rf /tmp/warp-extracted
    mkdir -p /root/.local/share/warp
    echo -n 'yes' > /root/.local/share/warp/accepted-tos.txt
EOF


FROM scratch
ARG VERSION=0.0.0

LABEL org.opencontainers.image.title="Cloudflare WARP" \
      org.opencontainers.image.description="Containerized Cloudflare WARP" \
      org.opencontainers.image.url="https://github.com/lexbritvin/warp" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.licenses="MIT"

COPY --from=fs / /
COPY entrypoint.sh healthcheck.sh router-routes.sh /

# hadolint ignore=DL3044
ENV WARP_MODE="tunnel_only" \
    WARP_LICENSE_KEY="" \
    WARP_PROXY_PORT=40000 \
    WARP_FAMILIES_MODE=off \
    WARP_ROUTING_OVERRIDE=0 \
    WARP_ROUTER_ROUTES="" \
    WARP_MSS_CLAMP=1 \
    WARP_AUTOHEAL=1 \
    WARP_DNS_EXPOSE=0 \
    WARP_PROXY_EXPOSE=0 \
    WARP_CONSUMER_REGISTER="" \
    WARP_DEBUG_QLOG=""

ENV STATE_DIRECTORY=/var/lib/cloudflare-warp \
    RUNTIME_DIRECTORY=/run/cloudflare-warp \
    LOGS_DIRECTORY=/run/log/cloudflare-warp

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 CMD /healthcheck.sh
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
