# NetBraid implementation progress

## Session continuation — 2026-11-18 UTC

This session continued the implementation in `D:\REPO\RustWRT\rustwrt\netbraid` after the prior Kilo session stopped with an upstream proxy error. The original `D:\REPO\RustWRT\rustwrt\routebraid` tree and unrelated repositories were not deleted or overwritten. No router, firewall, nftables, iproute2 or conntrack state was modified.

### Compiler error diagnosis

The reported allocator error was reproduced with the OpenWrt 25.12.6 SDK ucode compiler:

```text
Syntax error: Exports may only appear at top level of a module
In .../netbraid/files/usr/lib/netbraid/allocator.uc, line 7, byte 1
```

Root cause: the SDK's `ucode -c <module.uc>` compiles the file as a script, where `export` is illegal. The code itself was valid when loaded as a module. Direct SDK execution of `allocator.uc` produced the same diagnostic, while importing the module compiled successfully.

No source rewrite was needed to remove valid top-level exports. The verification method was corrected: library modules are compiled through an importer (`import * as module from '...'`) and command-line entrypoints are compiled directly. `tests/compile-all.sh` now performs this correctly.

### Implemented changes

- Added `netbraid/files/usr/lib/netbraid/routing.uc`:
  - validates rule sections (family, protocol, address/port syntax, ingress and priority);
  - builds rule-ordered policy plans with weighted PCC buckets;
  - preserves stable member IDs and table IDs when members change health state;
  - renders ip rule and nftables classification fragments as inspection-only strings;
  - never executes commands or changes kernel state.
- Extended `config.uc` to parse and validate `rule` sections so LuCI Rules pages no longer produce unknown section errors.
- Added `tests/routing-test.uc` covering bucket weighting, selector generation, mark masks, stable IDs, degraded members, collision rejection, unsafe address rejection and disabled configuration.
- Registered the new suite in `tests/run.uc`-adjacent scripts (`tests/compile-all.sh`, `tests/package-test.sh`).
- Added the SDK ucode math module dependency to the backend Makefile because `util.uc`, `planner.uc` and `allocator.uc` import `math`.
- Fixed daemon `uloop.interval` argument order to `(interval_ms, callback)`, verified against the SDK module.
- Added a status-directory existence check before publishing `writeSnapshot()`.
- Added a valid `Build/Compile` recipe so the OpenWrt package build can complete.

### Verification executed

Environment: WSL2 Ubuntu-26.04; complete configured SDK at `/home/khaiphan/warp-ucode-25.12.6/sdk` (x86_64, OpenWrt 25.12.6; `ucode` 2026.01.16; `rpcd-mod-ucode=y`, `ucode-mod-math=y`, `luci-base=y`).

Command:

```bash
bash /mnt/d/REPO/RustWRT/rustwrt/netbraid/tests/compile-all.sh
```

Result: exit code 0. All actual outputs:

```text
PASS compile module allocator.uc
PASS compile module config.uc
PASS compile module daemon.uc
PASS compile module detector.uc
PASS compile module discovery.uc
PASS compile module health.uc
PASS compile module planner.uc
PASS compile module portal.uc
PASS compile module routing.uc
PASS compile module runtime.uc
PASS compile module util.uc
PASS compile script netbraid/files/usr/libexec/rpcd/netbraid.uc (absolute import rewritten to SDK path)
PASS compile script tests/detector-test.uc
PASS compile script tests/portal-test.uc
PASS compile script tests/routing-test.uc
PASS compile script tests/run.uc
PASS test tests/run.uc
PASS test tests/detector-test.uc
PASS test tests/portal-test.uc
PASS test tests/routing-test.uc
```

The rpcd compile test rewrites the deployed absolute import `/usr/lib/netbraid/runtime.uc` to the workspace path because the SDK host has no `/usr/lib/netbraid`; this validates syntax and dependency compilation, not an installed-device RPC call.

Additional direct command:

```bash
sh /mnt/d/REPO/RustWRT/rustwrt/netbraid/tests/package-test.sh
```

