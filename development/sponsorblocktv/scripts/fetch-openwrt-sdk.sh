#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Fetch and extract an OpenWrt SDK for building the SponsorBlock feed.
#
# The SDK is the supported way to build out-of-tree packages without a full
# buildroot checkout. It contains the cross toolchain, the target rootfs stubs
# and the package build system.
#
# Usage:
#   scripts/fetch-openwrt-sdk.sh [workdir]
#
# Environment:
#   OPENWRT_RELEASE   "snapshots" (default) or a release such as "24.10.4"
#   OPENWRT_TARGET    default "x86"
#   OPENWRT_SUBTARGET default "64"
#   OPENWRT_SDK_URL   override the whole download URL (skips discovery)
#
# Notes:
#   * OpenWrt snapshots and >= 24.10 build with apk; older releases build ipk.
#     The package format only affects the produced artifact, not this script.
#   * Extraction needs tar + zstd (or xz for older SDKs).
set -eu

WORKDIR=${1:-${WORKDIR:-$PWD/.openwrt-sdk}}

OPENWRT_RELEASE=${OPENWRT_RELEASE:-snapshots}
OPENWRT_TARGET=${OPENWRT_TARGET:-x86}
OPENWRT_SUBTARGET=${OPENWRT_SUBTARGET:-64}

die() { echo "fetch-openwrt-sdk: $*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"; }
need curl
need tar

case "$OPENWRT_RELEASE" in
	snapshots) BASE="https://downloads.openwrt.org/snapshots" ;;
	*)         BASE="https://downloads.openwrt.org/releases/$OPENWRT_RELEASE" ;;
esac

TARGET_DIR="$BASE/targets/$OPENWRT_TARGET/$OPENWRT_SUBTARGET"

if [ -n "${OPENWRT_SDK_URL:-}" ]; then
	SDK_URL=$OPENWRT_SDK_URL
else
	echo "Discovering SDK in $TARGET_DIR ..." >&2
	LISTING=$(curl -fsSL --max-time 60 "$TARGET_DIR/") \
		|| die "cannot list $TARGET_DIR"
	SDK_NAME=$(printf '%s\n' "$LISTING" \
		| grep -oE 'openwrt-sdk-[A-Za-z0-9._-]+Linux-x86_64\.tar\.(zst|xz)' \
		| sort -u | head -n1)
	[ -n "$SDK_NAME" ] || die "no SDK tarball found in $TARGET_DIR"
	SDK_URL="$TARGET_DIR/$SDK_NAME"
fi

SDK_ARCHIVE=${SDK_URL##*/}
mkdir -p "$WORKDIR"
cd "$WORKDIR"

if [ ! -f "$SDK_ARCHIVE" ]; then
	echo "Downloading $SDK_URL ..." >&2
	curl -fL --retry 3 --max-time 1800 -o "$SDK_ARCHIVE.part" "$SDK_URL" \
		|| die "download failed"
	mv "$SDK_ARCHIVE.part" "$SDK_ARCHIVE"
fi

SDK_ROOT="$WORKDIR/${SDK_ARCHIVE%.tar.*}"
if [ ! -d "$SDK_ROOT" ]; then
	echo "Extracting $SDK_ARCHIVE ..." >&2
	case "$SDK_ARCHIVE" in
		*.tar.zst) need zstd; tar --zstd -xf "$SDK_ARCHIVE" ;;
		*.tar.xz)  tar -xf "$SDK_ARCHIVE" ;;
		*)         die "unsupported archive: $SDK_ARCHIVE" ;;
	esac
fi

# The tarball extracts to a directory named after itself; be defensive.
if [ ! -d "$SDK_ROOT" ]; then
	SDK_ROOT=$(find "$WORKDIR" -maxdepth 1 -type d -name 'openwrt-sdk-*' | head -n1)
fi
[ -d "$SDK_ROOT" ] || die "could not locate extracted SDK root"

echo
echo "SDK ready: $SDK_ROOT"
echo "Next: OPENWRT_DIR=\"$SDK_ROOT\" scripts/build-openwrt.sh"
