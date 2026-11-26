#!/usr/bin/env python3
"""Reject machine-specific binaries and bytecode in architecture-all payloads."""
import sys
from pathlib import Path

MAGICS = (b"\x7fELF", b"MZ", b"!<arch>\n", b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
          b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe")
SUFFIXES = {".so", ".dll", ".dylib", ".pyd", ".pyc", ".pyo", ".o", ".a", ".exe"}

def check(root):
    if not root.is_dir():
        raise SystemExit(f"Missing payload directory: {root}")
    for p in root.rglob("*"):
        if p.is_symlink():
            raise SystemExit(f"Unexpected symlink: {p}")
        if not p.is_file():
            continue
        with p.open("rb") as f:
            head = f.read(8)
        if p.suffix.lower() in SUFFIXES or ".so." in p.name or head.startswith(MAGICS):
            raise SystemExit(f"Non-portable payload: {p}")

if __name__ == "__main__":
    for arg in sys.argv[1:]:
        check(Path(arg))
