#!/usr/bin/env python3
"""Check that both README dependency tables match actual packaging metadata."""
import importlib.util
from pathlib import Path

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("apk_builder", root / "tools/build-test-apk.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)
for name in builder.NAMES:
    _, version, deps, _ = builder.definition(name)
    assert version == "0.3.0-r2"
    for file in ("README.md", "README_VI.md"):
        lines = (root / file).read_text(encoding="utf-8").splitlines()
        row = next(line for line in lines if line.startswith("| " + name + " |") and "\x60" in line)
        actual = {v for v in row.split("\x60")[1::2]}
        assert actual == {d for d in deps if not d.startswith("!")}, (name, file)
assert set(builder.definition("cloudflare-warp")[2]) >= {"!warp-proto", "!warp-reg-lua"}
print("PASS: documented direct dependencies, APK metadata and legacy conflicts match Makefiles")
