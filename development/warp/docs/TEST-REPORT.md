# Release verification

The official RustWRT version is reset to 0.1.0-r1. Historical development evidence below is not verification of this release. Rebuild and retest before publishing.

# 0.3.0 development verification

0.2.0 is the runtime baseline: real OpenWrt 25.12.6 VM verified four WARP interfaces, IPv4/IPv6 connectivity, account reuse, reboot, routing isolation and scoped Vietnamese translation. For 0.3.0, run native APK and IPK packaging checks, then test both with their matching package managers and runtime dependencies. A noarch package does not guarantee compatibility with every firmware fork. See docs/BUILD.md.
