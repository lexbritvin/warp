#!/bin/sh
# Integration tests for ghcr.io/lexbritvin/warp.
# Usage: ./test.sh [--ci] [IMAGE]
#   --ci   Smoke test + proxy only (for CI environments without IPv6/tunnel support)
#   IMAGE  Image to test; builds from current directory if omitted.

set -e

CI=0
IMAGE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --ci) CI=1; shift ;;
        *)    IMAGE=$1; shift ;;
    esac
done

if [ -z "$IMAGE" ]; then
    echo "Building image from current directory..."
    IMAGE=$(docker build -q .)
    echo "Built: $IMAGE"
fi

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

# Wait for Docker healthcheck to report healthy.
wait_healthy() {
    container=$1
    i=0
    while [ $i -lt 30 ]; do
        status=$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || echo "missing")
        if [ "$status" = "healthy" ]; then return 0; fi
        printf "."
        sleep 2
        i=$((i + 1))
    done
    echo ""
    echo "  Container did not become healthy (last status: $status)"
    docker logs "$container" 2>&1 | tail -20
    return 1
}

# Wait for warp-cli to respond — does not require tunnel connectivity.
wait_running() {
    container=$1
    i=0
    while [ $i -lt 30 ]; do
        if docker exec "$container" warp-cli status > /dev/null 2>&1; then return 0; fi
        printf "."
        sleep 2
        i=$((i + 1))
    done
    echo ""
    echo "  warp-cli did not respond"
    docker logs "$container" 2>&1 | tail -20
    return 1
}

COMMON_RUN_ARGS="
    --cap-add NET_ADMIN
    --cap-add MKNOD
    --cap-add AUDIT_WRITE
    --sysctl net.ipv6.conf.all.disable_ipv6=0
    --sysctl net.ipv4.conf.all.src_valid_mark=1
    --device-cgroup-rule c 10:200 rwm
    --health-interval=5s"

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
        --health-interval=5s \
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

# ── CI tests ────────────────────────────────────────────────────────────────

test_smoke() {
    printf "\nTest: smoke\n"
    container=$(docker run -d \
        --cap-add NET_ADMIN \
        --cap-add MKNOD \
        --cap-add AUDIT_WRITE \
        --sysctl net.ipv6.conf.all.disable_ipv6=0 \
        --sysctl net.ipv4.conf.all.src_valid_mark=1 \
        --device-cgroup-rule 'c 10:200 rwm' \
        "$IMAGE") || { fail "smoke" "docker run failed"; return; }

    if wait_running "$container"; then
        pass "smoke"
    else
        fail "smoke" "warp-svc did not start"
    fi
    docker rm -f "$container" > /dev/null 2>&1 || true
}

# ── Full tests ───────────────────────────────────────────────────────────────

test_basic() {
    run_test "basic connectivity" \
        "curl -fsS https://cloudflare.com/cdn-cgi/trace | grep -q 'warp=on'"
}

test_warp_mode() {
    run_test "warp mode" \
        -e WARP_MODE=warp \
        "nslookup cloudflare.com 127.0.2.2 > /dev/null && curl -fsS https://cloudflare.com/cdn-cgi/trace | grep -q 'warp=on'"
}

test_firewall_override() {
    run_test "firewall override" \
        -e WARP_ROUTING_OVERRIDE=1 \
        "sleep 5 \
         && ! nft list table inet cloudflare-warp 2>/dev/null \
         && ! ip route show table 65743 2>/dev/null | grep -q . \
         && ! ip rule list 2>/dev/null | grep -q 'lookup 65743'"
}

test_warp_routing_override() {
    run_test "warp mode + routing override" \
        -e WARP_MODE=warp \
        -e WARP_ROUTING_OVERRIDE=1 \
        "sleep 5 \
         && ! nft list table inet cloudflare-warp 2>/dev/null \
         && ip route show table 65743 2>/dev/null | grep -q '162.159.0.0/17' \
         && nslookup cloudflare.com 127.0.2.2 > /dev/null"
}

test_dns_expose() {
    run_test "dns expose" \
        -e WARP_MODE=warp \
        -e WARP_DNS_EXPOSE=1 \
        "nslookup cloudflare.com 127.0.2.2"
}

test_proxy_expose() {
    run_test "proxy expose" \
        -e WARP_MODE=proxy \
        -e WARP_PROXY_EXPOSE=1 \
        --sysctl net.ipv4.conf.all.route_localnet=1 \
        "curl -fsS --socks5 127.0.0.1:${WARP_PROXY_PORT:-40000} https://cloudflare.com/cdn-cgi/trace | grep -q 'warp=on'"
}

