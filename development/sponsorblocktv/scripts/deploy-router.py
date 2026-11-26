#!/usr/bin/env python3
"""Deploy verified build to the configured OpenWrt router; prune only after success."""
import argparse
import re
import shlex
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TARGET = "root@192.168.1.1"
SSH = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=8"]
SCP = ["scp", "-O", *SSH[1:]]
NAMES = ("sponsorblocktv", "luci-app-sponsorblocktv", "luci-i18n-sponsorblocktv-vi")

def run(args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)

def remote(command, capture=False):
    return run(SSH + [TARGET, command], capture_output=capture).stdout if capture else run(SSH + [TARGET, command])

def release(path):
    text = (ROOT / path).read_text(encoding="utf-8")
    return re.search(r"^PKG_RELEASE:=(\d+)$", text, re.M).group(1)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    directory = args.directory.resolve()
    core = release("../../utils/sponsorblocktv/Makefile")
    ui = release("../../luci/luci-app-sponsorblocktv/Makefile")
    vi = release("../../luci/luci-i18n-sponsorblocktv-vi/Makefile")
    tag = "24.10-r" + core
    if directory != ROOT / "dist" / "universal" / tag:
        raise SystemExit("Deploy requires the current canonical universal build directory")
    versions = ((ROOT / "../../utils/sponsorblocktv/VERSION").read_text().strip() + "-r" + core, "0.1.0-r"+ui, "0.1.0-r"+vi)
    files = [directory / (n+"_"+v+"_all.ipk") for n,v in zip(NAMES,versions)]
    if not all(p.is_file() and p.stat().st_size>0 for p in files):
        raise SystemExit("Incomplete current build; no install or cleanup")
    release_info = remote("cat /etc/openwrt_release", True)
    if "DISTRIB_RELEASE='24.10.4'" not in release_info or "DISTRIB_ARCH='x86_64'" not in release_info:
        raise SystemExit("Unexpected router OS/architecture")
    installed = remote("opkg list-installed", True)
    previous = ("sponsorblock", "luci-app-sponsorblock", "luci-i18n-sponsorblock-vi",
                "isponsorblocktv", "luci-app-isponsorblocktv", "luci-i18n-isponsorblocktv-vi")
    if any(line.split(" - ", 1)[0] in previous for line in installed.splitlines()):
        raise SystemExit("Conflicting controller package installed; uninstall it before installing SponsorBlockTV as a new package")
    running = remote("if /etc/init.d/sponsorblocktv running; then echo yes; else echo no; fi", True).strip()=="yes"
    stage = remote("mktemp -d /tmp/sponsorblocktv-deploy.XXXXXX", True).strip()
    if not re.fullmatch(r"/tmp/sponsorblocktv-deploy\.[A-Za-z0-9]+", stage):
        raise SystemExit("Unexpected staging directory")
    try:
        run(SCP + [str(p) for p in files] + [TARGET+":"+stage+"/"])
        remote("opkg install " + " ".join(shlex.quote(stage+"/"+p.name) for p in files))
        installed = remote("opkg list-installed", True)
        for n,v in zip(NAMES,versions):
            if n+" - "+v not in installed.splitlines():
                raise RuntimeError("Installed version mismatch: "+n)
        if running:
            remote("i=0; while [ $i -lt 15 ]; do if /etc/init.d/sponsorblocktv running && ubus list sponsorblocktv.live | grep -qx sponsorblocktv.live; then exit 0; fi; i=$((i+1)); sleep 1; done; exit 1")
        print("Verified installed: "+", ".join(n+" "+v for n,v in zip(NAMES,versions)), flush=True)
    finally:
        remote("rm -rf -- "+shlex.quote(stage))
    # Never touch source, backup, SDK or arbitrary directories. Keep only
    # exact current version IPKs; stale build dirs are removed after success.
    for variant in ("local", "universal"):
        parent = ROOT / "dist" / variant
        if not parent.is_dir():
            continue
        for child in parent.iterdir():
            if child.is_symlink() or not child.is_dir() or not re.fullmatch(r"24\.10-r\d+",child.name):
                continue
            if child.name != tag:
                shutil.rmtree(child)
                print("Removed old build:", child, flush=True)
            else:
                keep = {p.name for p in files}
                for p in child.glob("*.ipk"):
                    if p.name not in keep and p.name.startswith(tuple(n+"_" for n in NAMES)):
                        p.unlink()
                        print("Removed obsolete IPK:", p, flush=True)

if __name__ == "__main__":
    main()
