include $(TOPDIR)/rules.mk

PKG_NAME:=netbraid
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/netbraid
  SECTION:=net
  CATEGORY:=Network
  TITLE:=NetBraid read-only routing discovery and planning
  DEPENDS:=+ucode +ucode-mod-fs +ucode-mod-math +ucode-mod-uci +ucode-mod-ubus +ucode-mod-uloop +rpcd-mod-ucode
endef

define Package/netbraid/description
  Native ucode interface discovery, config validation, bounded diagnostics and observer daemon.
  Routing and captive portal enforcement remain disabled until isolated resources are complete.
endef

define Package/netbraid/conffiles
/etc/config/netbraid
endef

define Build/Compile
	true
endef

define Package/netbraid/install
	$(INSTALL_DIR) $(1)/usr/lib/netbraid $(1)/usr/sbin $(1)/etc/config $(1)/etc/init.d $(1)/usr/share/rpcd/acl.d $(1)/usr/share/rpcd/ucode
	$(INSTALL_DATA) ./files/usr/lib/netbraid/*.uc $(1)/usr/lib/netbraid/
	$(INSTALL_BIN) ./files/usr/sbin/netbraid $(1)/usr/sbin/netbraid
	$(INSTALL_BIN) ./files/usr/sbin/netbraidd $(1)/usr/sbin/netbraidd
	$(INSTALL_BIN) ./files/etc/init.d/netbraid $(1)/etc/init.d/netbraid
	$(INSTALL_CONF) ./files/etc/config/netbraid $(1)/etc/config/netbraid
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/netbraid.json $(1)/usr/share/rpcd/acl.d/netbraid.json
	$(INSTALL_DATA) ./files/usr/libexec/rpcd/netbraid.uc $(1)/usr/share/rpcd/ucode/netbraid.uc
endef

$(eval $(call BuildPackage,netbraid))
