#!/usr/bin/env python3
"""Build the 24.10.4 ucode feed with the matching SDK's ipkg-build.
Usage: build-24-feed.py SDK OUTPUT [--ui-only] [--no-deploy]
"""

import os, re, shutil, subprocess, sys, tempfile
from pathlib import Path
from ipk_hooks import POSTINST, PRERM

repo = Path(__file__).resolve().parents[1]
sdk, output = (Path(arg).resolve() for arg in sys.argv[1:3])
output.mkdir(parents=True, exist_ok=True)
work = tempfile.TemporaryDirectory()
root = Path(work.name)


def package(name, version, depends, tree, arch="all"):
    control = tree / "CONTROL"
    control.mkdir(exist_ok=True)
    legacy = {"sponsorblocktv":"sponsorblock, isponsorblocktv","luci-app-sponsorblocktv":"luci-app-sponsorblock, luci-app-isponsorblocktv","luci-i18n-sponsorblocktv-vi":"luci-i18n-sponsorblock-vi, luci-i18n-isponsorblocktv-vi"}[name]
    (control / "control").write_text(
        f"Package: {name}\nVersion: {version}\nArchitecture: {arch}\nConflicts: {legacy}\nDepends: {depends}\nInstalled-Size: {sum(p.stat().st_size for p in tree.rglob(chr(42)) if p.is_file() and control not in p.parents)}\nMaintainer: Khải Phan\nLicense: GPL-3.0-or-later\nDescription: {name} for OpenWrt 24.10 (ucode); Author (OpenWrt edition): Khải Phan\n"
        , encoding="utf-8"
    )
    subprocess.run([sys.executable, repo / "../../utils/sponsorblocktv/check-portable-payload.py", tree], check=True)
    subprocess.run(
        [sdk / "scripts/ipkg-build", tree, output],
        check=True,
        env={**os.environ, "TAR_OPTIONS": "--owner=0 --group=0"},
    )


def copy(src, dst, mode=0o644):
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dst)
    dst.chmod(mode)


ui = repo / "../../luci/luci-app-sponsorblocktv"
tree = root / "ui"
for directory, prefix in [("root", ""), ("htdocs", "www")]:
    for src in (ui / directory).rglob("*"):
        if src.is_file():
            dst = tree / prefix / src.relative_to(ui / directory)
            copy(src, dst, 0o755 if "sbin" in dst.parts else 0o644)
control = tree / "CONTROL"
control.mkdir()
postinst = control / "postinst"
postinst.write_text("#!/bin/sh\n[ -n \"$IPKG_INSTROOT\" ] && exit 0\n"
                    "rm -f /tmp/luci-indexcache.*\n/etc/init.d/rpcd reload\n")
postinst.chmod(0o755)
package("luci-app-sponsorblocktv", "0.1.0-r1", "luci-base, sponsorblocktv (>= 0.1.0-r1), flock", tree)
vi_tree = root / "vi"
vi_rel = "luci-static/resources/sponsorblocktv/i18n/vi.json"
copy(ui.parent / "luci-i18n-sponsorblocktv-vi/htdocs" / vi_rel, vi_tree / "www" / vi_rel)
package("luci-i18n-sponsorblocktv-vi", "0.1.0-r1", "luci-app-sponsorblocktv (>= 0.1.0-r1)", vi_tree)
def deploy_current():
    # Only canonical release builds auto-deploy; SDK experiments remain local.
    match = re.fullmatch(r"24\.10-r\d+", output.name)
    if "--no-deploy" in sys.argv or not match or output.parent != repo / "dist/universal":
        return
    script = repo / "scripts/deploy-router.py"
    if "microsoft" in os.uname().release.lower() and shutil.which("python.exe"):
        win = lambda path: subprocess.check_output(["wslpath", "-w", str(path)], text=True).strip()
        subprocess.run(["python.exe", win(script), win(output)], check=True)
    else:
        subprocess.run([sys.executable, script, output], check=True)

if "--ui-only" in sys.argv:
    deploy_current()
    sys.exit(0)

# --- app package (native ucode runtime) ------------------------------------
tree = root / "app"
files = repo / "../../utils/sponsorblocktv/files"
ucode = files / "ucode"
for src in files.iterdir():
    if not src.is_file():
        continue
    mapping = {
        "sponsorblocktv.config": "etc/config/sponsorblocktv",
        "sponsorblocktv.init": "etc/init.d/sponsorblocktv",
        "sponsorblocktv-categories.json": "usr/share/sponsorblocktv/categories.json",
    }
    dst = mapping.get(src.name, "usr/sbin/" + src.name)
    copy(src, tree / dst, 0o755 if dst.startswith(("etc/init", "usr/sbin")) else 0o644)
# CLI entry points.
for name in ("sponsorblocktv-run", "sponsorblocktv-write-config",
             "sponsorblocktv-policy", "sponsorblocktv-pair", "sponsorblocktv-discover", "sponsorblocktv-cast-bridge", "sponsorblocktv-watch-page"):
    copy(ucode / name, tree / "usr/sbin" / name, 0o755)
# ucode lib/ tree.
for lib in sorted((ucode / "lib").rglob("*")):
    if lib.is_file():
        rel = lib.relative_to(ucode / "lib")
        copy(lib, tree / "usr/lib/sponsorblocktv" / rel)
for lib in sorted((files / "python").rglob("*")):
    if lib.is_file() and "__pycache__" not in lib.parts and lib.suffix not in (".pyc", ".pyo"):
        copy(lib, tree / "usr/lib/sponsorblocktv/python" / lib.relative_to(files / "python"))
(tree / "CONTROL").mkdir()
for hook, content in [("postinst", POSTINST), ("prerm", PRERM)]:
    script = tree / "CONTROL" / hook
    script.write_text(content)
    script.chmod(0o755)
(tree / "etc/config/sponsorblocktv").chmod(0o600)
(tree / "CONTROL/conffiles").write_text("/etc/config/sponsorblocktv\n")
deps = "ucode, ucode-mod-uloop, ucode-mod-uclient, ucode-mod-socket, ucode-mod-struct, ucode-mod-digest, ucode-mod-fs, ucode-mod-ubus, ca-bundle, python3, python3-zeroconf, python3-requests, python3-urllib3, python3-certifi, python3-idna, python3-chardet"
package("sponsorblocktv", "0.1.0-r1", deps, tree)

# Deploy and prune only after all requested packages were built.
deploy_current()
