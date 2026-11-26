#!/bin/sh
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
# Isolated shell-level netifd simulations; these do not replace an OpenWrt VM test.
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
export WARP_TEST_ROOT="$root"
mkdir -p "$root/bin" "$root/warp"
: > "$root/events"
cat > "$root/warp-reg" <<'HELPER'
#!/bin/sh
printf 'helper:%s\n' "$1" >> "$WARP_TEST_ROOT/events"
 case "$1" in session|random-session|fresh-session) printf 'underlay:%s\n' "$4" >> "$WARP_TEST_ROOT/events";; esac
dir="$WARP_TEST_ROOT/warp/session-$3"
case "$1" in
  session|random-session|fresh-session)
  if [ "$1" = fresh-session ] && [ "${WARP_TEST_FAIL_FRESH:-0}" = 1 ]; then exit 1; fi
  mkdir "$dir"; printf '%s' "$5" > "$dir/owner"; printf '%s' "$3" > "$WARP_TEST_ROOT/warp/account-$2.lease"
  printf '%s' secret-key-test-only > "$dir/private.key"
  if [ "${WARP_TEST_DELAY_SESSION:-0}" = 1 ]; then
   : > "$WARP_TEST_ROOT/started"
   sleep 30 & helper_sleep=$!
   trap 'kill "$helper_sleep" 2>/dev/null; exit 143' TERM INT HUP
   wait "$helper_sleep"
  fi
  printf '{}' > "$dir/session.json";;
 clear)
  [ ! -f "$WARP_TEST_ROOT/force_clear_fail" ] || exit 1
  rm -f "$dir/private.key" "$dir/session.json" "$dir/owner"; rmdir "$dir"; rm -f "$WARP_TEST_ROOT/warp/account-$2.lease";;
 *) exit 1;;
esac
HELPER
cat > "$root/bin/ip" <<'IP'
#!/bin/sh
printf 'ip:%s\n' "$*" >> "$WARP_TEST_ROOT/events"
case "$1:$2" in
 -6:route)
  case "$3" in
   show) [ ! -f "$WARP_TEST_ROOT/v6table-$5" ] || cat "$WARP_TEST_ROOT/v6table-$5";;
   add) printf '%s\n' "$*" > "$WARP_TEST_ROOT/v6table-$8";;
   flush) rm -f "$WARP_TEST_ROOT/v6table-$5";;
  esac;;
 -6:rule)
  case "$3" in
   show) for f in "$WARP_TEST_ROOT"/v6rule-*; do [ ! -f "$f" ] || cat "$f"; done;;
   add) printf '%s: from all oif %s lookup %s\n' "$5" "$7" "$9" > "$WARP_TEST_ROOT/v6rule-$5";;
   del) rm -f "$WARP_TEST_ROOT/v6rule-$5";;
  esac;;
 -4:route)
  case "$3" in
   show)
    [ "${WARP_TEST_ROUTE_FAIL:-0}" = 0 ] || exit 1
    [ "$5" = main ] || { [ "$5" != "${WARP_TEST_BUSY_TABLE:-0}" ] || echo 'default dev foreign'; exit 0; }
    if [ "$#" -ge 8 ]; then routeDev="$8"; else routeDev="${WARP_TEST_ROUTE_DEV:-pppoe-wan}"; fi
    [ -z "${WARP_TEST_FIRST_ROUTE:-}" ] || [ "$#" -ge 8 ] || printf '%s\n' "$WARP_TEST_FIRST_ROUTE"
    printf 'default via 192.0.2.1 dev %s src 192.0.2.2\n' "$routeDev";;
   add)
    [ "${WARP_TEST_FAIL_ROUTE_ADD:-0}" = 0 ] || exit 1
    if [ "$4" = default ]; then
     routeDev=''; routeTable=''
     while [ "$#" -gt 0 ]; do case "$1" in dev) routeDev="$2";; table) routeTable="$2";; esac; shift; done
     printf '%s\n' "$routeDev" > "$WARP_TEST_ROOT/table-$routeTable"
    fi;;
   get) printf '%s dev %s table %s\n' "$4" "${WARP_TEST_RESOLVED_DEV:-$(cat "$WARP_TEST_ROOT/table-$6")}" "$6";;
   flush) rm -f "$WARP_TEST_ROOT/table-$5";;
  esac;;
 -4:rule)
  case "$3" in
   show) printf '%s\n' "${WARP_TEST_RULES:-}"; for ruleFile in "$WARP_TEST_ROOT"/rule-*; do [ ! -f "$ruleFile" ] || cat "$ruleFile"; done;;
   add) [ "${WARP_TEST_FAIL_RULE_ADD:-0}" = 0 ] || exit 1; printf '%s: from all fwmark %s lookup %s\n' "$5" "$7" "$9" > "$WARP_TEST_ROOT/rule-$5";;
   del) rm -f "$WARP_TEST_ROOT/rule-$5";;
  esac;;
 link:show) [ -f "$WARP_TEST_ROOT/link" ];;
 link:add) : > "$WARP_TEST_ROOT/link";;
 link:del) rm -f "$WARP_TEST_ROOT/link";;
 *) :;;
