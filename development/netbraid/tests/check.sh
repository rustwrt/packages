#!/bin/sh
set -eu

R=${UCODE_ROOT:-/home/khaiphan/warp-ucode-25.12.6/sdk/staging_dir/target-x86_64_musl/root-x86}
LOADER="$R/lib/ld-musl-x86_64.so.1"
UCODE="$R/usr/bin/ucode"

if [ ! -x "$LOADER" ] || [ ! -x "$UCODE" ]; then
	echo "ucode SDK runtime not found under $R" >&2
	exit 1
fi

"$LOADER" --library-path "$R/lib:$R/usr/lib" "$UCODE" -L "$R/usr/lib/ucode" tests/run.uc
