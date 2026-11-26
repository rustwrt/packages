# WARP

[English](README.md) · [RustWRT](../../README_VI.md)

Tích hợp Cloudflare WARP bằng netifd, WireGuard trong kernel và ucode.

## Gói phần mềm

- [warp](../../net/warp/)
- [luci-app-warp](../../luci/luci-app-warp/)
- [luci-i18n-warp-vi](../../luci/luci-i18n-warp-vi/) (tùy chọn)

Cài đặt từ [kho gói](https://rustwrt.pages.dev/vi/feeds/). Cấu hình WARP trong Network → Interfaces và xem trạng thái tại Status → Cloudflare WARP. Nếu chưa thấy giao thức sau khi cài, khởi động lại mạng từ console cục bộ hoặc khởi động lại router.

## Build và kiểm thử

Chạy trong thư mục này bằng Linux/WSL với SDK tương ứng.

```
sh tools/build-sdk.sh /path/to/sdk /path/to/new-output
sh tests/run-unit.sh
```

[Hướng dẫn build](docs/BUILD.md) · [Kiến trúc](docs/ARCHITECTURE.md)

Kiểm thử cài đặt và nâng cấp trên firmware mục tiêu. Kill switch và failover đa WAN chủ động cần được cấu hình riêng.