esac
IP
cat > "$root/bin/wg" <<'WG'
#!/bin/sh
if [ "$1" = pubkey ]; then cat >/dev/null; printf 'public-key-test\n'; exit; fi
if [ "$1" = show ] && [ "$2" = all ]; then printf '%s\n' "${WARP_TEST_MARKS:-}"; exit 0; fi
if [ "$1" = show ]; then
 [ -f "$WARP_TEST_ROOT/link" ] || exit 1
 if [ -f "$WARP_TEST_ROOT/foreign" ]; then printf 'other-public-key\n'; else printf 'public-key-test\n'; fi
 exit
fi
printf 'wg:%s\n' "$*" >> "$WARP_TEST_ROOT/events"
WG
cat > "$root/network.sh" <<'NET'
network_flush_cache() { :; }
network_find_wan() { [ "${fail_default:-0}" = 0 ] || return 1; export "$1=${default_wan:-wan}"; }
network_is_up() { [ "${fail_underlay:-0}" = 0 ]; }
network_get_device() { export "$1=pppoe-$2"; }
network_get_protocol() { if [ "$2" = lan ]; then export "$1=warp"; else export "$1=${test_underlay_proto:-dhcp}"; fi; }
NET
cat > "$root/jshn.sh" <<'JSON'
json_load() { :; }
json_get_vars() {
 ipv4=192.0.2.10; ipv6=2001:db8::1; peer=public_key_test
 endpoint=198.51.100.10:2408; private_key_file="$WARP_TEST_ROOT/warp/session-warp0/private.key"
}
json_get_var() { account=${test_session_account:-fresh-warp0}; }
JSON
chmod +x "$root/warp-reg" "$root/bin/ip" "$root/bin/wg"
sed -e "s|/usr/sbin/warp-reg|$root/warp-reg|g" \
    -e "s|/tmp/warp/|$root/warp/|g" \
    -e "s|/usr/share/libubox/jshn.sh|$root/jshn.sh|g" \
    -e "s|/lib/functions/network.sh|$root/network.sh|g" \
    ../../net/warp/files/lib/netifd/proto/warp.sh > "$root/proto.sh"
