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
SHARED_STATE_VOL=""

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

# Warm up one WARP registration into a shared docker volume, then reuse
# /var/lib/cloudflare-warp across every run_test. Without this, Cloudflare's
# registration API rate-limits the ~10th consecutive test (same source IP in
# rapid succession) and the container never finishes connecting → "not
# healthy". One registration per test run is enough for any non-persistence
# scenario; tests that specifically exercise fresh registration
# (state_persistence) use their own volume and bypass this.
#
# Stable name (not $$) so local dev re-runs reuse the warmed registration
# across invocations. CI is ephemeral so it still warms once per workflow.
seed_shared_state() {
    vol="warp-test-shared-state"
    docker volume inspect "$vol" > /dev/null 2>&1 || docker volume create "$vol" > /dev/null

    # If reg.json is already there, skip the warm-up container entirely.
    if docker run --rm --entrypoint /bin/sh \
        --volume "$vol:/state" "$IMAGE" \
        -c '[ -f /state/reg.json ]' 2>/dev/null; then
        SHARED_STATE_VOL="$vol"
        echo "Shared WARP state: reusing existing $vol"
        return 0
    fi

    echo "Warming up shared WARP registration in volume $vol..."
    ctr=$(docker run -d \
        --cap-add NET_ADMIN --cap-add MKNOD --cap-add AUDIT_WRITE \
        --sysctl net.ipv6.conf.all.disable_ipv6=0 \
        --sysctl net.ipv4.conf.all.src_valid_mark=1 \
        --device-cgroup-rule 'c 10:200 rwm' \
        --volume "$vol:/var/lib/cloudflare-warp" \
        "$IMAGE") || return 1

    i=0
    while [ $i -lt 40 ]; do
        if docker exec "$ctr" sh -c "[ -f /var/lib/cloudflare-warp/reg.json ]" 2>/dev/null; then
            docker rm -f "$ctr" > /dev/null 2>&1 || true
            SHARED_STATE_VOL="$vol"
            echo "Shared WARP state: registered → $vol"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done

    echo "  WARN: registration warm-up timed out — tests will register individually (may hit rate limits)"
    docker rm -f "$ctr" > /dev/null 2>&1 || true
    docker volume rm "$vol" > /dev/null 2>&1 || true
    return 1
}

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
#
# Arg-boundary preservation: we cannot concat args into a string — values
# with ';' (e.g. `-e WARP_ROUTER_ROUTES='dst=a;dst=b'`) would word-split on
# re-expansion and end up as image names. Instead: rotate `"$@"` N-1 times
# so the original last arg lands at $1 (captured as `check`), and the
# remaining docker args stay in `"$@"` with their original boundaries.
run_test() {
    name=$1; shift
    _n=$#
    _i=1
    while [ $_i -lt $_n ]; do
        _a=$1; shift
        set -- "$@" "$_a"
        _i=$((_i + 1))
    done
    check=$1; shift

    printf "\nTest: %s\n" "$name"
    container=$(docker run -d \
        --cap-add NET_ADMIN \
        --cap-add MKNOD \
        --cap-add AUDIT_WRITE \
        --sysctl net.ipv6.conf.all.disable_ipv6=0 \
        --sysctl net.ipv4.conf.all.src_valid_mark=1 \
        --device-cgroup-rule 'c 10:200 rwm' \
        --health-interval=5s \
        ${SHARED_STATE_VOL:+--volume "$SHARED_STATE_VOL:/var/lib/cloudflare-warp"} \
        "$@" \
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

test_mss_clamp_default() {
    run_test "mss clamp default on" \
        "nft list chain inet cf-custom cf-mss 2>/dev/null | grep -q 'maxseg'"
}

test_mss_clamp_disabled() {
    run_test "mss clamp disabled" \
        -e WARP_MSS_CLAMP=0 \
        "! nft list chain inet cf-custom cf-mss 2>/dev/null"
}

test_mss_clamp_routing_override() {
    run_test "mss clamp preserved with routing override" \
        -e WARP_ROUTING_OVERRIDE=1 \
        "sleep 5 \
         && ! nft list table inet cloudflare-warp 2>/dev/null \
         && nft list chain inet cf-custom cf-mss 2>/dev/null | grep -q 'maxseg'"
}

test_routing_override_none() {
    run_test "routing override none (no intervention)" \
        -e WARP_ROUTING_OVERRIDE=none \
        "sleep 5 \
         && nft list table inet cloudflare-warp > /dev/null \
         && ! nft list chain inet cf-custom cf-router-nat 2>/dev/null"
}

test_routing_override_router() {
    run_test "routing override router (state)" \
        -e WARP_MODE=warp \
        -e WARP_ROUTING_OVERRIDE=router \
        --sysctl net.ipv4.ip_forward=1 \
        --sysctl net.ipv4.conf.all.rp_filter=0 \
        --sysctl net.ipv6.conf.all.forwarding=1 \
        --sysctl net.ipv6.conf.all.accept_ra=2 \
        "sleep 12 \
         && nft list table inet cloudflare-warp > /dev/null \
         && nft list chain inet cf-custom cf-router-nat | grep -q masquerade"
}

test_routing_override_router_reconnect() {
    run_test "routing override router (reconnect repair)" \
        -e WARP_MODE=warp \
        -e WARP_ROUTING_OVERRIDE=router \
        --sysctl net.ipv4.ip_forward=1 \
        --sysctl net.ipv4.conf.all.rp_filter=0 \
        --sysctl net.ipv6.conf.all.forwarding=1 \
        --sysctl net.ipv6.conf.all.accept_ra=2 \
        "warp-cli disconnect \
         && sleep 2 \
         && warp-cli connect \
         && sleep 8 \
         && nft list table inet cloudflare-warp > /dev/null \
         && nft list chain inet cf-custom cf-router-nat | grep -q masquerade"
}

test_routing_override_router_forwarded() {
    printf "\nTest: routing override router (forwarded traffic)\n"
    net="warp-router-fwd-$$"
    docker network create --ipv6 --subnet fd00:dead:beef::/64 "$net" > /dev/null 2>&1 \
        || { fail "router forwarded" "docker network create failed"; return; }

    warp_ctr=$(docker run -d \
        --network "$net" \
        --cap-add NET_ADMIN \
        --cap-add MKNOD \
        --cap-add AUDIT_WRITE \
        --sysctl net.ipv6.conf.all.disable_ipv6=0 \
        --sysctl net.ipv4.conf.all.src_valid_mark=1 \
        --sysctl net.ipv4.ip_forward=1 \
        --sysctl net.ipv4.conf.all.rp_filter=0 \
        --sysctl net.ipv6.conf.all.forwarding=1 \
        --sysctl net.ipv6.conf.all.accept_ra=2 \
        --device-cgroup-rule 'c 10:200 rwm' \
        --health-interval=5s \
        -e WARP_MODE=warp \
        -e WARP_ROUTING_OVERRIDE=router \
        "$IMAGE") || { fail "router forwarded" "warp run failed"; docker network rm "$net" > /dev/null 2>&1; return; }

    if ! wait_healthy "$warp_ctr"; then
        fail "router forwarded" "warp container not healthy"
        docker rm -f "$warp_ctr" > /dev/null 2>&1
        docker network rm "$net" > /dev/null 2>&1
        return
    fi

    # Give the watcher one cycle to install cf-router-nat after warp connects.
    sleep 3

    warp_v4=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$net\").IPAddress}}" "$warp_ctr")
    warp_v6=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$net\").GlobalIPv6Address}}" "$warp_ctr")

    # Peer container helper: override default route to point at warp's bridge
    # IP, then curl. --user 0:0 because curlimages/curl runs as non-root by
    # default and cannot rewrite routes even with NET_ADMIN.
    peer_curl() {
        family=$1
        docker run --rm \
            --network "$net" \
            --cap-add NET_ADMIN \
            --user 0:0 \
            --sysctl net.ipv4.conf.all.rp_filter=0 \
            curlimages/curl sh -c "
set -e
ip route replace default via $warp_v4
[ -n '$warp_v6' ] && ip -6 route replace default via $warp_v6
curl -fsS -$family --max-time 15 https://cloudflare.com/cdn-cgi/trace | grep -q 'warp=on'
" > /dev/null 2>&1
    }

    if peer_curl 4; then
        pass "router forwarded (ipv4)"
    else
        fail "router forwarded (ipv4)" "peer curl did not see warp=on"
        docker logs "$warp_ctr" 2>&1 | tail -15
    fi

    # Best-effort IPv6 leg: warp-svc may not always have a global v6.
    if [ -n "$warp_v6" ]; then
        if peer_curl 6; then
            pass "router forwarded (ipv6)"
        else
            fail "router forwarded (ipv6)" "peer curl did not see warp=on"
            docker logs "$warp_ctr" 2>&1 | tail -15
        fi
    else
        echo "  SKIP: router forwarded (ipv6) — no global v6 on TUN"
    fi

    docker rm -f "$warp_ctr" > /dev/null 2>&1
    docker network rm "$net" > /dev/null 2>&1
}

