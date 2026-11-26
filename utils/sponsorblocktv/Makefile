# SPDX-License-Identifier: GPL-3.0-or-later
#
# SponsorBlockTV for OpenWrt
#
# Package OpenWrt build:
#   Add this repository to feeds.conf as a src-link, then:
#     ./scripts/feeds update -a && ./scripts/feeds install -a
#     make package/sponsorblocktv/compile V=s
#
# src-link example:
#   src-link sponsorblocktv /path/to/rustwrt/packages

SPONSORBLOCKTV_PACKAGE_DIR:=$(dir $(abspath $(lastword $(MAKEFILE_LIST))))
include $(TOPDIR)/rules.mk

PKG_NAME:=sponsorblocktv
PKG_VERSION:=$(strip $(shell cat $(SPONSORBLOCKTV_PACKAGE_DIR)/VERSION))
PKG_RELEASE:=1


PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE.md
PKG_MAINTAINER:=Khải Phan

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

# Native ucode runtime for SponsorBlock/Lounge/UCI/LuCI/procd.
#   ucode            - the interpreter
#   ucode-mod-uloop  - event loop (runtime, discovery, pairing)
#   ucode-mod-uclient - HTTP/HTTPS client (SponsorBlock, Lounge, DIAL)
#   ucode-mod-socket - UDP multicast (SSDP/DIAL, mDNS)
#   ucode-mod-struct - binary pack/unpack (Cast protobuf framing)
#   ucode-mod-digest - md5/sha256 (device_id, segment hashing)
# Chromecast Cast V2 discovery/pairing is delegated to a Python pychromecast
# bridge with three vendored pure-Python libraries (files/python).
# Requests, urllib3, Certifi, IDNA, Chardet and Zeroconf use matching system feeds.
# Zeroconf pulls in system ifaddr. No native TLS module
# or ucode-mod-ffi is required. HTTPS for uclient uses whatever libustream-ssl
# backend is already installed (openssl/wolfssl/mbedtls), so we do not force a
# specific one here.
PKG_DEPENDS:=\
	+ucode +ucode-mod-fs +ucode-mod-ubus +ca-bundle \
	+ucode-mod-uloop \
	+ucode-mod-uclient \
	+ucode-mod-socket \
	+ucode-mod-struct \
	+ucode-mod-digest \
	+python3 +python3-zeroconf +python3-requests +python3-urllib3 +python3-certifi +python3-idna +python3-chardet

define Package/sponsorblocktv
  SECTION:=utils
  CATEGORY:=Utilities
  SUBMENU:=Multimedia
  TITLE:=SponsorBlockTV client for YouTube TV clients
  URL:=https://github.com/rustwrt/packages
  CONFLICTS:=sponsorblock isponsorblocktv
  DEPENDS:=$(PKG_DEPENDS)
  PKGARCH:=all
endef

define Package/sponsorblocktv/description
  SponsorBlockTV mutes and skips sponsor segments, native YouTube ads
  and other SponsorBlock categories on YouTube TV / Cast devices in the
  local network. Managed through UCI (/etc/config/sponsorblocktv) and procd.

  The runtime is implemented natively in ucode with a Python Chromecast bridge. Devices are
  paired through the LuCI app or /usr/sbin/sponsorblocktv-pair.
  Author (OpenWrt edition): Khải Phan.
endef

define Package/sponsorblocktv/conffiles
/etc/config/sponsorblocktv
endef

define Build/Prepare
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(CP) ./LICENSE.md ./NOTICE.md $(PKG_BUILD_DIR)/
endef

# No compilation step: the ucode sources are shipped as-is.
define Build/Compile
	python3 "$(SPONSORBLOCKTV_PACKAGE_DIR)/check-portable-payload.py" ./files/python ./files/ucode/lib
endef

define Package/sponsorblocktv/install
	$(INSTALL_DIR) $(1)/usr/lib/sponsorblocktv
	$(CP) ./files/ucode/lib/. $(1)/usr/lib/sponsorblocktv/
	$(INSTALL_DIR) $(1)/usr/lib/sponsorblocktv/python
	$(CP) ./files/python/. $(1)/usr/lib/sponsorblocktv/python/

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/sponsorblocktv.config $(1)/etc/config/sponsorblocktv
	chmod 0600 $(1)/etc/config/sponsorblocktv

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/sponsorblocktv.init $(1)/etc/init.d/sponsorblocktv

	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/sponsorblocktv-merge-config $(1)/usr/sbin/sponsorblocktv-merge-config
	$(INSTALL_BIN) ./files/ucode/sponsorblocktv-run $(1)/usr/sbin/sponsorblocktv-run
	$(INSTALL_BIN) ./files/ucode/sponsorblocktv-write-config $(1)/usr/sbin/sponsorblocktv-write-config
	$(INSTALL_BIN) ./files/ucode/sponsorblocktv-policy $(1)/usr/sbin/sponsorblocktv-policy
	$(INSTALL_BIN) ./files/ucode/sponsorblocktv-pair $(1)/usr/sbin/sponsorblocktv-pair
	$(INSTALL_BIN) ./files/ucode/sponsorblocktv-discover $(1)/usr/sbin/sponsorblocktv-discover
	$(INSTALL_BIN) ./files/ucode/sponsorblocktv-cast-bridge $(1)/usr/sbin/sponsorblocktv-cast-bridge
	$(INSTALL_BIN) ./files/ucode/sponsorblocktv-watch-page $(1)/usr/sbin/sponsorblocktv-watch-page

	$(INSTALL_DIR) $(1)/usr/share/sponsorblocktv
	$(CP) ./files/sponsorblocktv-categories.json $(1)/usr/share/sponsorblocktv/categories.json

	# Normalize archive permissions even when source comes from a Windows mount.
	find $(1) -type d -exec chmod 0755 {} +
	find $(1) -type f -exec chmod 0644 {} +
	chmod 0600 $(1)/etc/config/sponsorblocktv
	chmod 0755 $(1)/etc/init.d/sponsorblocktv $(1)/usr/sbin/sponsorblocktv-*
endef

define Package/sponsorblocktv/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] && exit 0
chmod 600 /etc/config/sponsorblocktv 2>/dev/null || :
/usr/sbin/sponsorblocktv-merge-config || logger -t sponsorblocktv 'Configuration merge skipped; existing configuration retained'
/etc/init.d/sponsorblocktv enable >/dev/null 2>&1 || :
if [ -f /tmp/sponsorblocktv-was-running ] || [ "$$(uci -q get sponsorblocktv.main.enabled)" = 1 ]; then
    /etc/init.d/sponsorblocktv start || logger -t sponsorblocktv 'Start after installation failed'
fi
rm -f /tmp/sponsorblocktv-was-running
exit 0
endef

define Package/sponsorblocktv/prerm
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] && exit 0
if [ "$$1" = upgrade ] && /etc/init.d/sponsorblocktv running; then
    (umask 077; touch /tmp/sponsorblocktv-was-running)
fi
/etc/init.d/sponsorblocktv stop >/dev/null 2>&1 || :
/etc/init.d/sponsorblocktv disable >/dev/null 2>&1 || :
exit 0
endef

$(eval $(call BuildPackage,sponsorblocktv))
