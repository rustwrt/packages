#!/bin/sh
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
export WARP_HEALTH_TEST_ROOT="$root"
mkdir -p "$root/bin" "$root/warp/session-warp0" "$root/warp/transport-51820"
printf '123' > "$root/warp/session-warp0/owner"
printf 'warp0 123\n' > "$root/warp/transport-51820/owner"
: > "$root/warp/transport-51820/ipv6-active"
cat > "$root/bin/wg" <<'WG'
#!/bin/sh
case "$1:$3" in
 show:public-key) echo test-public;;
 show:peers) echo test-peer;;
 show:fwmark) echo 0xca6c;;
 show:endpoints) echo "test-peer $(cat "$WARP_HEALTH_TEST_ROOT/endpoint" 2>/dev/null || echo 162.159.192.8:2408)";;
 show:latest-handshakes) echo "test-peer $(cat "$WARP_HEALTH_TEST_ROOT/handshake" 2>/dev/null || echo 0)";;
 set:*) echo "$*" >> "$WARP_HEALTH_TEST_ROOT/wg-set"; echo "$6" > "$WARP_HEALTH_TEST_ROOT/endpoint"; date +%s > "$WARP_HEALTH_TEST_ROOT/handshake";;
 *) exit 1;;
esac
WG
cat > "$root/bin/ip" <<'IP'
#!/bin/sh
case "$3" in
 show) [ ! -f "$WARP_HEALTH_TEST_ROOT/route" ] || cat "$WARP_HEALTH_TEST_ROOT/route";;
 add) echo "default dev warp0 table 51820" > "$WARP_HEALTH_TEST_ROOT/route";;
esac
IP
cat > "$root/bin/uci" <<'UCI'
#!/bin/sh
[ ! -f "$WARP_HEALTH_TEST_ROOT/override" ] || cat "$WARP_HEALTH_TEST_ROOT/override"
UCI
cat > "$root/bin/curl" <<'CURL'
#!/bin/sh
echo 'ip=192.0.2.4'
echo 'warp=on'
CURL
printf '#!/bin/sh\nexit 0\n' > "$root/bin/ping"
cp "$root/bin/ping" "$root/bin/ping6"
cat > "$root/bin/nft" <<'NFT'
#!/bin/sh
case "$1" in
 list) [ -f "$WARP_HEALTH_TEST_ROOT/nft-rules" ];;
 -f) cat > "$WARP_HEALTH_TEST_ROOT/nft-rules";;
 *) exit 1;;
esac
NFT
mkdir -p "$root/sys/warp0"
echo 1280 > "$root/sys/warp0/mtu"
printf '#!/bin/sh\nexit 0\n' > "$root/bin/sleep"
printf '#!/bin/sh\nexit 0\n' > "$root/bin/logger"
chmod +x "$root/bin/"*
PATH="$root/bin:$PATH"; export PATH
sed -e "s|/tmp/warp/session-|$root/warp/session-|g" -e "s|/tmp/warp/transport-|$root/warp/transport-|g" -e "s|/tmp/warp-health-|$root/warp-health-|g" -e "s|/tmp/warp/.mss-|$root/warp/.mss-|g" -e "s|/sys/class/net/|$root/sys/|g" ../../net/warp/files/usr/libexec/warp-health > "$root/health"
sh "$root/health" warp0
grep -q 'endpoint 162.159.192.2:2408' "$root/wg-set"
grep -q '^default dev warp0 ' "$root/route"
test -s "$root/warp/session-warp0/health4"
test -s "$root/warp/session-warp0/health6"
# Explicit endpoint suppresses fallback; failed connectivity is reported.
rm -f "$root/handshake" "$root/wg-set" "$root/endpoint" "$root/warp/session-warp0/health4" "$root/warp/session-warp0/health6"
printf '192.0.2.1:2408' > "$root/override"
sh "$root/health" warp0
test ! -e "$root/wg-set"
grep -qx handshake_timeout "$root/warp/session-warp0/health-state"
# Refreshing Public IP must not rotate the endpoint or mutate routes.
rm -f "$root/override" "$root/route" "$root/wg-set"
sh "$root/health" warp0 refresh
test ! -e "$root/wg-set" && test ! -e "$root/route"
test -s "$root/warp/session-warp0/health4" && test -s "$root/warp/session-warp0/health6"
# A different owner cannot make any route or endpoint changes.
printf 'wrong 123\n' > "$root/warp/transport-51820/owner"
rm -f "$root/route"
if sh "$root/health" warp0; then echo 'foreign transport accepted' >&2; exit 1; fi
test ! -e "$root/route"
echo 'PASS: bounded endpoint fallback, IPv6 repair, explicit endpoint and ownership isolation'

# Healthy tunnels never install MSS rules. A failed TLS check plus an observed
# packet-size boundary triggers per-family recovery.
test ! -e "$root/nft-rules"
printf 'warp0 123\n' > "$root/warp/transport-51820/owner"
date +%s > "$root/handshake"
cat > "$root/bin/curl" <<'CURL'
#!/bin/sh
[ -f "$WARP_HEALTH_TEST_ROOT/nft-rules" ] || exit 28
echo 'ip=192.0.2.4'
echo 'warp=on'
CURL
cat > "$root/bin/ping" <<'PING'
#!/bin/sh
size=0
while [ "$#" -gt 0 ]; do
 if [ "$1" = -s ]; then size="$2"; shift; fi
 shift
done
[ ! -e "$WARP_HEALTH_TEST_ROOT/block-ping" ] || exit 1
[ ! -e "$WARP_HEALTH_TEST_ROOT/large-ping-ok" ] || exit 0
case "$0" in *ping6) overhead=48;; *) overhead=28;; esac
[ "$((size+overhead))" -le 1216 ]
PING
cp "$root/bin/ping" "$root/bin/ping6"
chmod +x "$root/bin/"*
rm -f "$root/warp/session-warp0/health4" "$root/warp/session-warp0/health6"
sh "$root/health" warp0 refresh
test ! -e "$root/nft-rules"
: > "$root/block-ping"
sh "$root/health" warp0
test ! -e "$root/nft-rules"
rm -f "$root/block-ping"
: > "$root/large-ping-ok"
sh "$root/health" warp0
test ! -e "$root/nft-rules"
rm -f "$root/large-ping-ok"
sh "$root/health" warp0
grep -q 'meta nfproto ipv4 oifname "warp0".*set 1136' "$root/nft-rules"
grep -q 'meta nfproto ipv6 iifname "warp0".*set 1120' "$root/nft-rules"
[ "$(cat "$root/warp/transport-51820/mss-owner")" = 123 ]
test -s "$root/warp/session-warp0/health4"
test -s "$root/warp/session-warp0/health6"
echo 'PASS: adaptive PMTU, healthy/blocked ICMP paths, refresh isolation and HTTPS recovery'