test_routing_override_router_tunnel_only() {
    run_test "routing override router + tunnel_only" \
        -e WARP_MODE=tunnel_only \
        -e WARP_ROUTING_OVERRIDE=router \
        --sysctl net.ipv4.ip_forward=1 \
        --sysctl net.ipv4.conf.all.rp_filter=0 \
        --sysctl net.ipv6.conf.all.forwarding=1 \
        --sysctl net.ipv6.conf.all.accept_ra=2 \
        "sleep 10 \
         && nft list chain inet cf-custom cf-router-nat | grep -q masquerade"
}

test_routing_override_router_routes() {
    run_test "routing override router + router routes" \
        -e WARP_MODE=tunnel_only \
        -e WARP_ROUTING_OVERRIDE=router \
        -e 'WARP_ROUTER_ROUTES=dst=10.99.0.0/24,via=192.0.2.1; dst=fd99::/64,via=2001:db8::1' \
        --sysctl net.ipv4.ip_forward=1 \
        --sysctl net.ipv4.conf.all.rp_filter=0 \
        --sysctl net.ipv6.conf.all.forwarding=1 \
        --sysctl net.ipv6.conf.all.accept_ra=2 \
        "sleep 10 \
         && ip route show 10.99.0.0/24 | grep -q '192.0.2.1' \
         && ip -6 route show fd99::/64 | grep -q '2001:db8::1'"
}

