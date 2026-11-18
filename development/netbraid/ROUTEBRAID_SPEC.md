# PHÁT TRIỂN DỰ ÁN ROUTEBRAID — 0.1.0
Bạn là coding agent chính. Hãy chủ động phát triển mã nguồn thực, không dừng ở skeleton. Workspace: D:\REPO\RustWRT\rustwrt\routebraid. Không thay đổi các repository khác trừ khi đồng bộ package definitions vào rustwrt/packages sau khi kiểm tra. Bắt đầu bằng khảo sát git, SDK, dung lượng, OpenWrt và luci-proto-warp, ghi tiến độ vào docs/PROGRESS.md.
## Mục tiêu và nền tảng
RouteBraid thay thế mwan3 và kết hợp PBR, PCC MikroTik, độc lập mwan3/PBR/iptables. Backend Lua (không runtime Rust/Python/Node); LuCI JavaScript native; nftables/firewall4, iproute2 policy routing, conntrack, netifd/ubus, UCI, procd. Forwarding, classification, load balancing thực thi trong kernel. OpenWrt 25.12.6 APK và 24.10.8 IPK qua SDK chính thức; kiểm tra phiên bản SDK thực có trước khi build.
## Cấu trúc
routebraid/Makefile, routebraid/files/; luci-app-routebraid/Makefile, luci-app-routebraid/files/, luci-app-routebraid/po/vi/; tests/, tools/, docs/, .github/workflows/, README.md, README.vi.md, CHANGELOG.md, LICENSE. Packages routebraid, luci-app-routebraid, luci-i18n-routebraid-vi; daemon routebraidd; UCI /etc/config/routebraid; LuCI Network → RouteBraid.
## Interface discovery
Dùng ubus/netifd để phát hiện mọi interface Layer 3 có Internet (WAN, LAN có gateway, DHCP/static/PPPoE, WWAN/Wi-Fi/4G/5G, VLAN, WireGuard, WARP, OpenVPN); không phụ thuộc tên WAN/LAN; không tạo interface ảo; đọc device, IP, gateway, subnet, routes, trạng thái và dependency graph.
## Routing
Routing table riêng theo nguồn, IPv4/IPv6, rule source/destination IP/subnet, protocol, source/destination port, ingress interface, priority; LAN traffic và tùy chọn router-originated. Bảo toàn connected/local/management/internal routes, không sửa default routes ngoài phạm vi RouteBraid.
## Failover
Nhóm priority, weight, health, failover/failback, recovery delay/threshold; nhiều nguồn cùng cấp, chuyển kết nối mới, không hứa giữ TCP khi public IP thay đổi; conntrack selective, không flush toàn bảng.
## PCC
Nftables deterministic hash cho đủ 9 chế độ: src-address, dst-address, both-addresses, src-port, dst-port, both-ports, src-address-and-port, dst-address-and-port, both-addresses-and-ports. Weighted PCC (3:2:1 = ~50/33.3/16.7% số kết nối mới, không phải băng thông), ct mark persist và packet mark restore; khi down tái phân bổ new flows, bảo vệ existing flows; non-TCP/UDP và IPv6 hash.
## Health
ICMP, TCP connect, DNS query, HTTP/HTTPS; targets, interval, timeout, failure/recovery counts, minimum working targets; Online/Offline/Degraded/Recovering/Disabled; probes bắt buộc qua đúng interface/table; hạn chế tiến trình.
## LuCI
Native JS pages Overview (latency/loss/gateway/IPv4/IPv6/status/policy), Interfaces, Members, Policies (single/failover/load balancing/weighted PCC/PCC+failover), Rules, Diagnostics (tables, rules, nft, ct mark, logs). English+Vietnamese; RPC ACL và validation hai phía.
## WARP
Nghiên cứu rustwrt/luci-proto-warp hiện có; WAN→WARP1, LAN→WARP2, WWAN; tránh xung đột fwmark, table ID, rule priority, transport route loop, dependency cycles; không sửa WARP trừ cần thiết.
## Safety
Namespace nft riêng, bit-mask fwmark cấp phát có kiểm tra xung đột; nft atomic transaction; validate-before-apply và rollback; không flush firewall, routing table, conntrack; không thay NAT/zones/LAN; firewall4 reload/netifd hotplug; đánh giá software/hardware offload; cleanup tài nguyên owned khi stop/uninstall; bảo vệ SSH/LuCI; cài xong mặc định không bật disruptive policies.
## Tests
Lua unit tests, Linux network namespaces integration, QEMU OpenWrt. Test dual WAN, WAN+LAN, WAN+WARP, dual WARP different upstream, >=3 sources, link down, Internet down while link up, failover/failback, weighted PCC, sticky connections, IPv4/IPv6, firewall reload, daemon restart, reboot, IP/gateway changes, admin access, install/upgrade/uninstall, CPU/RAM/concurrent flows/throughput. Chỉ ghi PASS nếu thực sự chạy và xác minh; nếu chưa chạy ghi NOT RUN.
## Packaging/release
Native OpenWrt build; APK 25.12.6, IPK 24.10.8, khai báo dependencies đầy đủ, luci app kéo backend tự động. Đồng bộ source feed rustwrt/packages sau khi xác minh cấu trúc. GitHub Actions build/test/dependency verification/signing/checksums; không tạo khóa ký giả; pre-release chỉ khi test đạt; stable sau khi đạt toàn bộ.
## Execution
1 inspect workspace/SDK/storage 2 study mwan3/PBR/PCC/nft 3 implement Lua/UCI/netifd 4 routing 5 health/failover 6 PCC 7 LuCI 8 WARP integration 9 SDK builds/tests 10 feed sync/git 11 preview release. Chủ động sửa lỗi, chạy lại test, commit có kiểm soát; không push/release khi chưa xác minh. Không commit secrets, logs, build outputs. Báo cáo rõ hoàn thành, chưa hoàn thành, test evidence và blockers. Bắt đầu triển khai ngay.