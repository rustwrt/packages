#!/bin/sh
# Read-only WARP health probe. No routes, accounts, keys or config are changed.
set -u
[ "$#" -gt 0 ] || { echo "usage: $0 INTERFACE..." >&2; exit 2; }
result=0
for iface in "$@"; do
 case "$iface" in ''|*[!A-Za-z0-9_-]*) echo "invalid interface" >&2; exit 2;; esac
 [ "${#iface}" -le 15 ] || exit 2
 if ! wg show "$iface" public-key >/dev/null 2>&1; then
  echo "$iface missing"; result=1; continue
 fi
 handshake="$(wg show "$iface" latest-handshakes 2>/dev/null | awk 'NR==1 {print $2}')"
 echo "$iface handshake=${handshake:-0}"
 for family in 4 6; do
  if [ "$family" = 4 ]; then url='https://1.1.1.1/cdn-cgi/trace'; else url='https://[2606:4700:4700::1111]/cdn-cgi/trace'; fi
  trace="$(curl -q --noproxy '*' -"$family" -fsS --connect-timeout 3 --max-time 6 --interface "if!$iface" "$url" 2>/dev/null)" || trace=''
  if printf '%s\n' "$trace" | grep -qx 'warp=on'; then
   echo "$iface IPv$family WARP OK"
  else
   echo "$iface IPv$family WARP FAILED"; result=1
  fi
 done
done
exit "$result"
