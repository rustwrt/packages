include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-warp
PKG_VERSION:=0.3.0
PKG_RELEASE:=2
PKG_LICENSE:=MIT
PKGARCH:=all

PKG_BUILD_DEPENDS += luci-base/host

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-warp
  PKGARCH:=all
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI Cloudflare WARP management application
  DEPENDS:=+cloudflare-warp +luci-base +rpcd +ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-ubus +wireguard-tools +uci
endef

define Package/luci-app-warp/description
  LuCI application for managing and monitoring Cloudflare WARP.
endef

define Build/Compile
endef

define Package/luci-app-warp/install
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/status $(1)/www/luci-static/resources/view/status/include $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/status/include/35_warp.js $(1)/www/luci-static/resources/view/status/include/35_warp.js
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/status/warp.js $(1)/www/luci-static/resources/view/status/warp.js
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/luci-app-warp.json $(1)/usr/share/luci/menu.d/luci-app-warp.json
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/luci.warp $(1)/usr/libexec/rpcd/luci.warp
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/luci-app-warp.json $(1)/usr/share/rpcd/acl.d/luci-app-warp.json
endef

# Match the standard LuCI post-install cache and RPC refresh. Do not
# restart netifd automatically: installing a package must not drop WANs.
define Package/luci-app-warp/postinst
#!/bin/sh
[ -z "$${IPKG_INSTROOT}" ] || exit 0
rm -f /tmp/luci-indexcache /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
/etc/init.d/rpcd reload 2>/dev/null || :
if handlers="$$(ubus call network get_proto_handlers 2>/dev/null)"; then
 if ! printf '%s\n' "$$handlers" | grep -q '"warp"[[:space:]]*:'; then
  echo 'WARP: restart networking from a local console to register the new protocol.' >&2
 fi
fi
exit 0
endef

$(eval $(call BuildPackage,luci-app-warp))

define Package/luci-i18n-warp-vi
  SECTION:=luci
  CATEGORY:=LuCI
  TITLE:=Vietnamese translation for Cloudflare WARP
  DEPENDS:=+luci-app-warp +luci-i18n-base-vi
  PKGARCH:=all
  HIDDEN:=1
  DEFAULT:=LUCI_LANG_vi
endef

define Package/luci-i18n-warp-vi/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n
	po2lmo ./po/vi/warp.po $(1)/usr/lib/lua/luci/i18n/warp.vi.lmo
endef

$(eval $(call BuildPackage,luci-i18n-warp-vi))