PATH="$root/bin:$PATH"; export PATH
INCLUDE_ONLY=1
. "$root/proto.sh"
config_load() { :; }
config_foreach() { "$1" lan; "$1" wan; "$1" wan2; "$1" wan3; }
config_get() {
  case "$3" in account) value=${test_account-test};; account_mode) value=${test_account_mode-};; endpoint) value='';; tunlink) value=${test_tunlink-wan2};; metric) value=${test_metric:-0};; mtu) value=1280;; keepalive) value=25;; dns) value=${test_dns:-};; *) value='';; esac
 export "$1=$value"
}
config_get_bool() { case "$3" in defaultroute) value=${test_default:-0};; ipv6) value=${test_ipv6:-$4};; accept_tos) value=${test_accept_tos:-0};; *) value=0;; esac; export "$1=$value"; }
proto_notify_error() { printf 'error:%s\n' "$2" >> "$root/events"; }
proto_block_restart() { printf 'block\n' >> "$root/events"; }
proto_setup_failed() { printf 'retry-setup\n' >> "$root/events"; }
proto_add_host_dependency() { printf 'hostdep:%s:%s\n' "$2" "$3" >> "$root/events"; [ -z "$2" ] || [ "${fail_hostdep:-0}" = 0 ]; }
proto_init_update() { printf 'init-update\n' >> "$root/events"; }
proto_add_ipv4_address() { printf 'address\n' >> "$root/events"; }
proto_add_ipv6_address() { printf 'address6\n' >> "$root/events"; }
proto_add_ipv4_route() { printf 'route4:%s\n' "$5" >> "$root/events"; }
proto_add_ipv6_route() { printf 'route6:%s\n' "${7:-main}" >> "$root/events"; }
proto_add_dns_server() { printf 'dns:%s\n' "$1" >> "$root/events"; }
proto_send_update() { printf 'send-update\n' >> "$root/events"; [ "${fail_update:-0}" = 0 ]; }
check() { grep -Fq "$1" "$root/events" || { echo "missing event: $1" >&2; exit 1; }; }
reject() { if grep -Fq "$1" "$root/events"; then echo "unexpected event: $1" >&2; exit 1; fi; }
sleep() { if [ "$1" = 5 ]; then :; else command sleep "$@"; fi; }
test_ipv6=1
proto_warp_setup warp0
check 'route6:51820'
check 'ip:-6 rule add priority 15001 oif warp0 lookup 51820'
check 'address6'
check 'helper:fresh-session'
reject 'helper:random-session'
reject 'helper:session'
check 'hostdep::wan2'
check 'hostdep:198.51.100.10:wan2'
check 'underlay:pppoe-wan2'
check 'send-update'
check 'ip:-4 route show table main default dev pppoe-wan2'
check 'ip:-4 route add unreachable default metric 42760 table 51820'
check 'ip:-4 rule add priority 1 fwmark 51820/0xffffffff lookup 51820'
check 'ip:-4 route add default via 192.0.2.1 dev pppoe-wan2 onlink metric 1 table 51820'
check 'wg:set warp0 fwmark 51820'
reject 'route4'
reject 'secret-key-test-only'
[ -f "$root/warp/session-warp0/private.key" ]
proto_warp_teardown warp0
check 'ip:-6 rule del priority 15001 oif warp0 lookup 51820'
check 'ip:-6 route flush table 51820'
test_ipv6=0
[ ! -e "$root/warp/session-warp0/private.key" ]
check 'helper:clear'
: > "$root/events"
test_tunlink=wan
proto_warp_setup warp0
check 'hostdep:198.51.100.10:wan'
check 'underlay:pppoe-wan'
proto_warp_teardown warp0
: > "$root/events"
test_tunlink=''
proto_warp_setup warp0
check 'underlay:pppoe-wan'
check 'hostdep:198.51.100.10:wan'
proto_warp_teardown warp0
: > "$root/events"
test_tunlink=default; default_wan=wan2; export WARP_TEST_ROUTE_DEV=pppoe-wan2
proto_warp_setup warp0
check 'underlay:pppoe-wan2'
proto_warp_teardown warp0
: > "$root/events"
export WARP_TEST_ROUTE_DEV=pppoe-unmanaged
if proto_warp_setup warp0; then echo 'unmanaged default device accepted' >&2; exit 1; fi
check 'error:UNDERLAY_UNAVAILABLE'
check 'retry-setup'
reject 'helper:fresh-session'
: > "$root/events"
export WARP_TEST_ROUTE_FAIL=1
if proto_warp_setup warp0; then echo 'missing default WAN accepted' >&2; exit 1; fi
check 'error:UNDERLAY_UNAVAILABLE'
check 'retry-setup'
reject 'block'
reject 'helper:session'
unset WARP_TEST_ROUTE_FAIL WARP_TEST_ROUTE_DEV
: > "$root/events"
test_session_account=fresh-warp0
for test_account_mode in random custom fresh invalid; do
 : > "$root/events"
 proto_warp_setup warp0
 check 'helper:fresh-session'
 reject 'helper:random-session'
 reject 'helper:session'
 proto_warp_teardown warp0
 [ ! -e "$root/warp/account-fresh-warp0.lease" ]
