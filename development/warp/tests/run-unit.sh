#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
python3 tests/dependencies.py
python3 tests/curl-binding.py
python3 tests/flock-process.py
sh tests/proto-validation.sh
sh tests/proto-integration.sh
sh tests/health-integration.sh
node tests/luci-protocol.js
node tests/luci-overview.js
if [ -n "${UCODE:-}" ]; then
 python3 tests/ucode-registration.py
 python3 tests/ucode-rpc.py
fi
