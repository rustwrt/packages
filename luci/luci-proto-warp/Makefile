include $(TOPDIR)/rules.mk

PKG_NAME:=luci-proto-warp
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKGARCH:=all

PKG_BUILD_DEPENDS += luci-base/host

include $(INCLUDE_DIR)/package.mk

define Package/luci-proto-warp
  PKGARCH:=all
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Protocols
  TITLE:=Experimental LuCI Cloudflare WARP protocol
  DEPENDS:=+cloudflare-warp +luci-base +rpcd +lua +lua-cjson +wireguard-tools +uci
endef

define Package/luci-proto-warp/description
  Experimental LuCI integration for a separately configured WARP account.
endef

define Build/Compile
endef

define Package/luci-proto-warp/install
	$(INSTALL_DIR) $(1)/www/luci-static/resources/protocol
	$(INSTALL_DATA) ./files/www/luci-static/resources/protocol/warp.js $(1)/www/luci-static/resources/protocol/warp.js
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/status $(1)/www/luci-static/resources/view/status/include $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/status/include/35_warp.js $(1)/www/luci-static/resources/view/status/include/35_warp.js
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/status/warp.js $(1)/www/luci-static/resources/view/status/warp.js
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/luci-proto-warp.json $(1)/usr/share/luci/menu.d/luci-proto-warp.json
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/luci.warp $(1)/usr/libexec/rpcd/luci.warp
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/luci-proto-warp.json $(1)/usr/share/rpcd/acl.d/luci-proto-warp.json
endef

$(eval $(call BuildPackage,luci-proto-warp))

define Package/luci-i18n-warp-vi
  SECTION:=luci
  CATEGORY:=LuCI
  TITLE:=Vietnamese translation for Cloudflare WARP
  DEPENDS:=+luci-proto-warp
  PKGARCH:=all
  HIDDEN:=1
  DEFAULT:=LUCI_LANG_vi
endef

define Package/luci-i18n-warp-vi/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n $(1)/etc/uci-defaults
	po2lmo ./po/vi/warp.po $(1)/usr/lib/lua/luci/i18n/warp.vi.lmo
	printf "%s\n" "uci set luci.languages.vi='Tiếng Việt (Vietnamese)'" 'uci commit luci' > $(1)/etc/uci-defaults/luci-i18n-warp-vi
endef

$(eval $(call BuildPackage,luci-i18n-warp-vi))
