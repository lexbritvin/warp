#!/bin/sh
# Host-side unit test for router-routes.sh. Runs in plain POSIX sh — no docker.
set -e
cd "$(dirname "$0")"
. ./router-routes.sh

fails=0
expect() {
    label=$1; want=$2; got=$3
    if [ "$want" = "$got" ]; then
        echo "ok   - $label"
    else
        echo "FAIL - $label"
        echo "       want: $want"
        echo "       got:  $got"
        fails=$((fails+1))
    fi
}
expect_match() {
    label=$1; needle=$2; hay=$3
    case "$hay" in
        *"$needle"*) echo "ok   - $label" ;;
        *) echo "FAIL - $label"
           echo "       needle: $needle"
           echo "       hay:    $hay"
           fails=$((fails+1)) ;;
    esac
}

# ── parse_router_routes ──────────────────────────────────────────────────────

# empty input → empty list
parse_router_routes "" >/dev/null
expect "empty input" "" "$WARP_ROUTER_ROUTES_LIST"

# single v4 entry
parse_router_routes "dst=10.20.0.0/24,via=10.20.1.3" >/dev/null
expect "single v4" " 4|10.20.0.0/24|10.20.1.3" "$WARP_ROUTER_ROUTES_LIST"

# single v6 entry
parse_router_routes "dst=fd3d::/64,via=fd3d::3" >/dev/null
expect "single v6" " 6|fd3d::/64|fd3d::3" "$WARP_ROUTER_ROUTES_LIST"

# mixed v4+v6 with whitespace around ';'
parse_router_routes "dst=10.20.0.0/24,via=10.20.1.3 ; dst=fd3d::/64,via=fd3d::3" >/dev/null
expect "mixed v4+v6" " 4|10.20.0.0/24|10.20.1.3 6|fd3d::/64|fd3d::3" "$WARP_ROUTER_ROUTES_LIST"

# field order doesn't matter
parse_router_routes "via=10.20.1.3,dst=10.20.0.0/24" >/dev/null
expect "field order" " 4|10.20.0.0/24|10.20.1.3" "$WARP_ROUTER_ROUTES_LIST"

# trailing semicolon is tolerated
parse_router_routes "dst=10.20.0.0/24,via=10.20.1.3;" >/dev/null
expect "trailing ;" " 4|10.20.0.0/24|10.20.1.3" "$WARP_ROUTER_ROUTES_LIST"

# $(...) runs in a subshell, so we call parse_router_routes twice for the
# negative cases below: once inside $() to capture stdout (warning text),
# once in the current shell so WARP_ROUTER_ROUTES_LIST gets updated.

# malformed entry is skipped, valid one survives
out=$(parse_router_routes "garbage; dst=10.20.0.0/24,via=10.20.1.3")
parse_router_routes "garbage; dst=10.20.0.0/24,via=10.20.1.3" >/dev/null
expect "malformed skipped (list)" " 4|10.20.0.0/24|10.20.1.3" "$WARP_ROUTER_ROUTES_LIST"
expect_match "malformed warning emitted" "skipping malformed entry: garbage" "$out"

# missing via
out=$(parse_router_routes "dst=10.20.0.0/24")
parse_router_routes "dst=10.20.0.0/24" >/dev/null
expect "missing via (list empty)" "" "$WARP_ROUTER_ROUTES_LIST"
expect_match "missing via warning" "skipping malformed entry" "$out"

# bad CIDR — no slash
out=$(parse_router_routes "dst=not-a-cidr,via=1.2.3.4")
parse_router_routes "dst=not-a-cidr,via=1.2.3.4" >/dev/null
expect "bad CIDR (list empty)" "" "$WARP_ROUTER_ROUTES_LIST"
expect_match "bad CIDR warning" "malformed CIDR: not-a-cidr" "$out"

# bad CIDR — too few v4 octets
out=$(parse_router_routes "dst=10.20.0/24,via=1.2.3.4")
parse_router_routes "dst=10.20.0/24,via=1.2.3.4" >/dev/null
expect "short v4 CIDR (list empty)" "" "$WARP_ROUTER_ROUTES_LIST"
expect_match "short v4 CIDR warning" "malformed CIDR: 10.20.0/24" "$out"

