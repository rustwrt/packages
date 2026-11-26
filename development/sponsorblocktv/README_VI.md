# SponsorBlockTV cho OpenWrt

[English](README.md) · [RustWRT](../../README_VI.md)

Bỏ qua các đoạn video YouTube TV được hỗ trợ và quản lý thiết bị ghép nối qua LuCI, sử dụng ucode và cầu nối Chromecast bằng Python.

## Gói phần mềm

- [sponsorblocktv](../../utils/sponsorblocktv/)
- [luci-app-sponsorblocktv](../../luci/luci-app-sponsorblocktv/)
- [luci-i18n-sponsorblocktv-vi](../../luci/luci-i18n-sponsorblocktv-vi/) (tùy chọn)

Cài đặt từ [kho gói](https://rustwrt.pages.dev/vi/feeds/).

## Build và kiểm thử

```
OPENWRT_DIR=/path/to/sdk scripts/build-openwrt.sh
python3 -m unittest discover -s tests
node tests/luci_check.js
node tests/luci_i18n_check.js
```

[Công cụ build](scripts/README_VI.md) · [Nguồn gốc và giấy phép](../../utils/sponsorblocktv/NOTICE.md)

Sao lưu cấu hình và tệp controller-id riêng tư trước khi nâng cấp. Giữ thư mục dữ liệu trên bộ nhớ bền vững và không chia sẻ seed giữa các router.
