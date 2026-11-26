# SPDX-License-Identifier: GPL-3.0-or-later
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-sponsorblocktv
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-or-later
PKG_MAINTAINER:=Khải Phan

include $(INCLUDE_DIR)/package.mk

# Explicit package metadata: luci.mk does not export LUCI_CONFLICTS.
define Package/luci-app-sponsorblocktv
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI support for SponsorBlockTV
  DEPENDS:=+luci-base +sponsorblocktv +flock
  EXTRA_DEPENDS:=sponsorblocktv (>=0.1.0-r1)
  CONFLICTS:=luci-app-sponsorblock luci-app-isponsorblocktv
  PKGARCH:=all
endef

define Build/Compile
endef

define Package/luci-app-sponsorblocktv/install
	$(INSTALL_DIR) $(1)/www $(1)/usr/sbin
	$(CP) ./htdocs/. $(1)/www/
	$(CP) ./root/usr/. $(1)/usr/
	$(INSTALL_BIN) ./root/usr/sbin/sponsorblocktv-deps $(1)/usr/sbin/
	$(INSTALL_BIN) ./root/usr/sbin/sponsorblocktv-install-deps $(1)/usr/sbin/

	# Never propagate writable host directory or file modes into router archives.
	find $(1) -type d -exec chmod 0755 {} +
	find $(1) -type f -exec chmod 0644 {} +
	chmod 0755 $(1)/usr/sbin/sponsorblocktv-*
endef

define Package/luci-app-sponsorblocktv/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] && exit 0
rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
[ ! -x /etc/init.d/rpcd ] || /etc/init.d/rpcd reload >/dev/null 2>&1 || :
exit 0
endef

$(eval $(call BuildPackage,luci-app-sponsorblocktv))
