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
printf '#!/bin/sh\nexit 0\n' > "$root/bin/sleep"
printf '#!/bin/sh\nexit 0\n' > "$root/bin/logger"
chmod +x "$root/bin/"*
PATH="$root/bin:$PATH"; export PATH
sed -e "s|/tmp/warp/session-|$root/warp/session-|g" -e "s|/tmp/warp/transport-|$root/warp/transport-|g" -e "s|/tmp/warp-health-|$root/warp-health-|g" cloudflare-warp/files/usr/libexec/warp-health > "$root/health"
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
