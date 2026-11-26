#!/usr/bin/env python3
"""Native APK v3 smoke packages; official release builds use tools/build-sdk.sh."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
NAMES = ("warp", "luci-app-warp", "luci-i18n-warp-vi")
EXEC = {
    "etc/uci-defaults/90-warp-ipv6",
    "etc/hotplug.d/iface/90-warp-health",
    "lib/netifd/proto/warp.sh",
    "usr/libexec/warp-health",
    "usr/sbin/warp-reg",
    "usr/libexec/rpcd/luci.warp",
}

def run(*args):
    subprocess.run([str(x) for x in args], check=True)

def definition(name):
    package = ROOT / ("net" if name == "warp" else "luci") / name
    text = (package / "Makefile").read_text()
    block = re.search(r"^define Package/" + re.escape(name) + r"\n(.*?)^endef$", text, re.M | re.S)[1]
    field = lambda key: re.search(r"^\s*" + key + r":=(.*)$", block, re.M)[1].strip()
    deps = [d.removeprefix("+") for d in field("DEPENDS").split()]
    if any(not re.fullmatch(r"[\w.-]+", d) for d in deps):
        raise ValueError("Unsupported dependency expression")
    if name == "warp":
        deps.extend("!" + d for d in field("CONFLICTS").split())
    v = re.search(r"^PKG_VERSION:=(.+)$", text, re.M)[1]
    r = re.search(r"^PKG_RELEASE:=(\d+)$", text, re.M)[1]
    return package, v + "-r" + r, deps, field("TITLE")

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--apk", type=Path, required=True, help="Verified OpenWrt 25.12 SDK host apk")
    p.add_argument("--po2lmo", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--sign-key", type=Path, required=True, help="Use a temporary test key")
    args = p.parse_args()
    if os.geteuid() != 0:
        raise SystemExit("Run inside a disposable root/fakeroot build environment for file ownership")
    args.out.mkdir(parents=True, exist_ok=False)
    for name in NAMES:
        package, version, deps, title = definition(name)
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            stage = tmp / "data"
            stage.mkdir()
            if name != "luci-i18n-warp-vi":
                for src in sorted((package / "files").rglob("*")):
                    if src.is_symlink():
                        raise ValueError("Unexpected symlink")
                    if src.is_file():
                        rel = src.relative_to(package / "files")
                        dest = stage / rel
                        dest.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copyfile(src, dest)
                        dest.chmod(0o755 if rel.as_posix() in EXEC else 0o644)
            else:
                lmo = stage / "usr/lib/lua/luci/i18n/warp.vi.lmo"
                lmo.parent.mkdir(parents=True)
                run(args.po2lmo, package / "po/vi/warp.po", lmo)
                if not lmo.stat().st_size:
                    raise ValueError("Empty translation")
            # OpenWrt native APK package integration, as in include/package-pack.mk.
            payload = sorted("/" + f.relative_to(stage).as_posix() for f in stage.rglob("*") if f.is_file())
            metadata = stage / "lib/apk/packages"
            metadata.mkdir(parents=True)
            (metadata / (name + ".list")).write_text("\n".join(payload) + "\n")
            common = '[ -s "$IPKG_INSTROOT/lib/functions.sh" ] || exit 0\n. "$IPKG_INSTROOT/lib/functions.sh"\nexport root="$IPKG_INSTROOT"\nexport pkgname="' + name + '"\n'
            post = '[ "$IPKG_NO_SCRIPT" = 1 ] && exit 0\n' + common + 'add_group_and_user\ndefault_postinst\n'
            scripts = {
                "post-install": post,
                "post-upgrade": "export PKG_UPGRADE=1\n" + post,
                "pre-deinstall": common + "default_prerm\n",
            }
            opts = []
            for kind, body in scripts.items():
                path = tmp / kind
                path.write_text("#!/bin/sh\n" + body)
                opts.extend(["--script", kind + ":" + str(path)])
            dest = args.out / (name + "-" + version + ".apk")
            run(args.apk, "mkpkg", "--info", "name:" + name,
                "--info", "version:" + version, "--info", "arch:noarch",
                "--info", "license:MIT", "--info", "description:" + title,
                "--info", "url:https://github.com/rustwrt/luci-app-warp",
                "--info", "depends:" + ",".join(deps),
                "--files", stage, "--sign", args.sign_key, *opts, "--output", dest)
            print("Built experimental native APK:", dest.name, flush=True)

if __name__ == "__main__":
    main()
