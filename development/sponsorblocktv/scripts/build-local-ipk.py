#!/usr/bin/env python3
"""Build local, structurally valid OpenWrt 24.10 x86_64 IPK validation packages.

This is NOT a cross-compiler replacement. It packages the already-written
integration files (UCI config, procd init, helpers, LuCI view/menu/ACL) into the
same ar/tar layout that opkg consumes, using only the Python standard library.
It exists so the *packaging and install flow* can be validated on a compatible
host when no SDK/VM is available; production packages must still be built with
the real OpenWrt SDK (see scripts/build-openwrt.sh).
"""

from __future__ import annotations

import argparse
import io
import os
import pathlib
import tarfile
import time
from ipk_hooks import POSTINST, PRERM

REPO = pathlib.Path(__file__).resolve().parent.parent
APP_FILES = REPO / "../../utils/sponsorblocktv" / "files"
LUCI = REPO / "../../luci/luci-app-sponsorblocktv"

VERSION = (REPO / "../../utils/sponsorblocktv/VERSION").read_text(encoding="utf-8").strip()
RELEASE = "r1"
LUCI_RELEASE = "r1"
EPOCH = int(os.environ.get("SOURCE_DATE_EPOCH", time.time()))


def add_file(tar, archive_name, source, mode=0o644):
    if isinstance(source, (bytes, bytearray)):
        data = bytes(source)
    else:
        data = pathlib.Path(source).read_bytes()
    info = tarfile.TarInfo(archive_name)
    info.size = len(data)
    info.mode = mode
    info.mtime = EPOCH
    info.uid = info.gid = 0
    info.uname = info.gname = "root"
    tar.addfile(info, io.BytesIO(data))


def add_dirs(tar, paths):
    for path in sorted(set(paths)):
        info = tarfile.TarInfo(path.rstrip("/") + "/")
        info.type = tarfile.DIRTYPE
        info.mode = 0o755
        info.mtime = EPOCH
        info.uid = info.gid = 0
        info.uname = info.gname = "root"
        tar.addfile(info)


def make_tgz(entries, dirs=()):
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode="w:gz") as tar:
        add_dirs(tar, dirs)
        for name, source, mode in entries:
            add_file(tar, name, source, mode)
    return out.getvalue()


def write_ipk(path, control, data, postinst=None, prerm=None, conffiles=None):
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        control += f"Installed-Size: {sum(m.size for m in archive.getmembers() if m.isfile())}\n"
    control_entries = [("./control", control.encode(), 0o644)]
    if postinst:
        control_entries.append(("./postinst", postinst.encode(), 0o755))
    if prerm:
        control_entries.append(("./prerm", prerm.encode(), 0o755))
    if conffiles:
        control_entries.append(("./conffiles", conffiles.encode(), 0o644))
    control_tgz = make_tgz(control_entries)
    data_tgz = data

    with tarfile.open(path, "w:gz") as tar:
        for name, blob in (("debian-binary", b"2.0\n"),
                           ("control.tar.gz", control_tgz),
                           ("data.tar.gz", data_tgz)):
            info = tarfile.TarInfo("./" + name)
            info.size = len(blob)
            info.mtime = EPOCH
            info.mode = 0o644
            tar.addfile(info, io.BytesIO(blob))
    return path


