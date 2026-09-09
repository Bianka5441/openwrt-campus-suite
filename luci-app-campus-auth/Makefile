# SPDX-License-Identifier: Apache-2.0
#
# Copyright (C) 2026 Bianka5441
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-campus-auth
PKG_VERSION:=1.0.4
PKG_RELEASE:=1

PKG_MAINTAINER:=Bianka5441
PKG_LICENSE:=Apache-2.0

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-campus-auth
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI support for campus authentication
  DEPENDS:=+luci-base +campus-auth
  PKGARCH:=all
endef

define Package/luci-app-campus-auth/description
  LuCI web interface for campus-auth: configure the portal credentials,
  watch the live network status and trigger authentication attempts from
  the OpenWrt admin UI (Services -> Campus Auth).
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/luci-app-campus-auth/install
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/luci-app-campus-auth.json \
		$(1)/usr/share/luci/menu.d/luci-app-campus-auth.json

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/luci-app-campus-auth.json \
		$(1)/usr/share/rpcd/acl.d/luci-app-campus-auth.json

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/campus-auth
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/campus-auth/*.js \
		$(1)/www/luci-static/resources/view/campus-auth/
endef

define Package/luci-app-campus-auth/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/rpcd restart 2>/dev/null || true
	/etc/init.d/rpcd reload 2>/dev/null || true
}
exit 0
endef

$(eval $(call BuildPackage,luci-app-campus-auth))