Earlier result after core/detector/portal suites were present: all three suites passed. Since then the new routing suite was added and all four suites passed through `compile-all.sh`.

LuCI JavaScript syntax was checked with `node --check` for all eight view files; all returned exit code 0.

### Package build

Backend APK build executed in the configured SDK:

```bash
cd /home/khaiphan/warp-ucode-25.12.6/sdk
rm -rf package/netbraid
mkdir -p package/netbraid
cp -a /mnt/d/REPO/RustWRT/rustwrt/netbraid/netbraid/. package/netbraid/
printf '\nCONFIG_PACKAGE_netbraid=y\n' >> .config
make defconfig
make V=s package/netbraid/compile
```

Result: exit code 0; SDK produced:

```text
/home/khaiphan/warp-ucode-25.12.6/sdk/bin/packages/x86_64/base/netbraid-0.1.0-r1.apk
```

Artifact copied to:

```text
artifacts/netbraid-0.1.0-r1.apk  (16718 bytes)
```

Artifact hash:

```text
sha256 17c98b846da7401d9e703822f141128983d89c204b8ebb9571402775f40c803e
```

The SDK `.config` was restored after the build. Build output is in `docs/build-25.12.6.log`.

### Not completed / blockers

- LuCI APK: NOT BUILT. The installed LuCI feed index did not register `luci-app-netbraid`; attempts with the package under `package/luci-app-netbraid` and under `feeds/luci/applications/luci-app-netbraid` ended with `No rule to make target 'package/.../luci-app-netbraid/compile'`. Feed refresh did not add the local app to `feeds/luci.tmp/.packageinfo`. SDK config was restored. Output is in `docs/build-luci-25.12.6.log`.
- IPK 24.10.8: NOT BUILT. The SDK at `/home/khaiphan/openwrt-sdk-24.10.8-x86-64_gcc-13.3.0_musl.Linux-x86_64` has no `.config` and an empty `include/package.mk`. An isolated build copy failed host prerequisites before package compilation.
- Full nftables transaction application: NOT IMPLEMENTED. The routing increment generates inspection-only fragments; no ip/nft commands are executed.
- Complete occupied-resource inventory, atomic apply/rollback, netifd event handling, health probes and portal enforcement: NOT IMPLEMENTED.
- LuCI pages were syntax-checked but not tested in a browser or on a device.
- No network namespace, QEMU, router or live packet tests were executed. No feature is claimed functional on a device.

### Prior increment status

The earlier RouteBraid progress table below recorded all tests as NOT RUN. Those entries are historical. The current executed results above supersede only the ucode checks that were actually run; they do not imply that integration, safety or performance requirements passed.

## 2026-11-18 late session — packaging and VM validation

- Repaired the corrupted SDK LuCI Makefile with `cp` from the project source (no PowerShell `$()` interpolation), added the standard `BuildPackage` scanner marker and `PKG_VERSION`/`PKG_RELEASE`, and verified the correct target `package/feeds/luci/luci-app-netbraid/compile`.
- Reran `tests/compile-all.sh`: all compile checks and all six runtime suites pass.
- Built both APK (25.12.6 SDK) and IPK (clean 24.10.8 SDK extraction) for backend and LuCI app; all four artifacts and hashes are in `docs/VM_TEST_RESULTS.md`.
- Installed the IPKs with `opkg` in the existing QEMU VM (OpenWrt 24.10.4; not 25.12.6) and found/fixed five real runtime defects: missing `lastIndexOf`, unsupported callback `replace`, missing status-dir creation, unsupported `uloop.cancel`, null detector state, and wrong rpcd ucode script path.
- After fixes, the VM produced a valid daemon status JSON, `luci.netbraid` ubus object with all six methods, correct ACL grants, and the installed LuCI menu at `admin/network/netbraid`.
- Browser acceptance and 25.12.6 APK install remain incomplete because the 25.12.6 VM/image was absent and the QEMU VM's SSH/LuCI login path became unreachable; details and truthful blockers are recorded in `docs/VM_TEST_RESULTS.md`.
