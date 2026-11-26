"""Test helpers for the ucode-based SponsorBlockTV package.

The runtime is implemented in ucode (no Python). Tests validate the shipped
ucode sources structurally (shebang, exports, module layout) and, when a
`ucode` interpreter is available on PATH, execute the pure-logic modules
(config parsing, segment processing) directly.
"""

from __future__ import annotations

import os
import pathlib
import shutil
import subprocess
import sys
from typing import Optional

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
PACKAGE_FILES = REPO_ROOT / "../../utils/sponsorblocktv" / "files"
UCODE_DIR = PACKAGE_FILES / "ucode"
LIB_DIR = UCODE_DIR / "lib"
LUCI_DIR = REPO_ROOT / "../../luci/luci-app-sponsorblocktv"

# ucode modules shipped in lib/ (excluding the cast/ subdir, listed separately).
LIB_MODULES = [
    "util.uc",
    "config.uc",
    "http.uc",
    "sponsorblock.uc",
    "lounge.uc",
    "dial.uc",
    "mdns.uc",
    "discovery.uc",
    "runtime.uc",
    "pair_store.uc",
]

CAST_MODULES = [
    "client.uc",
]

# CLI entry points shipped in ucode/.
CLI_SCRIPTS = [
    "sponsorblocktv-run",
    "sponsorblocktv-write-config",
    "sponsorblocktv-pair",
    "sponsorblocktv-discover",
    "sponsorblocktv-cast-bridge",
    "sponsorblocktv-watch-page",
]


# WSL ucode bridge: the ucode interpreter lives inside WSL at
# /home/khaiphan/.local/bin/ucode with LD_LIBRARY_PATH=/home/khaiphan/.local/lib.
# When no native `ucode` is on PATH, we invoke it through `wsl`.
WSL_UCODE = "/home/khaiphan/.local/bin/ucode"
WSL_LD_LIBRARY_PATH = "/home/khaiphan/.local/lib"


def _wsl_available() -> bool:
    return shutil.which("wsl") is not None


def _wsl_ucode_available() -> bool:
    """Return True if the WSL ucode interpreter is reachable."""
    if not _wsl_available():
        return False
    try:
        result = subprocess.run(
            ["wsl", "-d", "Ubuntu-26.04", "-e", "bash", "-lc",
             f"export LD_LIBRARY_PATH={WSL_LD_LIBRARY_PATH}; test -x {WSL_UCODE} && echo OK"],
            capture_output=True, text=True, timeout=30,
        )
        return result.returncode == 0 and "OK" in result.stdout
    except Exception:
        return False


def ucode_binary() -> Optional[str]:
    """Return a ucode interpreter path, or None if unavailable.

    Prefers a native `ucode` on PATH; falls back to the WSL ucode.
    """
    native = shutil.which("ucode")
    if native:
        return native
    if _wsl_ucode_available():
        return "wsl-ucode"  # sentinel handled by run_ucode/run_ucode_expr
    return None


def _win_to_wsl(path: str) -> str:
    """Convert a Windows path like C:\\foo\\bar to a WSL /mnt/c/foo/bar path."""
    path = path.replace("\\", "/")
    if len(path) >= 2 and path[1] == ":":
        drive = path[0].lower()
        return "/mnt/" + drive + path[2:]
    return path


def _run_wsl_ucode(args: list[str], env: Optional[dict] = None) -> subprocess.CompletedProcess:
    """Run ucode inside WSL, converting Windows paths to WSL paths.

    The UCODE_PATH is exported inside the WSL command itself, so we do NOT pass
    a stripped-down `env` to subprocess (that would drop PATH/SYSTEMROOT and
    break WSL). The caller's `env` is only consulted for UCODE_PATH.
    """
    wsl_args = [a if not os.path.isabs(a) or not os.path.exists(a) else _win_to_wsl(a)
                for a in args]
    cmd = ["wsl", "-d", "Ubuntu-26.04", "--exec", "env",
           f"LD_LIBRARY_PATH={WSL_LD_LIBRARY_PATH}"]
    if env and env.get("UCODE_PATH"):
        cmd.append(f"UCODE_PATH={_win_to_wsl(env['UCODE_PATH'])}")
    cmd.extend([WSL_UCODE, *wsl_args])
    return subprocess.run(cmd, capture_output=True, text=True, timeout=60)


def run_ucode(script: pathlib.Path, args: Optional[list[str]] = None) -> subprocess.CompletedProcess:
    """Run a ucode script with the lib/ dir on the module path."""
    ucode = ucode_binary()
    if not ucode:
        raise RuntimeError("ucode interpreter not available on PATH")
    if ucode == "wsl-ucode":
        return _run_wsl_ucode([str(script)] + (args or []))
    cmd = [ucode, str(script)] + (args or [])
    env = {**os.environ, "UCODE_PATH": str(LIB_DIR)}
    return subprocess.run(cmd, capture_output=True, text=True, env=env)


def run_ucode_expr(expr: str) -> subprocess.CompletedProcess:
    """Run a ucode expression with the lib/ dir on the module path.

    ucode's -e flag evaluates a single expression; to allow import statements
    we wrap the expression in a temporary script and run it. The temp script is
    placed inside LIB_DIR so that bare imports like `import * as c from
    'config.uc'` resolve relative to the module directory.

    ucode resolves bare module names through its search path, which rewrites
    dots to slashes (so `config.uc` becomes `config/uc`). To import a sibling
    `.uc` module reliably we rewrite bare imports to relative imports
    (`./config.uc`), which ucode resolves against the importing file's
    directory.
    """
    ucode = ucode_binary()
    if not ucode:
        raise RuntimeError("ucode interpreter not available on PATH")
    import re
    expr = re.sub(r"from\s+'([A-Za-z0-9_]+\.uc)'", r"from './\1'", expr)
    import tempfile
    fd, path = tempfile.mkstemp(suffix=".uc", dir=str(LIB_DIR), text=True)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(expr + "\n")
    env = {**os.environ, "UCODE_PATH": str(LIB_DIR)}
    try:
        if ucode == "wsl-ucode":
            return _run_wsl_ucode([path], env=env)
        return subprocess.run([ucode, path], capture_output=True, text=True, env=env)
    finally:
        os.unlink(path)


def read_ucode_module(name: str) -> str:
    """Read a lib module's source text."""
    return (LIB_DIR / name).read_text(encoding="utf-8")


def read_cli_script(name: str) -> str:
    """Read a CLI script's source text."""
    return (UCODE_DIR / name).read_text(encoding="utf-8")
