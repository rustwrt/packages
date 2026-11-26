#!/usr/bin/env python3
"""Exercise the loopback relay without disabling TLS or APK trust checks."""
import hashlib
import http.server
import importlib.util
import pathlib
import threading
import urllib.error
import urllib.request

root = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("mirror", root / "tools/apk-test-mirror.py")
mirror = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mirror)
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), mirror.Mirror)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
local = f"http://127.0.0.1:{server.server_port}"
path = "/releases/25.12.6/packages/x86_64/base/packages.adb"
try:
    for bad in ("/", "/releases/24.10.8/packages.adb",
                "/releases/25.12.6/../packages.adb",
                "/releases/25.12.6/%2e%2e/packages.adb",
                "/releases/25.12.6/packages.adb?secret=1",
                "/releases/25.12.6/%2fpackages.adb"):
        try:
            urllib.request.urlopen(local + bad, timeout=10).close()
            raise AssertionError(f"Accepted invalid path: {bad}")
        except urllib.error.HTTPError as exc:
            assert exc.code == 404, (bad, exc.code)
    with urllib.request.urlopen(mirror.HOST + path, timeout=90) as ref:
        original = ref.read()
    with urllib.request.urlopen(local + path, timeout=100) as relayed:
        data = relayed.read()
    assert original and data == original, "Index changed or relay corrupted bytes"
    print("PASS: official APK index relayed unchanged via verified host TLS")
    print("SHA256:", hashlib.sha256(data).hexdigest())
    print("PASS: rejected invalid, cross-release and encoded traversal paths")
finally:
    server.shutdown()
    server.server_close()
