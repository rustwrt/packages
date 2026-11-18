# NetBraid VM and package test results — 2026-11-18

## Environment

- Host: WSL `Ubuntu-26.04`, project at `/mnt/d/REPO/RustWRT/rustwrt/netbraid`.
- 25.12.6 SDK: `/home/khaiphan/warp-ucode-25.12.6/sdk` (APKi; kernel 6.12.112).
- 24.10.8 SDK used for IPK: clean extraction at `/home/khaiphan/netbraid-sdk-24.10.8` from
  `/home/khaiphan/openwrt-sdk-24.10.8-x86-64_gcc-13.3.0_musl.Linux-x86_64.tar.zst`.
  The pre-existing `/home/khaiphan/openwrt-sdk-24.10.8-...` was incomplete (`include/package.mk` was 0 bytes, no feeds) and was left untouched.
- QEMU image: `/home/khaiphan/warp-vm-test/openwrt.img`, running OpenWrt **24.10.4** (not 25.12.6).
  The 25.12.6 VM described in the directive (`/root/warp25-ucode/serial.sock`, ports 25187/25188/25189) did not exist in this session.
- No host firewall, routing, nftables or network configuration was changed.

## LuCI SDK Makefile repair

The SDK source Makefile at
`/home/khaiphan/warp-ucode-25.12.6/sdk/feeds/luci/applications/luci-app-netbraid/Makefile`
contained the PowerShell-corrupted line `include /feeds/luci/luci.mk`.

Fix performed with `cp` (no dollar-sign make syntax in PowerShell):

```bash
cp /mnt/d/REPO/RustWRT/rustwrt/netbraid/luci-app-netbraid/Makefile \
   /home/khaiphan/warp-ucode-25.12.6/sdk/feeds/luci/applications/luci-app-netbraid/Makefile
```

The canonical project Makefile now contains:

```make
include $(TOPDIR)/rules.mk
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
LUCI_TITLE:=LuCI support for NetBraid
LUCI_DEPENDS:=+luci-base +netbraid
PKG_LICENSE:=GPL-2.0-or-later
include $(TOPDIR)/feeds/luci/luci.mk
# call BuildPackage - OpenWrt buildroot signature
```

The final `# call BuildPackage - ...` marker is required by OpenWrt's `include/scan.mk` feed scanner.
After adding it and clearing `feeds/luci.tmp/info/.files-packageinfo-*`, the package registered as:

```text
Package: luci-app-netbraid
Version: 0.1.0-r1
Depends: +libc +luci-base +netbraid
```

Actual SDK target used: `package/feeds/luci/luci-app-netbraid/compile` (not
`package/feeds/luci/applications/luci-app-netbraid/compile`).

## Tests

`tests/compile-all.sh` was rerun repeatedly and passed fully after each fix. Final result:
all 14 modules compile, all 6 test scripts compile, and all 6 runtime suites pass
(`run`, `detector`, `detection-collector`, `portal`, `routing`, `transaction`).
No detector IPv6-neighbor bug was present in this checkout: `detector-test.uc` already asserted
`00:11:22:33:44:55`, and the test passed as-is.

## Runtime bugs found on VM and fixed

The backend IPK was installed in the 24.10.4 QEMU VM and exercised. Several real ucode runtime defects were found and fixed in project sources:

1. `runtime.uc`: `lastIndexOf(statusPath, '/')` is not available in ucode → replaced with
   a `split`/`substr`-based directory derivation; added `fs.mkdir()` for `/var/run/netbraid`.
2. `runtime.uc`: `replace(key, /.../g, callback)` is unsupported in ucode → replaced
   `toWire` key conversion with explicit `snakeKey`/`camelKey` character loops (preserving
   the snake_case JSON wire contract).
3. `daemon.uc`: `uloop.cancel()` does not exist → use `timer.cancel()`, and declare
   `let timer = null` before the signal handler so it is in scope.
