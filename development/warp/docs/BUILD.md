# Build 0.3.0

One source tree and two native packaging formats. Use an unprivileged Linux user and the matching SDK, including its LuCI feeds.

    sh tools/build-sdk.sh /path/to/fresh/sdk /path/to/new/output

The default detects the SDK's native package manager. For the official 25.12.6 SDK, which contains both packaging implementations, build both formats:

    sh tools/build-sdk.sh /path/to/fresh/25.12.6/sdk /path/to/new/output both

Outputs: output/apk (three APKs), output/ipk (three IPKs). The IPKs come from the SDK native ipkg-build path, not APK conversion. For a vendor's OpenWrt 25.x firmware using opkg, prefer that firmware's own SDK and auto mode. Package architecture is all/noarch; kernel ABI and ucode module compatibility must be verified on target firmware. Native 24.10.8 IPK is also a CI target, not a guarantee of compatibility with every fork.

    sh tests/run-unit.sh
    python3 tests/package-check.py /path/to/output/ipk

Set UCODE and UCODE_MODULES to a matching host interpreter/module directory for the ucode unit tests. Use normal package scripts in a disposable matching OpenWrt VM for installation/reboot verification. Sign APK and IPK repository indexes separately with the appropriate tooling. Never bypass signature checks. Do not publish before both native formats have passed checks.

## Protocol discovery after installation

After installing both primary packages on a running router (APK or IPK), check:

    /lib/netifd/proto/warp.sh warp dump
    ubus call network get_proto_handlers

The first command must return valid JSON with name warp; the second must contain the warp handler. Netifd loads new shell protocol handlers at startup, not on a normal configuration reload. If the script dump succeeds but warp is absent from the handler list, restart networking from a local console or during a maintenance window:

    /etc/init.d/network restart

This temporarily interrupts connectivity. Do not automatically restart networking from an installation script. Check the handler list again, then hard-refresh LuCI. If warp is still absent, inspect logread, file permissions, script dump errors, and the firmware's netifd implementation before assuming package compatibility.

The r2 LuCI package clears its caches and reloads RPC on a live install, matching the official LuCI package hook. When the handler is missing it prints a maintenance-window restart reminder. Offline image builds do not run live actions.
