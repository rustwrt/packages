# RustWRT packages / Gói OpenWrt RustWRT

## Tiếng Việt

Repository này chứa trực tiếp **mã nguồn và Makefile** của các gói OpenWrt.

| Gói | Đường dẫn | Phụ thuộc chính |
| --- | --- | --- |
| `cloudflare-warp` | `net/cloudflare-warp/` | `ucode`, `netifd`, `wireguard-tools`, `kmod-wireguard`, `curl` |
| `luci-app-warp` | `luci/luci-app-warp/` | `cloudflare-warp`, `luci-base`, `rpcd`, `ucode` |
| `netbraid` | `net/netbraid/` | `ucode`, `ucode-mod-uci`, `ucode-mod-ubus`, `rpcd-mod-ucode` |
| `luci-app-netbraid` | `luci/luci-app-netbraid/` | `netbraid`, `luci-base` |
| `luci-i18n-warp-vi` | `luci/luci-app-warp/` | `luci-app-warp`, `luci-i18n-base-vi` |

NetBraid đang phát triển; mã nguồn, tài liệu và kiểm thử được lưu cùng feed tại `development/netbraid/`.

**Không còn package `luci-proto-warp`.** Giao diện WARP là ứng dụng LuCI độc lập tại Network → Cloudflare WARP. Backend vẫn sử dụng netifd/WireGuard để quản lý kết nối. Tài liệu và bài kiểm thử nguồn cũ ở `development/warp/`.

Thêm feed vào `feeds.conf.default`:

```text
src-git rustwrt https://github.com/rustwrt/packages.git
```

```sh
./scripts/feeds update rustwrt
./scripts/feeds install -a -p rustwrt
make menuconfig
```

Đây là mã nguồn phát triển, chưa phải bản phát hành APK/IPK đã xác minh. Kiểm tra Makefile để biết phụ thuộc đầy đủ và build trên SDK đúng phiên bản trước khi cài.

## English

This repository directly contains **OpenWrt package source and Makefiles**.

| Package | Path | Key dependencies |
| --- | --- | --- |
| `cloudflare-warp` | `net/cloudflare-warp/` | `ucode`, `netifd`, `wireguard-tools`, `kmod-wireguard`, `curl` |
| `luci-app-warp` | `luci/luci-app-warp/` | `cloudflare-warp`, `luci-base`, `rpcd`, `ucode` |
| `netbraid` | `net/netbraid/` | `ucode`, `ucode-mod-uci`, `ucode-mod-ubus`, `rpcd-mod-ucode` |
| `luci-app-netbraid` | `luci/luci-app-netbraid/` | `netbraid`, `luci-base` |
| `luci-i18n-warp-vi` | `luci/luci-app-warp/` | `luci-app-warp`, `luci-i18n-base-vi` |

NetBraid is in development; its source, documentation and tests are maintained in this feed under `development/netbraid/`.

**The `luci-proto-warp` package is retired.** WARP has a standalone LuCI page under Network → Cloudflare WARP; the backend still relies on netifd/WireGuard. Former development documentation and tests are under `development/warp/`.

Add to `feeds.conf.default`:

```text
src-git rustwrt https://github.com/rustwrt/packages.git
```

```sh
./scripts/feeds update rustwrt
./scripts/feeds install -a -p rustwrt
make menuconfig
```

Development source only; no verified APK/IPK release yet. Consult Makefiles for complete dependencies and build with a matching SDK before deployment.