test_routing_override_router_routes_malformed() {
    run_test "routing override router + malformed router routes" \
        -e WARP_MODE=tunnel_only \
        -e WARP_ROUTING_OVERRIDE=router \
        -e 'WARP_ROUTER_ROUTES=garbage; dst=10.99.0.0/24,via=192.0.2.1' \
        --sysctl net.ipv4.ip_forward=1 \
        --sysctl net.ipv4.conf.all.rp_filter=0 \
        --sysctl net.ipv6.conf.all.forwarding=1 \
        --sysctl net.ipv6.conf.all.accept_ra=2 \
        "sleep 10 \
         && ip route show 10.99.0.0/24 | grep -q '192.0.2.1'"
}

# Repro for the martian-drop black hole: the probe must distinguish between
# "masquerade rule present" and "masquerade rule missing". Approach: run
# /healthcheck.sh directly. Flush cf-router-nat and immediately probe before
# the watcher's 2s cycle can reinstall — the probe should fail. Restore and
# probe again — should pass. Tests the probe itself, not just steady-state.
test_healthcheck_detects_missing_masquerade() {
    printf "\nTest: healthcheck detects missing masquerade\n"
    ctr=$(docker run -d \
        --cap-add NET_ADMIN \
        --cap-add MKNOD \
        --cap-add AUDIT_WRITE \
        --sysctl net.ipv6.conf.all.disable_ipv6=0 \
        --sysctl net.ipv4.conf.all.src_valid_mark=1 \
        --sysctl net.ipv4.ip_forward=1 \
        --sysctl net.ipv4.conf.all.rp_filter=0 \
        --sysctl net.ipv6.conf.all.forwarding=1 \
        --sysctl net.ipv6.conf.all.accept_ra=2 \
        --device-cgroup-rule 'c 10:200 rwm' \
        --health-interval=5s \
        -e WARP_MODE=warp \
        -e WARP_ROUTING_OVERRIDE=router \
        "$IMAGE") || { fail "healthcheck black-hole" "docker run failed"; return; }

    if ! wait_healthy "$ctr"; then
        fail "healthcheck black-hole" "container never went healthy"
        docker rm -f "$ctr" > /dev/null 2>&1
        return
    fi

    # Green state: with cf-router-nat active, the probe should succeed.
    if docker exec "$ctr" /healthcheck.sh > /dev/null 2>&1; then
        pass "healthcheck black-hole (green with masquerade)"
    else
        fail "healthcheck black-hole" "probe failed with masquerade in place"
    fi

    # Red state: flush the chain and probe in the same exec so the watcher
    # (2s polling) can't race us. The probe must fail because peer-src
    # packets would reach warp-svc without SNAT and be dropped as martian.
    if docker exec "$ctr" sh -c '
        nft flush chain inet cf-custom cf-router-nat 2>/dev/null \
            || nft delete chain inet cf-custom cf-router-nat 2>/dev/null
        ! /healthcheck.sh > /dev/null 2>&1
    '; then
        pass "healthcheck black-hole (red without masquerade)"
    else
        fail "healthcheck black-hole" "probe passed despite missing masquerade"
    fi

    docker rm -f "$ctr" > /dev/null 2>&1 || true
}