done
: > "$root/events"
export WARP_TEST_FAIL_FRESH=1
if proto_warp_setup warp0; then echo 'failed fresh registration accepted' >&2; exit 1; fi
unset WARP_TEST_FAIL_FRESH
check 'error:SESSION_FAILED'
check 'block'
test_account_mode=''
test_account=test; test_accept_tos=0; test_session_account=fresh-warp0
: > "$root/events"
test_tunlink=wan2
fail_hostdep=1
if proto_warp_setup warp0; then echo 'host dependency failure accepted' >&2; exit 1; fi
check 'error:ENDPOINT_UNREACHABLE'
check 'ip:link del dev warp0'
check 'helper:clear'
check 'block'
reject 'send-update'
[ ! -e "$root/warp/session-warp0/private.key" ]
: > "$root/events"
fail_hostdep=0; fail_update=1
if proto_warp_setup warp0; then echo 'update failure accepted' >&2; exit 1; fi
check 'send-update'
check 'error:UPDATE_FAILED'
check 'helper:clear'
[ ! -e "$root/warp/session-warp0/private.key" ]
: > "$root/events"
fail_update=0; fail_underlay=1
if proto_warp_setup warp0; then echo 'unavailable WAN accepted' >&2; exit 1; fi
check 'error:UNDERLAY_UNAVAILABLE'
check 'retry-setup'
reject 'helper:session'
: > "$root/events"
fail_underlay=0; test_underlay_proto=warp
if proto_warp_setup warp0; then echo 'WARP used as WAN' >&2; exit 1; fi
check 'error:UNDERLAY_LOOP'
reject 'helper:session'
: > "$root/events"
test_underlay_proto=dhcp
proto_warp_setup warp0
: > "$root/foreign"
: > "$root/events"
proto_warp_teardown warp0
check 'error:DEVICE_OWNERSHIP_LOST'
reject 'ip:link del dev warp0'
[ -f "$root/link" ] && [ ! -e "$root/warp/session-warp0/private.key" ]
reject 'ip:-4 route flush table'
rm -f "$root/link" "$root/foreign"
warpTransportRelease warp0
: > "$root/events"
proto_warp_setup warp0
: > "$root/warp/session-warp0/underlay.route"
: > "$root/force_clear_fail"
warp_cleanup warp0 fresh-warp0 1
[ ! -e "$root/warp/session-warp0" ] || { echo 'legacy route blocked session cleanup' >&2; exit 1; }
rm -f "$root/force_clear_fail"
[ ! -e "$root/warp/session-warp0/private.key" ] && [ ! -e "$root/warp/account-fresh-warp0.lease" ]
: > "$root/events"
export WARP_TEST_DELAY_SESSION=1
(proto_warp_setup warp0) & setup_job=$!
i=0
while [ ! -f "$root/started" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i+1)); done
if [ ! -f "$root/started" ]; then kill "$setup_job" 2>/dev/null || :; echo 'setup did not start' >&2; exit 1; fi
kill -TERM "$setup_job"
wait "$setup_job" 2>/dev/null || :
unset WARP_TEST_DELAY_SESSION
[ ! -e "$root/warp/session-warp0/private.key" ] && [ ! -e "$root/warp/account-fresh-warp0.lease" ] || { echo 'interrupted setup left key or lease' >&2; exit 1; }
: > "$root/events"
test_tunlink=default
export WARP_TEST_FIRST_ROUTE='default dev pppoe-lan metric 0'
proto_warp_setup warp0
check 'underlay:pppoe-wan'
proto_warp_teardown warp0
unset WARP_TEST_FIRST_ROUTE
: > "$root/events"
export WARP_TEST_RULES='1: from all lookup 100'
export WARP_TEST_MARKS='foreign 0xca6d'
export WARP_TEST_BUSY_TABLE=51822
proto_warp_setup warp0
check 'wg:set warp0 fwmark 51823'
proto_warp_teardown warp0
check 'ip:-4 rule del priority 4 fwmark 51823/0xffffffff lookup 51823'
reject 'ip:-4 route flush table 51822'
unset WARP_TEST_RULES WARP_TEST_MARKS WARP_TEST_BUSY_TABLE
: > "$root/events"
warpTransportSetup warpA pppoe-wan 198.51.100.10
firstId="$transportId"
warpTransportSetup warpB pppoe-wan2 198.51.100.10
secondId="$transportId"
[ "$firstId" != "$secondId" ]
warpTransportRelease warpA
[ ! -d "$root/warp/transport-$firstId" ]
[ -d "$root/warp/transport-$secondId" ]
warpTransportRelease warpB
export WARP_TEST_RESOLVED_DEV=wrong-wan
if proto_warp_setup warp0; then echo 'wrong marked route accepted' >&2; exit 1; fi
unset WARP_TEST_RESOLVED_DEV
[ ! -d "$root/warp/transport-51820" ]
export WARP_TEST_RULES='100: from all fwmark 0xca6c/0xfffffffc lookup 200'
proto_warp_setup warp0
check 'wg:set warp0 fwmark 51824'
proto_warp_teardown warp0
unset WARP_TEST_RULES
for failureKind in WARP_TEST_FAIL_ROUTE_ADD WARP_TEST_FAIL_RULE_ADD; do
 : > "$root/events"
 export "$failureKind=1"
 if proto_warp_setup warp0; then echo 'transport failure accepted' >&2; exit 1; fi
 unset "$failureKind"
 check 'error:TRANSPORT_FAILED'
 reject 'wg:set'
 reject 'send-update'
 [ ! -d "$root/warp/transport-51820" ]
