#!/bin/bash
# Verify ucode sources with the SDK compiler: libraries are compiled through an
# import (where `export` is legal); entrypoints are compiled as scripts.
set -u
ROOT=${UCODE_ROOT:-/home/khaiphan/warp-ucode-25.12.6/sdk/staging_dir/target-x86_64_musl/root-x86}
LOADER=${UCODE_LOADER:-/home/khaiphan/warp-ucode-25.12.6/sdk/staging_dir/toolchain-x86_64_gcc-14.3.0_musl/lib/ld-musl-x86_64.so.1}
UCODE="$ROOT/usr/bin/ucode"
LIBS="$ROOT/lib:$ROOT/usr/lib"
MODULES="$ROOT/usr/lib/ucode"
PROJECT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

ucode() { "$LOADER" --library-path "$LIBS" "$UCODE" "$@"; }

status=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for source in "$PROJECT"/../net/netbraid/files/usr/lib/netbraid/*.uc; do
  name=${source##*/}
  printf "import * as module from '%s';\n" "$source" > "$tmp/import.uc"
  if ucode -L "$MODULES" -c -o "$tmp/module.ucb" "$tmp/import.uc" >/dev/null 2>&1 && [ -s "$tmp/module.ucb" ]; then
    echo "PASS compile module $name"
  else
    echo "FAIL compile module $name" >&2
    status=1
  fi
done

rpcd_script="$PROJECT/../net/netbraid/files/usr/libexec/rpcd/netbraid.uc"
rpcd_import="$tmp/rpcd-import.uc"
sed -e "s#^import .*runtime\.uc';#import { query, toWire } from '$PROJECT/../net/netbraid/files/usr/lib/netbraid/runtime.uc';#" \
    -e "s#^import .*detection-status\.uc';#import { detectionStatus } from '$PROJECT/../net/netbraid/files/usr/lib/netbraid/detection-status.uc';#" \
    "$rpcd_script" > "$rpcd_import"
if ucode -L "$MODULES" -c -o "$tmp/rpcd.ucb" "$rpcd_import" >/dev/null 2>&1 && [ -s "$tmp/rpcd.ucb" ]; then
  echo "PASS compile script net/netbraid/files/usr/libexec/rpcd/netbraid.uc (absolute import rewritten to SDK path)"
else
  echo "FAIL compile script net/netbraid/files/usr/libexec/rpcd/netbraid.uc" >&2
  status=1
fi

for source in "$PROJECT"/tests/*.uc; do
  name=${source#"$PROJECT"/}
  if ucode -L "$MODULES" -c -o "$tmp/test.ucb" "$source" >/dev/null 2>&1 && [ -s "$tmp/test.ucb" ]; then
    echo "PASS compile script $name"
  else
    echo "FAIL compile script $name" >&2
    status=1
  fi
done

for test_file in "$PROJECT"/tests/*.uc; do
  name=${test_file#"$PROJECT"/}
  if ucode -L "$MODULES" "$test_file" >/dev/null; then
    echo "PASS test $name"
  else
    echo "FAIL test $name" >&2
    status=1
  fi
done

exit "$status"
