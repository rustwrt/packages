#!/bin/sh
set -eu
if [ ! -r /etc/openwrt_release ]; then
  echo 'error: /etc/openwrt_release not found' >&2
  exit 1
fi
. /etc/openwrt_release
version="${DISTRIB_RELEASE:-unknown}"
major="${version%%.*}"
case "$major" in
  ''|*[!0-9]*) echo 'error: invalid OpenWrt release' >&2; exit 1 ;;
esac
if [ "$major" -lt 24 ]; then
  echo 'error: OpenWrt versions below 24 are unsupported' >&2
  exit 1
fi
if command -v apk >/dev/null 2>&1; then
  manager=apk
elif command -v opkg >/dev/null 2>&1; then
  manager=opkg
else
  echo 'error: no supported package manager found' >&2
  exit 1
fi
printf 'release=%s\ntarget=%s\narchitecture=%s\npackage_manager=%s\n' \
  "$version" "${DISTRIB_TARGET:-unknown}" "${DISTRIB_ARCH:-unknown}" "$manager"