test_network_attach() {
    printf "\nTest: network_mode attach\n"
    warp_ctr=$(docker run -d \
        --cap-add NET_ADMIN \
        --cap-add MKNOD \
        --cap-add AUDIT_WRITE \
        --sysctl net.ipv6.conf.all.disable_ipv6=0 \
        --sysctl net.ipv4.conf.all.src_valid_mark=1 \
        --device-cgroup-rule 'c 10:200 rwm' \
        --health-interval=5s \
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
}

test_graceful_shutdown() {
    printf "\nTest: graceful shutdown\n"
    ctr=$(docker run -d \
        --cap-add NET_ADMIN \
        --cap-add MKNOD \
        --cap-add AUDIT_WRITE \
        --sysctl net.ipv6.conf.all.disable_ipv6=0 \
        --sysctl net.ipv4.conf.all.src_valid_mark=1 \
        --device-cgroup-rule 'c 10:200 rwm' \
        "$IMAGE") || { fail "graceful shutdown" "docker run failed"; return; }

    if ! wait_running "$ctr"; then
        fail "graceful shutdown" "container did not start"
        docker rm -f "$ctr" > /dev/null 2>&1
        return
    fi

    docker stop --time 10 "$ctr" > /dev/null 2>&1
    exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$ctr" 2>/dev/null || echo "unknown")
    # 137 = SIGKILL: container hung on SIGTERM and was force-killed after timeout
    if [ "$exit_code" = "137" ]; then
        fail "graceful shutdown" "container required SIGKILL (exit 137)"
        docker logs "$ctr" 2>&1 | tail -10
    else
        pass "graceful shutdown"
    fi
    docker rm "$ctr" > /dev/null 2>&1
}

test_state_persistence() {
    printf "\nTest: state persistence\n"
    vol="warp-persist-$$"
    docker volume create "$vol" > /dev/null 2>&1

    # First run: register and write reg.json
    ctr=$(docker run -d \
        --cap-add NET_ADMIN \
        --cap-add MKNOD \
        --cap-add AUDIT_WRITE \
        --sysctl net.ipv6.conf.all.disable_ipv6=0 \
        --sysctl net.ipv4.conf.all.src_valid_mark=1 \
        --device-cgroup-rule 'c 10:200 rwm' \
        --volume "$vol:/var/lib/cloudflare-warp" \
        "$IMAGE") || { fail "state persistence" "first docker run failed"; docker volume rm "$vol" > /dev/null 2>&1; return; }

    ok=0
    if wait_running "$ctr"; then
        i=0
        while [ $i -lt 20 ]; do
            if docker exec "$ctr" sh -c "[ -f /var/lib/cloudflare-warp/reg.json ]" 2>/dev/null; then
                ok=1; break
            fi
            sleep 1; i=$((i + 1))
        done
    fi
    docker rm -f "$ctr" > /dev/null 2>&1

    if [ "$ok" = "0" ]; then
        fail "state persistence" "first run: reg.json not written"
        docker volume rm "$vol" > /dev/null 2>&1
        return
    fi

    # Second run: must reuse existing registration
    ctr=$(docker run -d \
        --cap-add NET_ADMIN \
        --cap-add MKNOD \
        --cap-add AUDIT_WRITE \
        --sysctl net.ipv6.conf.all.disable_ipv6=0 \
        --sysctl net.ipv4.conf.all.src_valid_mark=1 \
        --device-cgroup-rule 'c 10:200 rwm' \
        --volume "$vol:/var/lib/cloudflare-warp" \
        "$IMAGE") || { fail "state persistence" "second docker run failed"; docker volume rm "$vol" > /dev/null 2>&1; return; }

    if wait_running "$ctr"; then
        if docker logs "$ctr" 2>&1 | grep -q "already registered"; then
            pass "state persistence"
        else
            fail "state persistence" "second run did not reuse registration"
            docker logs "$ctr" 2>&1 | tail -10
        fi
    else
        fail "state persistence" "second container did not start"
    fi
    docker rm -f "$ctr" > /dev/null 2>&1
    docker volume rm "$vol" > /dev/null 2>&1
}

test_reconnect_firewall_watcher() {
    run_test "reconnect firewall watcher" \
        -e WARP_ROUTING_OVERRIDE=1 \
        "warp-cli disconnect \
         && sleep 2 \
         && warp-cli connect \
         && sleep 5 \
         && ! nft list table inet cloudflare-warp 2>/dev/null"
}

# ── Run ──────────────────────────────────────────────────────────────────────

if [ "$CI" = "1" ]; then
    test_smoke
    test_graceful_shutdown
    test_proxy_expose
else
    test_basic
    test_warp_mode
    test_firewall_override
    test_warp_routing_override
    test_dns_expose
    test_proxy_expose
    test_network_attach
    test_state_persistence
    test_graceful_shutdown
    test_reconnect_firewall_watcher
fi

printf "\n==============================\n"
echo "Results: $PASS passed, $FAIL failed"
printf "==============================\n"
[ $FAIL -eq 0 ]
