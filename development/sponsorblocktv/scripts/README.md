# SponsorBlockTV Build Tools

[Tiếng Việt](README_VI.md) · [SponsorBlockTV](../README.md)

Run from development/sponsorblocktv/ with a matching OpenWrt SDK.

```
OPENWRT_DIR=/path/to/sdk scripts/build-openwrt.sh
```

For a 24.10.4 IPK build and signed index:

```
python3 scripts/build-24-feed.py "$SDK" "$FEED" --no-deploy
sh scripts/index-24-feed.sh "$SDK" "$FEED" "$PRIVATE_KEY" "$PUBLIC_KEY"
```

## Router tests

```
powershell -NoProfile -File scripts/test-environment.ps1 -RunTests -Network -Discovery
```

Requires the configured test router, Android TV emulator and LAN bridge. Reports: build/test-reports/.

Use --no-deploy for local builds; keep signing keys private. Verify target installation before publishing.
