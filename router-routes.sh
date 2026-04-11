#!/bin/sh
# Parser + applier for WARP_ROUTER_ROUTES. Sourced by entrypoint.sh and by
# test-router-routes.sh. Pure POSIX sh — no bash-isms, no external deps, no
# IFS manipulation.

# parse_router_routes <raw-string>
#   Sets WARP_ROUTER_ROUTES_LIST to a space-separated stream of
#   "<fam>|<dst>|<gw>" tokens. Writes warnings + accepted-route lines to
#   stdout. Malformed/dangerous entries are skipped, not fatal.
parse_router_routes() {
    _raw=$1
    WARP_ROUTER_ROUTES_LIST=
    [ -n "$_raw" ] || return 0

    # Split on ';' via parameter expansion — no IFS juggling.
    while [ -n "$_raw" ]; do
        case "$_raw" in
            *";"*) _entry=${_raw%%;*}; _raw=${_raw#*;} ;;
            *)     _entry=$_raw; _raw= ;;
        esac

        # Strip leading/trailing whitespace. printf (not echo) avoids the
        # `-e`/`-n` interpretation footgun on some shells.
        _entry=$(printf '%s' "$_entry" | awk '{$1=$1; print}')
        [ -z "$_entry" ] && continue

        # Split entry on ',' — same parameter-expansion trick.
        _dst= ; _via=
        _kvs=$_entry
        while [ -n "$_kvs" ]; do
            case "$_kvs" in
                *","*) _kv=${_kvs%%,*}; _kvs=${_kvs#*,} ;;
                *)     _kv=$_kvs; _kvs= ;;
            esac
            case "$_kv" in
                dst=*) _dst=${_kv#dst=} ;;
                via=*) _via=${_kv#via=} ;;
            esac
        done

        if [ -z "$_dst" ] || [ -z "$_via" ]; then
            echo "WARNING: WARP_ROUTER_ROUTES: skipping malformed entry: $_entry"
            continue
        fi

        # Refuse any default route (`/0` prefix or the `default` keyword) —
        # `ip route replace` would clobber the container/host's own default
        # route and silently break all egress.
        case "$_dst" in
            */0|default|0.0.0.0|::)
                echo "WARNING: WARP_ROUTER_ROUTES: refusing default route: $_dst"
                continue
                ;;
        esac

        # Loose CIDR shape check — catches typos at startup instead of
        # silent-fail at `ip route replace` time. Exhaustive validation is
        # the kernel's job; we only want to reject obvious garbage.
        case "$_dst" in
            *.*.*.*/*[0-9]) _fam=4 ;;
            *:*/*[0-9])     _fam=6 ;;
            *)
                echo "WARNING: WARP_ROUTER_ROUTES: malformed CIDR: $_dst"
                continue
                ;;
        esac

        echo "Router route: v$_fam $_dst via $_via"
        WARP_ROUTER_ROUTES_LIST="$WARP_ROUTER_ROUTES_LIST $_fam|$_dst|$_via"
    done

    unset _raw _entry _dst _via _fam _kv _kvs
}

# apply_router_routes
#   Called every watch cycle from configure_router_mode(). Uses `ip route
#   replace` so the kernel doesn't complain about existing entries. Routes go
#   into the main table (not $WARP_RT): return traffic un-masqueraded from the
#   TUN is looked up there. stderr is intentionally NOT suppressed — real
#   failures (unreachable gateway, kernel rejection) should surface in docker
#   logs. `|| true` keeps the function non-fatal.
apply_router_routes() {
    _list=$WARP_ROUTER_ROUTES_LIST
    while [ -n "$_list" ]; do
        _list=${_list# }
        case "$_list" in
            *" "*) _token=${_list%% *}; _list=${_list#* } ;;
            *)     _token=$_list; _list= ;;
        esac
        [ -z "$_token" ] && continue
        _fam=${_token%%|*}
        _rest=${_token#*|}
        _dst=${_rest%%|*}
        _via=${_rest#*|}
        if [ "$_fam" = "6" ]; then
            ip -6 route replace "$_dst" via "$_via" || true
        else
            ip route replace "$_dst" via "$_via" || true
        fi
    done
    unset _list _token _fam _rest _dst _via
}
