# NetBraid Dual Geo Database Engine — approved implementation directive

Status: Approved 2026-11-18. Implement as separate module without interrupting ongoing Detection Engine fixes.

## Modes and data
- Default Hybrid, plus SRS-only and GeoIP2-only modes.
- Support sing-box source JSON and compiled SRS rule sets for GeoIP CIDRs, GeoSite domain rules and service groups. Prefer parsing source JSON where possible; compiled .srs requires a verified compatible converter; do not pretend nftables reads .srs directly.
- Support MaxMind-compatible MMDB Country and ASN, and ISP only when the selected database provides ISP fields. Do not imply free GeoLite2 ASN provides ISP-level details.
- Enable country, ASN, ISP and service/domain-based routing policies via existing NetBraid PBR/PCC, WAN/WARP, and failover architecture. Preserve existing priority semantics and ensure conflicts have deterministic precedence.

## Runtime and resources
- No always-on sing-box process requirement. Convert enabled GeoIP CIDR rules into nftables interval sets. GeoSite must integrate with DNS resolution and account for shared CDN IPs, DNS bypass and encrypted DNS limitations; do not silently treat domain-to-IP mappings as exact domain routing.
- Optimize for MT7621/512 MB RAM: lazy-load only enabled sources, disk cache, bound memory/disk usage, deduplicate CIDRs, avoid whole-country databases in RAM when possible.
- Validate sources, schema, checksums when supplied; download to staging; atomic activation and rollback on failure. Protect management connectivity, preserve working configuration, and log provenance/update status. Allow manual and scheduled updates with user-controlled interval.
- Respect licenses and source distribution terms; configurable source URLs; sensible defaults, avoid unsupported download assumptions.

## LuCI and packaging
- Geo Database page: mode, sources, enable/disable sets, last update, storage footprint, test lookup and policy linkage, errors and rollback status; Vietnamese/English labels.
- Keep separate backend and LuCI packages, both APK for OpenWrt 25.12.x and IPK for OpenWrt 24.10.x. Provide unit tests for parser/conversion, IPv4/IPv6, priority, invalid data, atomic rollback and integration tests on VM where possible.
- Keep this feature modular and staged AFTER urgent detector test fixes; do not falsely report implementation complete. Update docs/PROGRESS.md with verified milestones.

## Approved expansion: Universal Rule Set Manager (2026-11-18)
- Build extensible adapter architecture, not separate long-running engines. Default Hybrid mode and optional per-source activation.
- Phase 1: sing-box SRS/source JSON, MaxMind-compatible MMDB, plain IPv4/IPv6 CIDR, domain list TXT. Validate format, IPv4/IPv6, source provenance, duplicate rules, memory bounds and rollback.
- Phase 2: Mihomo/Clash rule-provider YAML and security feeds (domain/IP blocklists). Security feeds must be opt-in and must not cause blocking by default.
- Phase 3: full PBR/PCC, Multi-WAN, WARP and LuCI policy integration with deterministic precedence and tests.
- Candidate providers: v2fly/domain-list-community, Loyalsoldier/v2ray-rules-dat, MetaCubeX/meta-rules-dat, blackmatrix7/ios_rule_script, IPdeny, IP2Location LITE, Spamhaus, HaGeZi, AdGuard DNS Filter. Provider availability, format, redistribution rights and freshness must be verified before enabling defaults.
- Preserve urgent existing detector tests, four APK/IPK packaging and VM validation as immediate release blockers. Implement expansion in staged, testable increments; do not claim complete before tested.
