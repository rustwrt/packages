#!/bin/sh
set -eu
echo 'Guest release:'
. /etc/openwrt_release
test "$DISTRIB_RELEASE" = 24.10.8
echo "$DISTRIB_RELEASE"
echo 'Pending configuration delta fingerprints (contents withheld):'
find /tmp -maxdepth 4 -type f -path '*/.uci/*' -exec sha256sum {} \;
echo 'Required commands:'
for tool in lua wg curl flock ubus uci ip; do command -v "$tool"; done
echo 'Guest default route:'
ip -4 route show default
echo 'Existing WARP interface names:'
uci -q show network | sed -n "s/^network\.\([A-Za-z0-9_-]*\)\.proto='warp'$/\1/p"
echo 'Package files:'
test -x /usr/sbin/warp-reg
test -x /usr/libexec/rpcd/luci.warp
echo 'Preflight passed.'
