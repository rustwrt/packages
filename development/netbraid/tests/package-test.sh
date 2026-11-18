#!/bin/sh
set -eu

R=${UCODE_ROOT:-/home/khaiphan/warp-ucode-25.12.6/sdk/staging_dir/target-x86_64_musl/root-x86}
LOADER="$R/lib/ld-musl-x86_64.so.1"
UCODE="$R/usr/bin/ucode"
LIBS="$R/lib:$R/usr/lib"
MODULES="$R/usr/lib/ucode"

if [ ! -x "$LOADER" ] || [ ! -x "$UCODE" ]; then
	echo "ucode SDK runtime not found under $R" >&2
	exit 1
fi

cd "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
for test_file in tests/*.uc; do
	"$LOADER" --library-path "$LIBS" "$UCODE" -L "$MODULES" "$test_file"
done
