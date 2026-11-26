# SPDX-License-Identifier: GPL-3.0-or-later
include $(TOPDIR)/rules.mk
PKG_NAME:=luci-i18n-sponsorblocktv-vi
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-or-later
PKG_MAINTAINER:=Khải Phan
include $(INCLUDE_DIR)/package.mk
define Package/luci-i18n-sponsorblocktv-vi
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=5. Translations
  TITLE:=Vietnamese language for SponsorBlockTV (private catalog)
  CONFLICTS:=luci-i18n-sponsorblock-vi luci-i18n-isponsorblocktv-vi
  DEPENDS:=+luci-app-sponsorblocktv
  EXTRA_DEPENDS:=luci-app-sponsorblocktv (>=0.1.0-r1)
  PKGARCH:=all
endef
define Build/Compile
endef
define Package/luci-i18n-sponsorblocktv-vi/install
	$(INSTALL_DIR) $(1)/www/luci-static/resources/sponsorblocktv/i18n
	$(INSTALL_DATA) ./htdocs/luci-static/resources/sponsorblocktv/i18n/vi.json $(1)/www/luci-static/resources/sponsorblocktv/i18n/vi.json
endef
$(eval $(call BuildPackage,luci-i18n-sponsorblocktv-vi))
