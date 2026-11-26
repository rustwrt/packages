#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build the SponsorBlockTV packages (native ucode runtime) inside an OpenWrt
# SDK or a full buildroot checkout.
#
# Usage:
#   OPENWRT_DIR=/path/to/openwrt-sdk scripts/build-openwrt.sh [package ...]
#
# With no arguments every package in this feed is built:
#   sponsorblocktv and luci-app-sponsorblocktv.
#
# Environment:
#   OPENWRT_DIR   SDK/buildroot root (default: current directory)
#   REPO_DIR      this repository (default: parent of this script)
#   FEED_NAME     feed name used in feeds.conf (default: sponsorblocktv)
#   JOBS          parallelism passed to make -j (default: nproc)
#   V             "s" for verbose make output (default: unset)
#
# The script is idempotent: re-running it refreshes the feed and rebuilds.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=${REPO_DIR:-$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)}
OPENWRT_DIR=${OPENWRT_DIR:-$(pwd)}

FEED_NAME=${FEED_NAME:-rustwrt}
# OpenWrt's scripts/feeds parses feed names as \w+ only (no dashes; a dash would
# be reported as a feeds.conf syntax error), so the LuCI feed name is suffixed
# without a separator.
LUCI_FEED_NAME="${FEED_NAME}luci"
JOBS=${JOBS:-$( (nproc 2>/dev/null || echo 1) )}

die() { echo "build-openwrt: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[ -f "$OPENWRT_DIR/rules.mk" ] || die "$OPENWRT_DIR does not look like an OpenWrt SDK/buildroot (no rules.mk)"
[ -d "$REPO_DIR/utils/sponsorblocktv" ] || die "cannot find utils/sponsorblocktv under $REPO_DIR"
[ -d "$REPO_DIR/luci/luci-app-sponsorblocktv" ] || die "cannot find luci/luci-app-sponsorblocktv under $REPO_DIR"
command -v make >/dev/null 2>&1 || die "make not found"

PKG_DIRS=""
for d in "$REPO_DIR"/utils/sponsorblocktv/; do
	[ -f "$d/Makefile" ] || continue
	PKG_DIRS="$PKG_DIRS $d"
done

# Target package names this repository defines. The directory name equals the
# target package name for every recipe under package/.
OUR_PACKAGES="luci-app-sponsorblocktv luci-i18n-sponsorblocktv-vi"
for d in $PKG_DIRS; do
	name=$(basename "$d")
	OUR_PACKAGES="$OUR_PACKAGES $name"
done

# Default build list: all packages in the feed, plus the LuCI app.
DEFAULT_PACKAGES=""
for d in $PKG_DIRS; do
	name=$(basename "$d")
	DEFAULT_PACKAGES="$DEFAULT_PACKAGES package/$name/compile"
done
DEFAULT_PACKAGES="$DEFAULT_PACKAGES package/luci-app-sponsorblocktv/compile package/luci-i18n-sponsorblocktv-vi/compile"

if [ "$#" -gt 0 ]; then
	BUILD_TARGETS=""
	for p in "$@"; do
		BUILD_TARGETS="$BUILD_TARGETS package/$p/compile"
	done
else
	BUILD_TARGETS="$DEFAULT_PACKAGES"
fi

cd "$OPENWRT_DIR"

# --- feed registration -------------------------------------------------------
# Prefer feeds.conf (user owned) and derive it from feeds.conf.default on first
# run, so the SDK's stock feeds are preserved and our additions are separate.
FEEDS_CONF=feeds.conf
if [ ! -f "$FEEDS_CONF" ] && [ -f feeds.conf.default ]; then
	cp feeds.conf.default "$FEEDS_CONF"
fi
[ -f "$FEEDS_CONF" ] || die "no feeds.conf / feeds.conf.default in $OPENWRT_DIR"

add_feed() {
	name=$1 path=$2
	if grep -q "^src-link $name " "$FEEDS_CONF"; then
		grep -Fxq "src-link $name $path" "$FEEDS_CONF" || die "feed $name points to another path"
		info "feed $name already registered"
	else
		info "registering feed $name -> $path"
		printf 'src-link %s %s\n' "$name" "$path" >> "$FEEDS_CONF"
	fi
}

add_feed "$FEED_NAME" "$REPO_DIR"

info "updating feeds"
./scripts/feeds update -a

info "installing feed packages"
./scripts/feeds install -a

# --- configuration -----------------------------------------------------------
# The SDK ships no .config; defconfig materialises the target defaults and every
# installed package's symbols before a package/<name>/compile is attempted.
info "generating default configuration"
make defconfig

# --- duplicate package guard -------------------------------------------------
# tmp/.config-package.in holds one `config PACKAGE_<name>` stanza per target
# package across *all* enabled feeds; a name appearing twice means two feeds
# define it and the build would be ambiguous.
info "checking for duplicate package definitions"
if [ -f tmp/.config-package.in ]; then
	all_dupes=$(sed -n \
		's/^[[:space:]]*config[[:space:]]*\(PACKAGE_[A-Za-z0-9_.-]*\)[[:space:]]*$/\1/p' \
		tmp/.config-package.in | sort | uniq -d)
	our_dupes=""
	for pkg in $OUR_PACKAGES; do
		case " $all_dupes " in
			*" PACKAGE_$pkg "*) our_dupes="$our_dupes $pkg" ;;
		esac
	done
	[ -z "$our_dupes" ] || die "also defined by another enabled feed:$our_dupes -- only one feed may provide a package name; disable the other provider or use a snapshot tree"
fi

# --- build -------------------------------------------------------------------
info "building:$BUILD_TARGETS"
FLAGS=""
[ -n "${V:-}" ] && FLAGS="-V=$V"
# shellcheck disable=SC2086
make -j"$JOBS" $BUILD_TARGETS $FLAGS

# --- package index -----------------------------------------------------------
# Generates bin/packages/<arch>/<feed>/packages.adb so the feed is directly
# installable (apk add --allow-untrusted -X bin/packages/<arch>/<feed> <pkg>).
info "generating package index"
make package/index

# --- collect artifacts -------------------------------------------------------
BIN_DIR=bin
info "packages produced:"
# Layout is bin/packages/<arch>/<feed>/<pkg>.apk, i.e. depth 4 below bin/.
find "$BIN_DIR" -maxdepth 5 -type f \( -name '*.apk' -o -name '*.ipk' \) 2>/dev/null \
	| grep -E 'sponsorblocktv' | sort || true

echo
echo "Build finished. Inspect $OPENWRT_DIR/$BIN_DIR for the .apk/.ipk artifacts."
