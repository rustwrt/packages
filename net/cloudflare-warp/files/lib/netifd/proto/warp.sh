#!/bin/sh
# Experimental WARP netifd protocol. Not yet a production package.
[ -n "$INCLUDE_ONLY" ] || {
 . /lib/functions.sh
 . ../netifd-proto.sh
 init_proto "$@"
}
proto_warp_init_config() {
 proto_config_add_string 'endpoint' 'tunlink'
 proto_config_add_int 'mtu' 'keepalive'
 proto_config_add_boolean 'defaultroute' 'ipv6'
 proto_config_add_array 'dns'
 available=1
 no_proto_task=1
}
warp_name_ok() {
 case "$1" in ''|*[!A-Za-z0-9_-]*) return 1;; esac
 [ "${#1}" -le 15 ]
}
warp_endpoint_ok() (
 case "$1" in ''|*[!0-9.:]*|*:*:*) return 1;; esac
 host="${1%:*}"; port="${1##*:}"
 [ "$host" != "$1" ] || return 1
 case "$host" in ''|.*|*.|*..*) return 1;; esac
 case "$port" in ''|*[!0-9]*) return 1;; esac
 [ "${#port}" -le 5 ] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
 set -f; IFS=.; set -- $host
 [ "$#" = 4 ] || return 1
 for octet in "$@"; do
  case "$octet" in ''|*[!0-9]*) return 1;; esac
  [ "${#octet}" -le 3 ] && [ "$octet" -le 255 ] || return 1
 done
)
# network_find_wan selects the first netifd default route, which may differ
# from the route actually selected by the kernel when several WANs exist.
warp_default_candidate() {
 local section="$1" dev proto
 [ -z "$warp_default_link" ] || return 0
 network_is_up "$section" || return 0
 network_get_device dev "$section" || return 0
 [ "$dev" = "$warp_default_dev" ] || return 0
 network_get_protocol proto "$section" || return 0
 [ "$proto" != warp ] || return 0
 warp_default_link="$section"
}
warp_find_default_underlay() {
 local routeList routeLine
 warp_default_link=''; warp_default_dev=''
 routeList="$(ip -4 route show table main default)" || return 1
 while IFS= read -r routeLine; do
  warp_default_dev="$(printf '%s\n' "$routeLine" | awk '{for (i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
  case "$warp_default_dev" in ''|*[!A-Za-z0-9_.-]*) continue;; esac
  config_foreach warp_default_candidate interface
  [ -z "$warp_default_link" ] || break
 done <<EOF
$routeList
EOF
 [ -n "$warp_default_link" ] || return 1
 tunlink="$warp_default_link"
}
warpTransportRelease() {
 local config="$1" setupOwner="${2:-}" transportDir transportName transportOwner transportId transportPriority ruleList
 for transportDir in /tmp/warp/transport-*; do
  [ -f "$transportDir/owner" ] || continue
  read -r transportName transportOwner < "$transportDir/owner" || continue
  [ "$transportName" = "$config" ] || continue
  [ -z "$setupOwner" ] || [ "$setupOwner" = "$transportOwner" ] || continue
  transportId="${transportDir##*-}"
  case "$transportId" in ''|*[!0-9]*) continue;; esac
  [ "$transportId" -ge 51820 ] && [ "$transportId" -lt 52820 ] || continue
  transportPriority=$((transportId - 51819))
  if [ -f "$transportDir/active" ]; then
   ruleList="$(ip -4 rule show)" || return 1
   if printf '%s\n' "$ruleList" | grep -q "^[[:space:]]*$transportPriority:.*lookup $transportId\([[:space:]]\|$\)"; then
    ip -4 rule del priority "$transportPriority" fwmark "$transportId/0xffffffff" lookup "$transportId" 2>/dev/null || return 1
   fi
   ip -4 route flush table "$transportId" 2>/dev/null || return 1
  fi
  if [ -f "$transportDir/ipv6-active" ]; then
   ip -6 rule del priority "$((15000 + transportPriority))" oif "$config" lookup "$transportId" 2>/dev/null || :
   ip -6 route flush table "$transportId" 2>/dev/null || :
  fi
  rm -f "$transportDir/ipv6-active" "$transportDir/active" "$transportDir/owner"
  rmdir "$transportDir" 2>/dev/null || return 1
 done
}
warpTransportAllocate() {
 local config="$1" transportDir transportPriority ruleList ruleList6 markList tableRoutes usedToken usedValue collision ruleMark ruleMask
 ruleList="$(ip -4 rule show)" || return 1
 ruleList6="$(ip -6 rule show)" || return 1
 markList="$(wg show all fwmark)" || return 1
 transportId=51820
 while [ "$transportId" -lt 52820 ]; do
  transportPriority=$((transportId - 51819))
  transportDir="/tmp/warp/transport-$transportId"
  if mkdir -m 700 "$transportDir" 2>/dev/null; then
   printf '%s %s\n' "$config" "$$" > "$transportDir/owner" || return 1
   collision=0
   for usedToken in $(printf '%s\n%s\n' "$ruleList" "$markList" | tr ':/' '  '); do
    case "$usedToken" in
     0x*) usedValue="${usedToken#0x}"; case "$usedValue" in ''|*[!0-9a-fA-F]*) continue;; esac;;
     *) case "$usedToken" in ''|*[!0-9]*|0[0-9]*) continue;; esac;;
    esac
    usedValue=$((usedToken + 0))
    [ "$usedValue" != "$transportId" ] || collision=1
   done
   while read -r ruleMark ruleMask; do
    [ -n "$ruleMark" ] || continue
    ruleMask="${ruleMask:-4294967295}"
    if [ "$((transportId & ruleMask))" = "$((ruleMark & ruleMask))" ]; then collision=1; fi
   done <<EOF