# default route v4 refused
out=$(parse_router_routes "dst=0.0.0.0/0,via=1.2.3.4")
parse_router_routes "dst=0.0.0.0/0,via=1.2.3.4" >/dev/null
expect "default v4 (list empty)" "" "$WARP_ROUTER_ROUTES_LIST"
expect_match "default v4 refused" "refusing default route: 0.0.0.0/0" "$out"

# default route v6 refused
out=$(parse_router_routes "dst=::/0,via=fd::1")
parse_router_routes "dst=::/0,via=fd::1" >/dev/null
expect "default v6 (list empty)" "" "$WARP_ROUTER_ROUTES_LIST"
expect_match "default v6 refused" "refusing default route: ::/0" "$out"

# `default` keyword refused
out=$(parse_router_routes "dst=default,via=1.2.3.4")
parse_router_routes "dst=default,via=1.2.3.4" >/dev/null
expect "default keyword (list empty)" "" "$WARP_ROUTER_ROUTES_LIST"
expect_match "default keyword refused" "refusing default route: default" "$out"

# non-zero prefix that happens to end in /0 — e.g. /10 matches *[0-9], not /0
parse_router_routes "dst=10.0.0.0/10,via=1.2.3.4" >/dev/null
expect "/10 prefix allowed" " 4|10.0.0.0/10|1.2.3.4" "$WARP_ROUTER_ROUTES_LIST"

# whitespace around '=' is strict — rejected as malformed
out=$(parse_router_routes "dst = 10.0.0.0/24,via=1.2.3.4")
parse_router_routes "dst = 10.0.0.0/24,via=1.2.3.4" >/dev/null
expect "strict = (list empty)" "" "$WARP_ROUTER_ROUTES_LIST"
expect_match "strict = warning" "skipping malformed entry" "$out"

# multiple valid entries, some with extra spaces
parse_router_routes "  dst=10.1.0.0/16,via=10.0.0.1 ;  dst=10.2.0.0/16,via=10.0.0.2  " >/dev/null
expect "multi with spaces" " 4|10.1.0.0/16|10.0.0.1 4|10.2.0.0/16|10.0.0.2" "$WARP_ROUTER_ROUTES_LIST"

# ── apply_router_routes ──────────────────────────────────────────────────────
# Mock `ip` on PATH so the applier doesn't touch real routing. The fake
# records its argv to a log file we can assert on.

TMPBIN=$(mktemp -d 2>/dev/null || mktemp -d -t warp-rr)
IP_LOG=$TMPBIN/ip.log
cat > "$TMPBIN/ip" <<FAKE
#!/bin/sh
printf '%s\n' "\$*" >> "$IP_LOG"
FAKE
chmod +x "$TMPBIN/ip"
_origpath=$PATH
PATH="$TMPBIN:$PATH"
trap 'rm -rf "$TMPBIN"; PATH=$_origpath' EXIT

# single v4 → one `ip route replace` call
: > "$IP_LOG"
WARP_ROUTER_ROUTES_LIST=" 4|10.20.0.0/24|10.20.1.3"
apply_router_routes
expect "apply v4 argv" "route replace 10.20.0.0/24 via 10.20.1.3" "$(cat "$IP_LOG")"

# single v6 → one `ip -6 route replace` call
: > "$IP_LOG"
WARP_ROUTER_ROUTES_LIST=" 6|fd3d::/64|fd3d::3"
apply_router_routes
expect "apply v6 argv" "-6 route replace fd3d::/64 via fd3d::3" "$(cat "$IP_LOG")"

# mixed — both invocations present, order irrelevant (substring match)
: > "$IP_LOG"
WARP_ROUTER_ROUTES_LIST=" 4|10.0.0.0/8|1.2.3.4 6|fd::/64|fd::1"
apply_router_routes
log=$(cat "$IP_LOG")
expect_match "apply mixed v4" "route replace 10.0.0.0/8 via 1.2.3.4" "$log"
expect_match "apply mixed v6" "-6 route replace fd::/64 via fd::1" "$log"

# empty list → no invocations
: > "$IP_LOG"
WARP_ROUTER_ROUTES_LIST=
apply_router_routes
expect "apply empty → no calls" "" "$(cat "$IP_LOG")"

# ── summary ──────────────────────────────────────────────────────────────────

if [ "$fails" = "0" ]; then
    echo "all parser + applier tests passed"
    exit 0
else
    echo "$fails test(s) failed"
    exit 1
fi
