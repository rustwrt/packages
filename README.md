# RustWRT Packages

Shared native OpenWrt source feed. WARP is the initial development candidate; no stable binary feed is published yet.

    src-git rustwrt https://github.com/rustwrt/packages.git

For reproducible firmware builds append ^FULL_COMMIT_SHA to the URL. For local development, use:

    src-link rustwrt /absolute/path/to/RustWRT/rustwrt/packages

Run scripts/feeds update rustwrt then scripts/feeds install -a -p rustwrt. The WARP backend, LuCI integration, and optional Vietnamese language package come from two package directories.

Import a reviewed committed source revision using python3 tools/import-warp.py /path/to/luci-proto-warp FULL_COMMIT_SHA; review the changes and provenance.json before committing. Do not edit mirrored package files independently. Further projects can add category/package directories and register their origin.

Binary distribution is owned by rustwrt/website. Native signed IPK and APK only. No credentials, private signing keys, binary artifacts or VM data belong here.

To enable automatic candidate builds, configure PACKAGE_BUILD_ENABLED=true and a narrowly scoped WEBSITE_WORKFLOW_TOKEN (Actions write on rustwrt/website) to request a candidate automatically on main. This does not publish a stable release.