$(printf '%s\n' "$ruleList" | awk '{for (i=1;i<NF;i++) if ($i=="fwmark") {gsub("/", " ", $(i+1)); print $(i+1)}}')
EOF
   printf '%s\n' "$ruleList" | grep -q "^[[:space:]]*$transportPriority:" && collision=1
   tableRoutes="$(ip -4 route show table "$transportId" 2>/dev/null)" || tableRoutes=''
   [ -z "$tableRoutes" ] || collision=1
   printf '%s\n' "$ruleList6" | grep -q "^[[:space:]]*$((15000 + transportPriority)):" && collision=1
   tableRoutes="$(ip -6 route show table "$transportId" 2>/dev/null)" || tableRoutes=''
   [ -z "$tableRoutes" ] || collision=1
   if [ "$collision" = 0 ]; then
    : > "$transportDir/active"
    return 0
   fi
   rm -f "$transportDir/owner"
   rmdir "$transportDir" || return 1
  fi
  transportId=$((transportId + 1))
 done
 return 1
}
warpTransportSetup() {
 local config="$1" underlayDev="$2" transportDestination="$3" routeList routeLine gateway transportPriority resolvedRoute
 routeList="$(ip -4 route show table main default dev "$underlayDev")" || return 1
 routeLine="$(printf '%s\n' "$routeList" | head -n 1)"
 [ -n "$routeLine" ] || return 1
 gateway="$(printf '%s\n' "$routeLine" | awk '{for (i=1;i<NF;i++) if ($i=="via") {print $(i+1); exit}}')"
 [ -z "$gateway" ] || warp_endpoint_ok "$gateway:1" || return 1
 warpTransportAllocate "$config" || return 1
 transportPriority=$((transportId - 51819))
 ip -4 route add unreachable default metric 42760 table "$transportId" || return 1
 ip -4 rule add priority "$transportPriority" fwmark "$transportId/0xffffffff" lookup "$transportId" || return 1
 if [ -n "$gateway" ]; then
  ip -4 route add default via "$gateway" dev "$underlayDev" onlink metric 1 table "$transportId" || return 1
 else
  ip -4 route add default dev "$underlayDev" metric 1 table "$transportId" || return 1
 fi
 resolvedRoute="$(ip -4 route get "$transportDestination" mark "$transportId")" || return 1
 printf '%s\n' "$resolvedRoute" | awk -v expectedDev="$underlayDev" -v expectedTable="$transportId" '{for (i=1;i<NF;i++) {if ($i=="dev" && $(i+1)==expectedDev) devOk=1; if ($i=="table" && $(i+1)==expectedTable) tableOk=1}} END {exit !(devOk && tableOk)}'
}
warpIPv6Setup() {
 local config="$1" id="$2" dir="/tmp/warp/transport-$2"
 [ -f "$dir/owner" ] || return 1
 : > "$dir/ipv6-active" || return 1
 ip -6 rule add priority "$((15000 + id - 51819))" oif "$config" lookup "$id" || return 1
}
warp_link_owned() {
 local config="$1" keyfile="/tmp/warp/session-$1/private.key" expected actual
 [ -s "$keyfile" ] || return 1
 expected="$(wg pubkey < "$keyfile" 2>/dev/null)" || return 1
 actual="$(wg show "$config" public-key 2>/dev/null)" || return 1
 [ -n "$expected" ] && [ "$actual" = "$expected" ]
}
warp_purge_owned() {
 local config="$1" account="$2" owner="$3" dir="/tmp/warp/session-$1" lease="/tmp/warp/account-$2.lease"
 case "$owner" in ''|*[!0-9]*) return 1;; esac
 [ -f "$dir/owner" ] && [ "$(cat "$dir/owner" 2>/dev/null)" = "$owner" ] || return 1
 rm -f "/tmp/warp/public-refresh-$config-$owner" || return 1
 rm -f "$dir/private.key" "$dir/session.json" "$dir/underlay.route" "$dir/health4" "$dir/health6" "$dir/health-state" "$dir/owner" || return 1
 rmdir "$dir" 2>/dev/null || return 1
 [ "$(cat "$lease" 2>/dev/null)" != "$config" ] || rm -f "$lease"
}
warp_remove_created() {
 local config="$1" actual
 actual="$(wg show "$config" public-key 2>/dev/null)" || return 1
 if [ -z "$actual" ] || [ "$actual" = '(none)' ] || warp_link_owned "$config"; then
  ip link del dev "$config" 2>/dev/null || return 1
 else
  proto_notify_error "$config" DEVICE_OWNERSHIP_LOST
  return 1
 fi
}
warp_cleanup() {
 local config="$1" account="$2" made="$3"
 trap - HUP INT TERM
 [ "$made" != 1 ] || warp_remove_created "$config" || return 1
 warpTransportRelease "$config" "$$" || :
 if ! /usr/sbin/warp-reg clear "$account" "$config" >/dev/null 2>&1; then
  warp_purge_owned "$config" "$account" "$$" || :
 fi
}
warp_abort_setup() {
 local config="$1" account="$2" made="$3" child="$4"
 trap - HUP INT TERM
 if [ -n "$child" ]; then kill "$child" 2>/dev/null || :; wait "$child" 2>/dev/null || :; fi
 if [ "$made" = 1 ] && [ "$(cat "/tmp/warp/session-$config/owner" 2>/dev/null)" = "$$" ]; then
  warp_remove_created "$config" || exit 1
 fi
 warpTransportRelease "$config" "$$" || :
 warp_purge_owned "$config" "$account" "$$" || :
 exit 1
}
proto_warp_setup() {
 local config="$1" account endpoint_override tunlink underlay_dev underlay_proto mtu keepalive defaultroute ipv6_enabled dns
 local sessionCommand transportId
 local ipv4 ipv6 peer endpoint private_key_file destination metadata allowed created warp_child
 underlay_dev=''; created=0; warp_child=''
 warp_name_ok "$config" || { proto_notify_error "$config" INVALID_NAME; proto_block_restart "$config"; return 1; }
 config_load network
 # Each interface gets its own persistent device; reconnects reuse it and
 # rotate the ephemeral tunnel key. Legacy UCI account options are ignored.
 account="fresh-$config"
 sessionCommand=fresh-session
 config_get endpoint_override "$config" endpoint
 config_get tunlink "$config" tunlink
 config_get mtu "$config" mtu 1280
 config_get keepalive "$config" keepalive 25
 config_get_bool defaultroute "$config" defaultroute 1
 config_get_bool ipv6_enabled "$config" ipv6 1
 config_get dns "$config" dns
 if [ -z "$dns" ]; then
  dns='1.1.1.1 1.0.0.1'
  [ "$ipv6_enabled" != 1 ] || dns="$dns 2606:4700:4700::1111 2606:4700:4700::1001"
 fi
 case "$account" in ''|*[!A-Za-z0-9_-]*) proto_notify_error "$config" INVALID_ACCOUNT; proto_block_restart "$config"; return 1;; esac
 [ "${#account}" -le 32 ] || { proto_notify_error "$config" INVALID_ACCOUNT; proto_block_restart "$config"; return 1; }
 case "$mtu" in ''|*[!0-9]*) proto_notify_error "$config" INVALID_MTU; proto_block_restart "$config"; return 1;; esac
 [ "$mtu" -ge 576 ] && [ "$mtu" -le 9000 ] || { proto_notify_error "$config" INVALID_MTU; proto_block_restart "$config"; return 1; }
 [ "$ipv6_enabled" != 1 ] || [ "$mtu" -ge 1280 ] || { proto_notify_error "$config" IPV6_MTU_TOO_SMALL; proto_block_restart "$config"; return 1; }
 case "$keepalive" in ''|*[!0-9]*) proto_notify_error "$config" INVALID_KEEPALIVE; proto_block_restart "$config"; return 1;; esac
 [ "$keepalive" -le 65535 ] || { proto_notify_error "$config" INVALID_KEEPALIVE; proto_block_restart "$config"; return 1; }
 if [ -n "$endpoint_override" ] && ! warp_endpoint_ok "$endpoint_override"; then proto_notify_error "$config" INVALID_ENDPOINT; proto_block_restart "$config"; return 1; fi
 if [ -z "$tunlink" ] || [ "$tunlink" = default ]; then
  . /lib/functions/network.sh
  network_flush_cache
  if ! warp_find_default_underlay; then
    proto_notify_error "$config" UNDERLAY_UNAVAILABLE
    proto_setup_failed "$config"
    return 1
  fi
 fi
 case "$tunlink" in *[!A-Za-z0-9_-]*) proto_notify_error "$config" INVALID_UNDERLAY; proto_block_restart "$config"; return 1;; esac
 [ "${#tunlink}" -le 32 ] || { proto_notify_error "$config" INVALID_UNDERLAY; proto_block_restart "$config"; return 1; }
 [ -z "$tunlink" ] || { [ "$tunlink" != "$config" ] && [ "$tunlink" != loopback ]; } || { proto_notify_error "$config" UNDERLAY_LOOP; proto_block_restart "$config"; return 1; }
  if ip link show dev "$config" >/dev/null 2>&1; then proto_notify_error "$config" DEVICE_EXISTS; proto_block_restart "$config"; return 1; fi
  if ! warpTransportRelease "$config"; then proto_notify_error "$config" TRANSPORT_FAILED; proto_block_restart "$config"; return 1; fi

 if [ -n "$tunlink" ]; then
  . /lib/functions/network.sh
  network_flush_cache
  # Register the logical underlay before making any API request so netifd can track WAN loss.
  if ! proto_add_host_dependency "$config" '' "$tunlink"; then proto_notify_error "$config" UNDERLAY_UNAVAILABLE; proto_setup_failed "$config"; return 1; fi
  if ! network_is_up "$tunlink" || ! network_get_device underlay_dev "$tunlink" || ! network_get_protocol underlay_proto "$tunlink"; then
   proto_notify_error "$config" UNDERLAY_UNAVAILABLE
   proto_setup_failed "$config"
   return 1
  fi
  [ "$underlay_proto" != warp ] || { proto_notify_error "$config" UNDERLAY_LOOP; proto_block_restart "$config"; return 1; }
  case "$underlay_dev" in ''|*[!A-Za-z0-9_.-]*) proto_notify_error "$config" INVALID_UNDERLAY; proto_block_restart "$config"; return 1;; esac
  [ "${#underlay_dev}" -le 15 ] || { proto_notify_error "$config" INVALID_UNDERLAY; proto_block_restart "$config"; return 1; }
 fi
 # netifd sends TERM when an in-progress setup is stopped. Kill the helper and
 # remove only files marked with this setup process's owner ID.
 trap 'warp_abort_setup "$config" "$account" "$created" "$warp_child"' HUP INT TERM
 /usr/sbin/warp-reg "$sessionCommand" "$account" "$config" "$underlay_dev" "$$" >/dev/null &
 warp_child=$!
 if ! wait "$warp_child"; then
  warp_child=''
  trap - HUP INT TERM
  warp_purge_owned "$config" "$account" "$$" || :
   proto_notify_error "$config" SESSION_FAILED
   proto_block_restart "$config"
   return 1
 fi
 warp_child=''
 metadata="/tmp/warp/session-$config/session.json"
 if [ ! -s "$metadata" ] || [ ! -s "/tmp/warp/session-$config/private.key" ]; then warp_cleanup "$config" "$account" 0; proto_notify_error "$config" BAD_SESSION; proto_block_restart "$config"; return 1; fi
 . /usr/share/libubox/jshn.sh
 json_load "$(cat "$metadata")" || { warp_cleanup "$config" "$account" 0; proto_notify_error "$config" BAD_SESSION; proto_block_restart "$config"; return 1; }
 json_get_vars ipv4 ipv6 peer endpoint private_key_file
 if [ "$ipv6_enabled" = 1 ] && [ -z "$ipv6" ]; then warp_cleanup "$config" "$account" 0; proto_notify_error "$config" NO_IPV6_ADDRESS; proto_block_restart "$config"; return 1; fi
 [ -z "$endpoint_override" ] || endpoint="$endpoint_override"
 if ! warp_endpoint_ok "$endpoint"; then warp_cleanup "$config" "$account" 0; proto_notify_error "$config" INVALID_ENDPOINT; proto_block_restart "$config"; return 1; fi
 destination="${endpoint%:*}"
 if ! ip link add dev "$config" type wireguard; then warp_cleanup "$config" "$account" 0; proto_notify_error "$config" CREATE_FAILED; proto_block_restart "$config"; return 1; fi
 created=1
 if ! ip link set dev "$config" mtu "$mtu"; then warp_cleanup "$config" "$account" "$created"; proto_notify_error "$config" SETUP_FAILED; proto_block_restart "$config"; return 1; fi
  if ! warpTransportSetup "$config" "$underlay_dev" "$destination"; then warp_cleanup "$config" "$account" "$created"; proto_notify_error "$config" TRANSPORT_FAILED; proto_block_restart "$config"; return 1; fi
  allowed='0.0.0.0/0'; [ "$ipv6_enabled" = 1 ] && allowed='0.0.0.0/0,::/0'

 if ! wg set "$config" fwmark "$transportId" private-key "/tmp/warp/session-$config/private.key" peer "$peer" endpoint "$endpoint" allowed-ips "$allowed" persistent-keepalive "$keepalive"; then warp_cleanup "$config" "$account" "$created"; proto_notify_error "$config" SETUP_FAILED; proto_block_restart "$config"; return 1; fi
 if [ "$ipv6_enabled" = 1 ]; then
  if ! warpIPv6Setup "$config" "$transportId"; then warp_cleanup "$config" "$account" "$created"; proto_notify_error "$config" IPV6_ROUTE_FAILED; proto_block_restart "$config"; return 1; fi
 fi
 # The endpoint must remain reachable outside the tunnel before any route is installed.
 if ! proto_add_host_dependency "$config" "$destination" "$tunlink"; then
  warp_cleanup "$config" "$account" "$created"
  proto_notify_error "$config" ENDPOINT_UNREACHABLE
  proto_block_restart "$config"
  return 1
 fi
 proto_init_update "$config" 1
 proto_add_ipv4_address "$ipv4" 32
 if [ "$ipv6_enabled" = 1 ] && [ -n "$ipv6" ]; then
  proto_add_ipv6_address "$ipv6" 128
  proto_add_ipv6_route "::" 0 "" "" "" "" "$transportId"
 fi
 if [ "$defaultroute" = 1 ]; then
  proto_add_ipv4_route '0.0.0.0' 0
  [ "$ipv6_enabled" = 1 ] && proto_add_ipv6_route '::' 0
 fi
 for server in $dns; do proto_add_dns_server "$server"; done
 if ! proto_send_update "$config"; then
  warp_cleanup "$config" "$account" "$created"
  proto_notify_error "$config" UPDATE_FAILED
  proto_block_restart "$config"
  return 1
 fi
 trap - HUP INT TERM
}
proto_warp_teardown() {
 local config="$1" account owner releaseTransport=1
 warp_name_ok "$config" || return 1
 if [ -f "/tmp/warp/session-$config/session.json" ]; then
  . /usr/share/libubox/jshn.sh
  json_load "$(cat "/tmp/warp/session-$config/session.json")" || return 1
  json_get_var account account
  case "$account" in ''|*[!A-Za-z0-9_-]*) return 1;; esac
  if ip link show dev "$config" >/dev/null 2>&1; then
   if warp_link_owned "$config"; then
    ip link del dev "$config" 2>/dev/null || return 1
   else
    proto_notify_error "$config" DEVICE_OWNERSHIP_LOST
    releaseTransport=0
   fi
  fi
  [ "$releaseTransport" != 1 ] || warpTransportRelease "$config" || :
  if ! /usr/sbin/warp-reg clear "$account" "$config" >/dev/null 2>&1; then
   owner="$(cat "/tmp/warp/session-$config/owner" 2>/dev/null)"
   warp_purge_owned "$config" "$account" "$owner" || :
  fi
 elif ! ip link show dev "$config" >/dev/null 2>&1; then
  warpTransportRelease "$config" || return 1
 fi
}
[ -n "$INCLUDE_ONLY" ] || add_protocol warp
