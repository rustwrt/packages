#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
d=$(mktemp -d)
pid=
trap 'if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || :; fi; rm -rf "$d"' EXIT
export LD_LIBRARY_PATH="$HOME/.local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
if ! command -v ucode >/dev/null && [ -x "$HOME/.local/bin/ucode" ]; then
    export PATH="$HOME/.local/bin:$PATH"
fi
command -v ucode >/dev/null || { echo "ucode interpreter unavailable" >&2; exit 1; }
cp -r ../../utils/sponsorblocktv/files/ucode/lib "$d/"
cp tests/*.uc "$d/"
printf 'return {};\n' > "$d/ubus.uc"
pass=0; fail=0
for f in "$d"/*.uc; do
    case "$f" in */ubus.uc|*/http_loopback_r36_check.uc|*/http_tls_pool_check.uc|*/stats_r80_check.uc|*/device_policy_store_r53_check.uc|*/whitelist_network_r57.uc) continue;; esac
    args=()
    case "$f" in
        */whitelist_html_r57.uc) args=("$PWD/build/r57-watch-fixtures");;
        */controller_restart_check.uc) mkdir -m 700 "$d/controller-one" "$d/controller-two"; args=("$d/controller-one" "$d/controller-two");;
    esac
    if timeout 20s ucode -g 1000 -L "$d" "$f" "${args[@]}"; then
        echo "PASS $(basename "$f")"; pass=$((pass+1))
    else
        echo "FAIL $(basename "$f")"; fail=$((fail+1))
    fi
done
python3 tests/http_loopback_fixture.py "$d/port" &
pid=$!
for i in $(seq 1 50); do [ ! -s "$d/port" ] || break; sleep .1; done
if [ -s "$d/port" ] && timeout 15s ucode -g 1000 -L "$d" "$d/http_loopback_r36_check.uc" "$(cat "$d/port")"; then
    echo 'PASS http_loopback_r36_check.uc'; pass=$((pass+1))
else
    echo 'FAIL http_loopback_r36_check.uc'; fail=$((fail+1))
fi
echo "HOST UCODE: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