def app_ipk(out):
    import subprocess, sys
    subprocess.run([sys.executable, REPO / "../../utils/sponsorblocktv/check-portable-payload.py", APP_FILES / "python", APP_FILES / "ucode/lib"], check=True)
    ucode = APP_FILES / "ucode"
    entries = [
        ("./etc/config/sponsorblocktv", APP_FILES / "sponsorblocktv.config", 0o600),
        ("./etc/init.d/sponsorblocktv", APP_FILES / "sponsorblocktv.init", 0o755),
        ("./usr/sbin/sponsorblocktv-merge-config", APP_FILES / "sponsorblocktv-merge-config", 0o755),
        ("./usr/sbin/sponsorblocktv-run", ucode / "sponsorblocktv-run", 0o755),
        ("./usr/sbin/sponsorblocktv-write-config", ucode / "sponsorblocktv-write-config", 0o755),
        ("./usr/sbin/sponsorblocktv-policy", ucode / "sponsorblocktv-policy", 0o755),
        ("./usr/sbin/sponsorblocktv-pair", ucode / "sponsorblocktv-pair", 0o755),
        ("./usr/sbin/sponsorblocktv-discover", ucode / "sponsorblocktv-discover", 0o755),
        ("./usr/sbin/sponsorblocktv-cast-bridge", ucode / "sponsorblocktv-cast-bridge", 0o755),
        ("./usr/sbin/sponsorblocktv-watch-page", ucode / "sponsorblocktv-watch-page", 0o755),
        ("./usr/share/sponsorblocktv/categories.json", APP_FILES / "sponsorblocktv-categories.json", 0o644),
    ]
    # Ship the ucode lib/ tree under /usr/lib/sponsorblocktv/.
    for lib in sorted((ucode / "lib").rglob("*")):
        if lib.is_file():
            rel = lib.relative_to(ucode / "lib")
            entries.append((f"./usr/lib/sponsorblocktv/{rel.as_posix()}", lib, 0o644))
    for lib in sorted((APP_FILES / "python").rglob("*")):
        if lib.is_file() and "__pycache__" not in lib.parts and lib.suffix not in (".pyc", ".pyo"):
            rel = lib.relative_to(APP_FILES / "python")
            entries.append((f"./usr/lib/sponsorblocktv/python/{rel.as_posix()}", lib, 0o644))
    dirs = ["./etc", "./etc/config", "./etc/init.d", "./usr", "./usr/sbin",
            "./usr/lib", "./usr/lib/sponsorblocktv", "./usr/lib/sponsorblocktv/cast",
            "./usr/share", "./usr/share/sponsorblocktv"]
    control = "\n".join([
        "Package: sponsorblocktv",
        "Conflicts: sponsorblock, isponsorblocktv",
        f"Version: {VERSION}-{RELEASE}",
        "Depends: libc, ucode, ucode-mod-uloop, ucode-mod-uclient, ucode-mod-socket, ucode-mod-struct, ucode-mod-digest, ucode-mod-fs, ucode-mod-ubus, ca-bundle, python3, python3-zeroconf, python3-requests, python3-urllib3, python3-certifi, python3-idna, python3-chardet",
        "Source: sponsorblocktv",
        "SourceName: sponsorblocktv",
        "License: GPL-3.0-or-later",
        "Section: utils",
        "Architecture: all",
        f"SourceDateEpoch: {EPOCH}",
        "URL: https://github.com/rustwrt/packages",
        "Maintainer: Khải Phan",
        "Description: SponsorBlockTV client for YouTube TV clients; Author (OpenWrt edition): Khải Phan",
        "",
    ])
    return write_ipk(out / f"sponsorblocktv_{VERSION}-{RELEASE}_all.ipk",
                     control, make_tgz(entries, dirs), POSTINST, PRERM, "/etc/config/sponsorblocktv\n")


def luci_ipk(out):
    entries = []
    dirs = set()
    for directory, prefix in [("root", ""), ("htdocs", "www")]:
        for src in (LUCI / directory).rglob("*"):
            if not src.is_file():
                continue
            dst = pathlib.PurePosixPath(prefix) / src.relative_to(LUCI / directory).as_posix()
            entries.append(("./"+dst.as_posix(),src,0o755 if "sbin" in dst.parts else 0o644))
            dirs.update("./"+p.as_posix() for p in dst.parents if str(p)!=".")
    control = "\n".join([
        "Package: luci-app-sponsorblocktv",
        "Conflicts: luci-app-sponsorblock, luci-app-isponsorblocktv",
        f"Version: 0.1.0-{LUCI_RELEASE}",
        "Depends: libc, luci-base, sponsorblocktv (>= 0.1.0-r1), flock",
        "Source: sponsorblocktv",
        "SourceName: luci-app-sponsorblocktv",
        "License: GPL-3.0-or-later",
        "Section: luci",
        "Architecture: all",
        f"SourceDateEpoch: {EPOCH}",
        "Maintainer: Khải Phan",
        "Description: LuCI support for SponsorBlockTV; Author (OpenWrt edition): Khải Phan",
        "",
    ])
    postinst = ("#!/bin/sh\n[ -n \"${IPKG_INSTROOT}\" ] || {\n"
                "\trm -f /tmp/luci-indexcache.*\n"
                "\trm -rf /tmp/luci-modulecache/\n"
                "\t/etc/init.d/rpcd reload 2>/dev/null\n}\nexit 0\n")
    return write_ipk(out / f"luci-app-sponsorblocktv_0.1.0-{LUCI_RELEASE}_all.ipk",
                     control, make_tgz(entries, dirs), postinst)


def vietnamese_ipk(out):
    rel = "www/luci-static/resources/sponsorblocktv/i18n/vi.json"
    src = LUCI.parent / "luci-i18n-sponsorblocktv-vi/htdocs" / rel.removeprefix("www/")
    control = "\n".join([
        "Package: luci-i18n-sponsorblocktv-vi",
        "Conflicts: luci-i18n-sponsorblock-vi, luci-i18n-isponsorblocktv-vi",
        f"Version: 0.1.0-{LUCI_RELEASE}",
        "Depends: luci-app-sponsorblocktv (>= 0.1.0-r1)",
        "Architecture: all",
        "Section: luci",
        "Maintainer: Khải Phan",
        "License: GPL-3.0-or-later",
        "Description: Vietnamese language for SponsorBlockTV only",
        "",
    ])
    dirs = {"./"+p.as_posix() for p in pathlib.PurePosixPath(rel).parents if str(p)!="."}
    return write_ipk(out / f"luci-i18n-sponsorblocktv-vi_0.1.0-{LUCI_RELEASE}_all.ipk",
                     control, make_tgz([("./"+rel,src,0o644)],dirs))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out", help="output directory")
    args = parser.parse_args()
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    for fn in (app_ipk, luci_ipk, vietnamese_ipk):
        path = fn(out)
        print(path.name, path.stat().st_size)


if __name__ == "__main__":
    main()
