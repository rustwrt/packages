#!/usr/bin/env python3
"""Validate package recipe dependencies and metadata without requiring duplicated README tables."""
import importlib.util
from pathlib import Path

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("apk_builder", root / "tools/build-test-apk.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)
required = {
    "warp": {"ucode", "ucode-mod-fs", "coreutils-stat", "netifd", "wireguard-tools", "kmod-wireguard", "ip-full", "jshn", "flock", "curl", "ca-bundle"},
    "luci-app-warp": {"warp", "luci-base", "rpcd", "ucode", "ucode-mod-fs", "ucode-mod-uci", "ucode-mod-ubus", "wireguard-tools", "uci"},
    "luci-i18n-warp-vi": {"luci-app-warp", "luci-i18n-base-vi"},
}
assert set(builder.NAMES) == set(required)
for name, expected in required.items():
    _, version, deps, _ = builder.definition(name)
    assert version == "0.1.0-r1", (name, version)
    assert expected <= set(deps), (name, expected-set(deps))
    assert not {"lua", "lua-cjson"} & set(deps), name
assert set(builder.definition("warp")[2]) >= {"!cloudflare-warp", "!warp-proto", "!warp-reg-lua"}
print("PASS: package dependency contracts, versions and legacy conflicts match Makefiles")
