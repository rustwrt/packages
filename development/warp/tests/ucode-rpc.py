#!/usr/bin/env python3
"""Regression test the native ucode WARP RPC against mocked ubus and commands.

The production script is executed by the real ucode interpreter with UCI, fs
and JSON modules. Only the ubus connection and external commands are mocked.
"""
import json
import os
import pathlib
import subprocess
import tempfile
import time

root = pathlib.Path(__file__).resolve().parents[1]
source = root / "../../luci/luci-app-warp/files/usr/libexec/rpcd/luci.warp"
ucode = os.environ.get("UCODE")
if not ucode:
    raise SystemExit("UCODE must point to an OpenWrt ucode interpreter")
args = [ucode]
if os.getenv("UCODE_MODULES"):
    args += ["-L", os.environ["UCODE_MODULES"]]

NETIFD = {
    "up": True,
    "pending": False,
    "available": True,
    "ipv4-address": [{"address": "192.0.2.1"}],
    "ipv6-address": [{"address": "2001:db8::1"}],
}

with tempfile.TemporaryDirectory(prefix="warp-rpc-test-") as temp:
    d = pathlib.Path(temp)
    (d / "etc/config").mkdir(parents=True)
    (d / "run/session-warp0").mkdir(parents=True)
    (d / "run/session-warp1").mkdir(parents=True)
    (d / "etc/warp-reg/accounts").mkdir(parents=True)
    (d / "bin").mkdir()
    (d / "etc/config/network").write_text(
        "config interface 'warp0'\n"
        "\toption proto 'warp'\n"
        "\toption tunlink 'wan'\n\n"
        "config interface 'warp1'\n"
        "\toption proto 'warp'\n\n"
        "config interface 'wan'\n"
        "\toption proto 'dhcp'\n"
    )
    (d / "etc/warp-reg/accounts/test.json").write_text(json.dumps({
        "device_id": "12345678-1234-1234-1234-123456789abc",
        "access_token": "secret-token-must-not-leak",
    }))
    (d / "run/session-warp0/session.json").write_text(json.dumps({
        "account_mode": "custom", "account": "test", "ipv4": "192.0.2.1",
        "ipv6": "2001:db8::1", "endpoint": "198.51.100.1:2408",
        "underlay_device": "pppoe-wan", "started_at": 1700000000,
        "private_key_file": "/secret/private.key", "access_token": "secret-token-must-not-leak",
    }))
    (d / "run/session-warp1/session.json").write_text(json.dumps({
        "account_mode": "fresh", "device_id_masked": "1234...9abc",
    }))
    now = int(time.time())
    (d / "run/session-warp0/health4").write_text(f"{now} 192.0.2.5\n")
    (d / "run/session-warp1/health4").write_text(f"{now - 300} 192.0.2.6\n")

    wg = d / "bin/wg"
    wg.write_text("""#!/bin/sh
case "$3" in
 latest-handshakes) echo 'peer 1700000200';;
 transfer) echo 'peer 1024 2048';;
 endpoints) echo 'peer 198.51.100.2:2408';;
 fwmark) echo 51820;;
esac
""")
    wg.chmod(0o755)
    ip = d / "bin/ip"
    ip.write_text("#!/bin/sh\necho '198.51.100.2 dev pppoe-wan table 51820'\n")
    ip.chmod(0o755)
    (d / "netifd.json").write_text(json.dumps(NETIFD))

    script = d / "luci.warp"
    text = source.read_text()
    text = text.replace("#!/usr/bin/ucode\n", "")
    text = text.replace("import { connect } from 'ubus';\n", "")
    text = text.replace(
        "let c=cursor(),b=connect();",
        "let c=cursor('" + str(d / "etc/config") + "','" + str(d / "run/.uci") + "',''),"
        "b={ call: function(path,method,payload) { return json(fs.readfile('"
        + str(d / "netifd.json") + "')); } };",
    )
    text = text.replace("/tmp/warp/", str(d / "run") + "/")
    text = text.replace("/etc/warp-reg/", str(d / "etc/warp-reg") + "/")
    text = text.replace("/usr/bin/wg ", str(wg) + " ")
    text = text.replace("'ip -4 route get '", "'" + str(ip) + " -4 route get '")
    text = text.replace(
        "try { main(); } catch(e) { print('{\"error\":\"status unavailable\"}\\n'); }",
        "main();",
    )
    script.write_text(text)

    env = dict(os.environ, PATH=str(d / "bin") + os.pathsep + os.environ.get("PATH", ""))

    def invoke(method, request=None):
        payload = (json.dumps(request) + "\n") if request is not None else ""
        p = subprocess.run(
            args + [str(script), "call", method], input=payload,
            text=True, capture_output=True, env=env, timeout=30,
        )
        assert p.returncode == 0, (method, p.returncode, p.stderr, p.stdout)
        return json.loads(p.stdout)

    status = invoke("status", {"interface": "warp0"})
    assert status["interface"] == "warp0" and status["state"] == "up"
    assert status["account_mode"] == "custom" and status["account_stored"] is True
    assert status["device_id_masked"] == "1234...9abc"
    assert status["ipv4"] == "192.0.2.1" and status["ipv6"] == "2001:db8::1"
    assert status["endpoint"] == "198.51.100.2:2408" and status["transport_device"] == "pppoe-wan"
    assert status["underlay_interface"] == "wan" and status["underlay_device"] == "pppoe-wan"
    assert status["latest_handshake"] == 1700000200
    assert status["rx_bytes"] == "1024" and status["tx_bytes"] == "2048"
    assert status["started_at"] == 1700000000

    all_status = invoke("status_all", {})
    assert [entry["interface"] for entry in all_status["interfaces"]] == ["warp0", "warp1"]
    assert all_status["interfaces"][0]["public_ipv4"] == "192.0.2.5"
    assert all_status["interfaces"][0]["internet_ipv4"] is True
    assert all_status["interfaces"][1]["account_mode"] == "fresh"
    assert all_status["interfaces"][1]["public_ipv4"] is None
    assert all_status["interfaces"][1]["internet_ipv4"] is False

    encoded = json.dumps(all_status)
    assert "secret-token" not in encoded and "private.key" not in encoded

    invalid = invoke("status", {"interface": "wan;reboot"})
    assert invalid["error"] == "invalid interface"
    assert invoke("status", {})["error"] == "invalid interface"

print("PASS: ucode RPC matches status fields, filters secrets and reports public IPs for every interface")
