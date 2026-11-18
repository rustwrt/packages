# RouteBraid

## Tiếng Việt

**NetBraid đang phát triển.** README hiện tại mô tả lõi thử nghiệm RouteBraid (Lua/OpenWrt) dùng để khám phá uplink và lập kế hoạch PCC; chưa phải công cụ thay thế mwan3/PBR có thể triển khai. Không áp dụng trực tiếp các biểu thức nftables do planner tạo ra.

**Phụ thuộc phát triển:** Lua 5.1, `luacheck`, `luac5.1`; runtime OpenWrt cần netifd/ubus theo Makefile tương ứng. Kiểm tra:

```sh
lua5.1 tests/run.lua
luacheck routebraid/files/usr/lib/lua routebraid/files/usr/sbin/routebraid tests
luac5.1 -p routebraid/files/usr/sbin/routebraid
```

**Trạng thái:** CLI khám phá chỉ đọc; không tạo service, route hoặc nftables khi cài. Chưa có build/release xác minh cho OpenWrt 25.12.6 APK hoặc 24.10.8 IPK. Xem `docs/PROGRESS.md`. Không thay đổi mã nguồn đang phát triển.

## English


RouteBraid is an experimental Lua/OpenWrt multi-uplink routing project. The complete target is defined in [ROUTEBRAID_SPEC.md](ROUTEBRAID_SPEC.md). This initial implementation is a discovery and planning core, not a usable mwan3/PBR replacement or a release candidate.

## Current behavior

The native `routebraid` package installs a read-only CLI and Lua modules. `routebraid discover` reads netifd through ubus and emits normalized JSON. `routebraid check-config` validates the disabled configuration and rejects activation. Installation creates no service, routing rules, nftables chains, or interface changes.

The planner selects healthy members in the best priority group, assigns stable member IDs to table/mark/priority slots, and creates deterministic weighted PCC classification expressions for nine modes and both address families. For protocols without TCP/UDP ports, port-only modes fall back to address-pair hashing. These expressions are fragments for development inspection, not a complete or validated nftables transaction. They must never be applied directly: route exclusions, mark restoration, owned-resource tracking, routing setup, atomic apply and rollback are still required.

A complete caller-supplied resource inventory is required by the planner. There is no live inventory collector yet. Full-mask WARP rules overlap the proposed mark region and correctly cause rejection; choosing numerically distant marks alone does not establish safe coexistence. Automatic coexistence with WARP is not implemented.

## Development checks

From the project root on a Linux development host:

```sh
lua5.1 tests/run.lua
luacheck routebraid/files/usr/lib/lua routebraid/files/usr/sbin/routebraid tests
find routebraid/files/usr/lib/lua tests -name '*.lua' -exec luac5.1 -p {} \;
luac5.1 -p routebraid/files/usr/sbin/routebraid
```

Lua has no separate static type-checking step configured. CI defines syntax, lint and unit checks; adding a workflow does not mean it has run. See [docs/PROGRESS.md](docs/PROGRESS.md) for evidence, limitations and remaining milestones.

## Packaging

`routebraid/Makefile` follows native OpenWrt package conventions and declares only dependencies used by the current code. It has not yet been built in either target SDK. Required release targets are OpenWrt 25.12.6 APK and 24.10.8 IPK, subject to verification of the actual SDK. No feed synchronization, deployment, signing or release has been performed.
