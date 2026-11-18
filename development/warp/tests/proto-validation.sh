#!/bin/sh
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
# Fail-closed checks: no network command or credential is needed for these cases.
INCLUDE_ONLY=1
. cloudflare-warp/files/lib/netifd/proto/warp.sh
error_file=$(mktemp)
trap 'rm -f "$error_file"' EXIT
config_load() { :; }
config_get() {
 case "$3" in
   account) value=${test_account:-test};; account_mode) value=${test_account_mode:-};; endpoint) value=${test_endpoint:-};; tunlink) value=${test_tunlink:-};;
  mtu) value=${test_mtu:-1280};; keepalive) value=${test_keepalive:-25};; dns) value='';;
  *) value='';;
 esac
 export "$1=$value"
}
config_get_bool() {
 case "$3" in defaultroute) value=${test_default:-0};; ipv6) value=${test_ipv6:-$4};; *) value=0;; esac
 export "$1=$value"
}
proto_notify_error() { printf '%s' "$2" > "$error_file"; }
proto_block_restart() { :; }
ip() { echo 'unexpected network command' >&2; exit 1; }
expect_failure() {
 expected=$1; name=$2
 : > "$error_file"
 if proto_warp_setup "$name"; then echo "expected $expected" >&2; exit 1; fi
 actual=$(cat "$error_file")
 [ "$actual" = "$expected" ] || { echo "expected $expected, got $actual" >&2; exit 1; }
}
test_account=test; test_mtu=1280; test_keepalive=25; test_default=0; test_ipv6=0; test_tunlink=''
expect_failure INVALID_NAME 'bad/name'
test_account=test; test_mtu=575; expect_failure INVALID_MTU warp0
test_mtu=1000; test_ipv6=1; expect_failure IPV6_MTU_TOO_SMALL warp0
test_mtu=1280; test_ipv6=0; test_keepalive=65536; expect_failure INVALID_KEEPALIVE warp0
test_keepalive=25
test_default=0; test_tunlink=warp0; expect_failure UNDERLAY_LOOP warp0
test_tunlink='bad;wan'; expect_failure INVALID_UNDERLAY warp0
test_tunlink=''; test_endpoint='999.1.1.1:2408'; expect_failure INVALID_ENDPOINT warp0
for endpoint in 198.51.100.1:2408 192.0.2.1:65535; do warp_endpoint_ok "$endpoint" || exit 1; done
for endpoint in 198.51.100.1:0 198.51.100.1:65536 999.0.0.1:1 1.1.1:24 1..1.1.1:2408; do
 if warp_endpoint_ok "$endpoint"; then echo "accepted invalid endpoint $endpoint" >&2; exit 1; fi
done
printf '%s\n' 'PASS: netifd rejects unsafe interface, MTU, keepalive, upstream and endpoint'
