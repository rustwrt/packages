#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
export LD_LIBRARY_PATH="$HOME/.local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PATH="$HOME/.local/bin:$PATH"
cp -r ../../utils/sponsorblocktv/files/ucode/lib "$d/"
cp tests/controller_restart_check.uc tests/fail_open_check.uc tests/cooperative_r65_check.uc tests/controller_roster_r62_check.uc "$d/"
printf 'return {};\n' > "$d/ubus.uc"
mkdir -m 700 "$d/one" "$d/two"
ucode -L "$d" "$d/controller_restart_check.uc" "$d/one" "$d/two"
cp "$d/one/controller-id" "$d/seed-before"
ucode -L "$d" "$d/controller_restart_check.uc" "$d/one" "$d/two"
cmp "$d/seed-before" "$d/one/controller-id"
echo 'PASS: identity survives a new ucode process'
for f in fail_open_check cooperative_r65_check controller_roster_r62_check; do
    timeout 20s ucode -L "$d" "$d/$f.uc"
done
