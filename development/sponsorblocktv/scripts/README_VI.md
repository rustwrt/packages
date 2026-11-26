# Công cụ build SponsorBlockTV

[English](README.md) · [SponsorBlockTV](../README_VI.md)

Chạy từ development/sponsorblocktv/ với SDK OpenWrt tương ứng.

```
OPENWRT_DIR=/path/to/sdk scripts/build-openwrt.sh
```

Build IPK cho 24.10.4 và ký index:

```
python3 scripts/build-24-feed.py "$SDK" "$FEED" --no-deploy
sh scripts/index-24-feed.sh "$SDK" "$FEED" "$PRIVATE_KEY" "$PUBLIC_KEY"
```

## Kiểm thử router

```
powershell -NoProfile -File scripts/test-environment.ps1 -RunTests -Network -Discovery
```

Cần router thử nghiệm, máy ảo Android TV và LAN bridge đã cấu hình. Báo cáo: build/test-reports/.

Dùng --no-deploy để build cục bộ; giữ bí mật khóa ký. Kiểm thử cài đặt trên thiết bị mục tiêu trước khi phát hành.