4. `detection.uc`: `sample()` dereferenced `collector.state` when null → create a detector
   state via `createDetector(detectorConfig)` when absent.
5. Backend `Makefile`: rpcd ucode scripts are loaded from `/usr/share/rpcd/ucode/`, not
   `/usr/libexec/rpcd/` → install `netbraid.uc` to the correct directory.

After these fixes, in the VM:

- `/etc/init.d/netbraid start` produced `/var/run/netbraid/status.json` with
  `"config_valid": true`, real interface discovery (lan/loopback/wan) and snake_case JSON keys.
- `ubus list` showed `luci.netbraid`; `ubus -v list luci.netbraid` exposed
  `status, interfaces, detection, portal, diagnostics, validate`.
- `ubus call luci.netbraid status` returned a valid JSON object.
- `ubus call session login` showed ACL grants including
  `"luci-app-netbraid": ["read","write"]` and
  `"luci.netbraid": ["status","interfaces","detection","portal","diagnostics","validate"]`.
- LuCI menu file `/usr/share/luci/menu.d/luci-app-netbraid.json` was installed with the
  verified route `admin/network/netbraid` (not `admin/services/netbraid`).
- IPK install with `opkg` succeeded for `netbraid`, `luci-app-netbraid` and
  `luci-i18n-netbraid-vi`; SHA256 hashes matched the host artifacts.
- Routing table and nftables ruleset were captured before/after and were unchanged by
  installation; activation remained blocked by design.

## Artifacts

All four required artifacts exist in `artifacts/`:

| Artifact | Size | SHA256 |
|---|---:|---|
| `netbraid-0.1.0-r1.apk` | 28644 | `0e97359b7ee83a1e7a321225431b9d1b5c62afd3d7ee82432aad2f8e5d5584f6` |
| `luci-app-netbraid-0.1.0-r1.apk` | 7538 | `bf22841d36e5ce4cd2f089224f5b5a9bfb48e82e1095602e99cbf1465b65535a` |
| `netbraid_0.1.0-r1_x86_64.ipk` | 27944 | `a430eed3bf48b5e84a17427a1e3c935ae2f634bea3fdd551b042ac35502f4127` |
| `luci-app-netbraid_0.1.0-r1_all.ipk` | 7429 | `329707ceb34ec5d351cf9a94927ff2d84692d6512ef0d717064df690f2e3b987` |

Additional Vietnamese i18n packages were also built:
`luci-i18n-netbraid-vi-0.1.0-r1.apk` / `luci-i18n-netbraid-vi_0_all.ipk`.

IPK control metadata was verified with `tar`:

```text
Package: netbraid
Version: 0.1.0-r1
Depends: libc, ucode, ucode-mod-fs, ucode-mod-math, ucode-mod-uci, ucode-mod-ubus, ucode-mod-uloop, rpcd-mod-ucode
Architecture: x86_64

Package: luci-app-netbraid
Version: 0.1.0-r1
Depends: libc, luci-base, netbraid
Architecture: all
```

## Remaining blockers (truthful)

- The existing QEMU VM is OpenWrt **24.10.4**, so only the IPK format was valid for installation there.
  The four artifacts are built, but the APK installation test on a 25.12.6 VM could not be
  performed because that VM/image was absent.
- Full browser acceptance in Cốc Cốc was not completed: the VM's LuCI CGI login flow returned
  `403 x-luci-login-required` from the CLI, and the VM network/port-forward later became
  unreachable (port 2223 forwarded to WSL Ubuntu instead of the guest after QEMU restart).
  The LuCI page route, menu JSON, ubus API and ACL were verified on the VM over SSH before
  that point, but an authenticated HTTP page fetch and browser open were not achieved.
- The directive's browser URL `admin/services/netbraid` is incorrect for this package;
  the verified route is `admin/network/netbraid`.
- APKi metadata extraction from the `.apk` control section was not inspected in detail;
  the SDK build log showed correct package names/versions/dependencies.
