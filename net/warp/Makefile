include $(TOPDIR)/rules.mk

PKG_NAME:=warp
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/warp
  PKGARCH:=all
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Cloudflare WARP protocol and registration backend
  DEPENDS:=+ucode +ucode-mod-fs +coreutils-stat +netifd +wireguard-tools +kmod-wireguard +ip-full +jshn +flock +curl +ca-bundle
  CONFLICTS:=cloudflare-warp warp-proto warp-reg-lua
endef

define Build/Compile
endef

define Package/warp/install
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/90-warp-ipv6 $(1)/etc/uci-defaults/90-warp-ipv6
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/usr/lib/warp
	$(INSTALL_BIN) ./files/usr/sbin/warp-reg $(1)/usr/sbin/warp-reg
	$(INSTALL_DATA) ./files/usr/lib/warp/warp-reg.uc $(1)/usr/lib/warp/warp-reg.uc
	$(INSTALL_DIR) $(1)/lib/netifd/proto
	$(INSTALL_BIN) ./files/lib/netifd/proto/warp.sh $(1)/lib/netifd/proto/warp.sh
	$(INSTALL_DIR) $(1)/usr/libexec $(1)/etc/hotplug.d/iface
	$(INSTALL_BIN) ./files/usr/libexec/warp-health $(1)/usr/libexec/warp-health
	$(INSTALL_BIN) ./files/etc/hotplug.d/iface/90-warp-health $(1)/etc/hotplug.d/iface/90-warp-health
endef

$(eval $(call BuildPackage,warp))