done
# No explicit ipv6 setting must enable IPv6 for new interfaces.
: > "$root/events"
unset test_ipv6
proto_warp_setup warp0
check 'address6'
check 'route6:51820'
proto_warp_teardown warp0
: > "$root/events"
test_ipv6=0
proto_warp_setup warp0
reject 'address6'
reject 'route6:'
reject 'dns:2606:4700:4700::'
proto_warp_teardown warp0
echo 'PASS: standard ipv6 option defaults to enabled; explicit 0 disables IPv6'
# DNS lists submitted by the protocol, with no real registration.
: > "$root/events"
test_ipv6=1
test_dns='9.9.9.9 2620:fe::fe'
proto_warp_setup warp0
check 'dns:9.9.9.9'
check 'dns:2620:fe::fe'
reject 'dns:1.1.1.1'
reject 'dns:1.0.0.1'
reject 'dns:2606:4700:4700::'
proto_warp_teardown warp0
: > "$root/events"
test_dns=''
proto_warp_setup warp0
check 'dns:1.1.1.1'
check 'dns:1.0.0.1'
check 'dns:2606:4700:4700::1111'
check 'dns:2606:4700:4700::1001'
proto_warp_teardown warp0
: > "$root/events"
test_ipv6=0
proto_warp_setup warp0
check 'dns:1.1.1.1'
check 'dns:1.0.0.1'
reject 'dns:2606:4700:4700::'
proto_warp_teardown warp0
echo 'PASS: custom IPv4/IPv6 DNS replaces protocol defaults; IPv4-only default DNS'
printf '%s\n' 'PASS: mocked WAN selection, isolated transport allocation, failure cleanup and session lifecycle'

# Default routes get a distinct metric even with WAN metric zero.
: > "$root/events"
test_default=1; test_tunlink=wan2; test_ipv6=1
proto_warp_setup warp0
check 'route4:51820'
[ "$(cat "$root/warp/transport-51820/default-metric")" = 51820 ]
proto_warp_teardown warp0
[ ! -e "$root/warp/transport-51820/default-metric" ]
printf '%s\n' 'PASS: automatic WARP default route metric and reservation cleanup'

# A transport can release only the MSS table it owns.
cat > "$root/bin/nft" <<'NFT'
#!/bin/sh
case "$1" in
 list) [ -f "$WARP_TEST_ROOT/nft-table-$4" ];;
 delete) rm -f "$WARP_TEST_ROOT/nft-table-$4";;
 *) exit 1;;
esac
NFT
chmod +x "$root/bin/nft"
warpTransportSetup warpA pppoe-wan 198.51.100.10
firstId="$transportId"
warpTransportSetup warpB pppoe-wan2 198.51.100.10
secondId="$transportId"
for id in "$firstId" "$secondId"; do
 echo "$$" > "$root/warp/transport-$id/mss-owner"
 : > "$root/nft-table-rustwrt_warp_mss_$id"
done
warpTransportRelease warpA
test ! -e "$root/nft-table-rustwrt_warp_mss_$firstId"
test -e "$root/nft-table-rustwrt_warp_mss_$secondId"
warpTransportRelease warpB
test ! -e "$root/nft-table-rustwrt_warp_mss_$secondId"
echo 'PASS: owned MSS table teardown isolation'