test_tunnel_protocol_masque_h3() {
    # Distinguish from default-mode output: with no env vars, settings shows
    # `MASQUE (HTTP/3 with HTTP/2 fallback)` — anchored `$` rules that out.
    # Also assert the protocol line is tagged `(consumer overrides)`, which
    # only appears when our entrypoint explicitly set it (default is
    # `(network policy)`).
    run_test "tunnel protocol MASQUE + h3-only" \
        -e WARP_TUNNEL_PROTOCOL=MASQUE \
        -e WARP_MASQUE_OPTIONS=h3-only \
        "warp-cli --accept-tos settings 2>/dev/null | grep -qE 'MASQUE \\(HTTP/3\\)$' \
         && warp-cli --accept-tos settings 2>/dev/null | grep -qE '\\(consumer overrides\\)[^A-Za-z]+WARP tunnel protocol: MASQUE'"
}

# Negative path: invalid env value must be rejected by entrypoint validation
# before warp-svc even tries to apply it. Don't use run_test (it expects the
# container to go healthy); we want it to exit non-zero with a specific stderr.
test_tunnel_protocol_invalid() {
    printf "\nTest: tunnel protocol invalid value rejected\n"
    out=$(docker run --rm \
        --cap-add NET_ADMIN \
        --cap-add MKNOD \
        --cap-add AUDIT_WRITE \
        --device-cgroup-rule 'c 10:200 rwm' \
        -e WARP_TUNNEL_PROTOCOL=bogus \
        "$IMAGE" 2>&1)
    if echo "$out" | grep -q "WARP_TUNNEL_PROTOCOL='bogus' invalid"; then
        pass "tunnel protocol invalid rejected"
    else
        fail "tunnel protocol invalid rejected" "did not see expected error"
        echo "$out" | tail -10
    fi
}

# ── Run ──────────────────────────────────────────────────────────────────────

# Host-side parser unit tests — no docker required.
printf "\nRunning host-side parser tests\n"
if ./test-router-routes.sh; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
fi

# Seed shared registration; every run_test mounts it so only one registration
# hits Cloudflare's API per workflow run. Failures are non-fatal — tests fall
# back to per-container registration (and the old rate-limit flakiness).
seed_shared_state

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
    test_mss_clamp_default
    test_mss_clamp_disabled
    test_mss_clamp_routing_override
    test_routing_override_none
    test_routing_override_router
    test_routing_override_router_tunnel_only
    test_routing_override_router_reconnect
    test_routing_override_router_forwarded
    test_routing_override_router_routes
    test_routing_override_router_routes_malformed
    test_healthcheck_detects_missing_masquerade
    test_tunnel_protocol_masque_h3
    test_tunnel_protocol_invalid
fi

printf "\n==============================\n"
echo "Results: $PASS passed, $FAIL failed"
printf "==============================\n"
[ $FAIL -eq 0 ]
