# RustWRT Binary Package Repository

RustWRT distributes prebuilt OpenWrt packages; it does not build or fork firmware.

## Support policy

- OpenWrt 24.x: opkg/IPK where the installed firmware uses opkg.
- OpenWrt 25.x and later: detect the actual package manager; never assume a major version alone guarantees APK compatibility.
- Each release, target/subtarget, architecture, libc and ABI combination must be validated before publication.
- Kernel modules require exact kernel ABI and firmware build compatibility; do not offer generic kmods.
- Unknown combinations fail closed, with a clear diagnostic.

## Logical artifact layout (published externally)

`<channel>/<release>/<target>/<subtarget>/<architecture>/<package-manager>/`

Each published feed must contain the correct package index and signatures for its package manager. Signing private keys stay outside Git; only public verification keys may be published.

## Workflow

1. Discover supported SDK/toolchain and target matrix.
2. Build packages with matching SDK and dependency ABI.
3. Test package metadata, dependency resolution and installation in representative OpenWrt images.
4. Generate and sign repository indexes.
5. Publish artifacts atomically to immutable release paths.
6. Update signed channel pointers only after validation.

The installer must identify `/etc/openwrt_release`, `opkg`/`apk`, architecture, target and existing trusted keys before selecting a feed. Do not add a feed if validation fails.

## Repository roles

Existing `net/`, `luci/`, `development/` and `tools/` remain package sources. `repository/config` stores policy; `scripts/compatibility` detects targets; `scripts/repository` handles index/sign/publish; `scripts/installer` contains onboarding; `tests/repository` validates feeds.
