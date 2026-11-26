# SponsorBlockTV for OpenWrt

[Tiếng Việt](README_VI.md) · [RustWRT](../../README.md)

Skip supported YouTube TV segments and manage paired devices through LuCI, using ucode and a Python Chromecast bridge.

## Packages

- [sponsorblocktv](../../utils/sponsorblocktv/)
- [luci-app-sponsorblocktv](../../luci/luci-app-sponsorblocktv/)
- [luci-i18n-sponsorblocktv-vi](../../luci/luci-i18n-sponsorblocktv-vi/) (optional)

Install from the [package feed](https://rustwrt.pages.dev/feeds/).

## Build and test

```
OPENWRT_DIR=/path/to/sdk scripts/build-openwrt.sh
python3 -m unittest discover -s tests
node tests/luci_check.js
node tests/luci_i18n_check.js
```

[Build tools](scripts/README.md) · [Attribution and license](../../utils/sponsorblocktv/NOTICE.md)

Back up the configuration and private controller-id file before upgrades. Keep the data directory persistent and never share its seed between routers.
