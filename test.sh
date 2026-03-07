#!/bin/sh
# Integration tests for ghcr.io/lexbritvin/warp.
# Usage: ./test.sh [IMAGE]
# If IMAGE is not provided, builds from the current directory.

set -e

IMAGE=${1:-}
if [ -z "$IMAGE" ]; then
    echo "Building image from current directory..."
    IMAGE=$(docker build -q .)
    echo "Built: $IMAGE"
fi

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

wait_healthy() {
    container=$1
    i=0
    while [ $i -lt 60 ]; do
        status=$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || echo "missing")
        if [ "$status" = "healthy" ]; then return 0; fi
        printf "."
        sleep 5
        i=$((i + 1))
    done
    echo ""
    echo "  Container did not become healthy (last status: $status)"
    docker logs "$container" 2>&1 | tail -20
    return 1
}

# run_test NAME [DOCKER_FLAGS...] CHECK_CMD
# All args except the first (name) and last (check) are passed to docker run.
run_test() {
    name=$1; shift
    docker_extra=""
    while [ $# -gt 1 ]; do
        docker_extra="$docker_extra $1"
        shift
    done
    check="$1"

    printf "\nTest: %s\n" "$name"
    container=$(docker run -d \
        --cap-add NET_ADMIN \
        --cap-add MKNOD \
        --cap-add AUDIT_WRITE \
        --sysctl net.ipv6.conf.all.disable_ipv6=0 \
        --sysctl net.ipv4.conf.all.src_valid_mark=1 \
        --device-cgroup-rule 'c 10:200 rwm' \
        $docker_extra \
        "$IMAGE") || { fail "$name" "docker run failed"; return; }

    if wait_healthy "$container"; then
        if docker exec "$container" sh -c "$check" > /dev/null 2>&1; then
            pass "$name"
        else
            fail "$name" "check failed"
            docker exec "$container" sh -c "$check" 2>&1 || true
        fi
    else
        fail "$name" "container not healthy"
    fi
    docker rm -f "$container" > /dev/null 2>&1 || true
}

# 1. Basic connectivity
run_test "basic connectivity" \
    "curl -fsS https://cloudflare.com/cdn-cgi/trace | grep -q 'warp=on'"

# 2. Routing override strips WARP nftables table
run_test "firewall override" \
    -e WARP_ROUTING_OVERRIDE=1 \
    "sleep 5 && ! nft list table inet cloudflare-warp 2>/dev/null"

# 3. DNS expose — WARP DNS reachable on port 53
run_test "dns expose" \
    -e WARP_MODE=warp \
    -e WARP_DNS_EXPOSE=1 \
    "nslookup cloudflare.com 127.0.2.2"

# 4. Proxy expose — SOCKS5 accessible via loopback
run_test "proxy expose" \
    -e WARP_MODE=proxy \
    -e WARP_PROXY_EXPOSE=1 \
    --sysctl net.ipv4.conf.all.route_localnet=1 \
    "curl -fsS --socks5 127.0.0.1:${WARP_PROXY_PORT:-40000} https://cloudflare.com/cdn-cgi/trace | grep -q 'warp=on'"

# 5. network_mode attach — container sharing network namespace sees warp=on
printf "\nTest: network_mode attach\n"
warp_ctr=$(docker run -d \
    --cap-add NET_ADMIN \
    --cap-add MKNOD \
    --cap-add AUDIT_WRITE \
    --sysctl net.ipv6.conf.all.disable_ipv6=0 \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    --device-cgroup-rule 'c 10:200 rwm' \
    "$IMAGE")
if wait_healthy "$warp_ctr"; then
    if docker run --rm \
        --network "container:$warp_ctr" \
        curlimages/curl \
        curl -fsS https://cloudflare.com/cdn-cgi/trace | grep -q 'warp=on'; then
        pass "network_mode attach"
    else
        fail "network_mode attach" "attached container check failed"
    fi
else
    fail "network_mode attach" "warp container not healthy"
fi
docker rm -f "$warp_ctr" > /dev/null 2>&1 || true

# Summary
printf "\n==============================\n"
echo "Results: $PASS passed, $FAIL failed"
printf "==============================\n"
[ $FAIL -eq 0 ]
