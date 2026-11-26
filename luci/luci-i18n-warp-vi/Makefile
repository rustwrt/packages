include $(TOPDIR)/rules.mk

PKG_NAME:=luci-i18n-warp-vi
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKGARCH:=all

PKG_BUILD_DEPENDS += luci-base/host

include $(INCLUDE_DIR)/package.mk

define Package/luci-i18n-warp-vi
  SECTION:=luci
  CATEGORY:=LuCI
  TITLE:=Vietnamese translation for Cloudflare WARP
  DEPENDS:=+luci-app-warp +luci-i18n-base-vi
  PKGARCH:=all
  HIDDEN:=1
  DEFAULT:=LUCI_LANG_vi
endef

define Build/Compile
endef

define Package/luci-i18n-warp-vi/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n
	po2lmo ./po/vi/warp.po $(1)/usr/lib/lua/luci/i18n/warp.vi.lmo
endef

$(eval $(call BuildPackage,luci-i18n-warp-vi))
