# WARP

[Tiếng Việt](README_VI.md) · [RustWRT](../../README.md)

Cloudflare WARP integration using netifd, kernel WireGuard and ucode.

## Packages

- [warp](../../net/warp/)
- [luci-app-warp](../../luci/luci-app-warp/)
- [luci-i18n-warp-vi](../../luci/luci-i18n-warp-vi/) (optional)

Install from the [package feed](https://rustwrt.pages.dev/feeds/). Configure WARP in Network → Interfaces and view its status in Status → Cloudflare WARP. If the protocol is not registered after installation, restart networking from a local console or reboot.

## Build and test

Run in this directory using Linux/WSL and a matching SDK.

```
sh tools/build-sdk.sh /path/to/sdk /path/to/new-output
sh tests/run-unit.sh
```

[Build guide](docs/BUILD.md) · [Architecture](docs/ARCHITECTURE.md)

Verify installation and upgrades on the target firmware. Kill switches and active multi-WAN failover are external responsibilities.
