# SPDX-License-Identifier: Apache-2.0
#
# Copyright (C) 2026 Bianka5441
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

PKG_NAME:=campus-auth
PKG_VERSION:=1.0.4
PKG_RELEASE:=1

PKG_MAINTAINER:=Bianka5441
PKG_LICENSE:=Apache-2.0

include $(INCLUDE_DIR)/package.mk

define Package/campus-auth
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  TITLE:=Campus network portal auto-authentication
  DEPENDS:=+curl +openssl-util
  PKGARCH:=all
endef

define Package/campus-auth/description
  Automatic authentication for gportal-based campus network portals.
  Reproduces the browser login flow (per-session sign/iv extraction and
  AES-128-CBC payload encryption) as a headless shell script, with a
  procd-supervised connectivity monitor and an ubus/rpcd status interface
  for LuCI. Configuration lives in /etc/config/campus-auth.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/campus-auth/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/campus-auth.sh $(1)/usr/bin/campus-auth
	$(INSTALL_BIN) ./files/campus-auth-loop.sh $(1)/usr/bin/campus-auth-loop
	$(INSTALL_BIN) ./files/campus-auth-mode.sh $(1)/usr/bin/campus-auth-mode

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/campus-auth.init $(1)/etc/init.d/campus-auth

	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./files/campus-auth.rpcd $(1)/usr/libexec/rpcd/campus-auth

	$(INSTALL_DIR) $(1)/usr/share/campus-auth/proto
	$(INSTALL_DATA) ./files/proto-gportal.sh $(1)/usr/share/campus-auth/proto/gportal.sh
	$(INSTALL_DATA) ./files/proto-ruijie.sh $(1)/usr/share/campus-auth/proto/ruijie.sh

	$(INSTALL_DIR) $(1)/usr/share/campus-auth
	$(INSTALL_DATA) ../docs/openclash-ua3f.yaml $(1)/usr/share/campus-auth/openclash-ua3f.yaml

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/campus-auth.config $(1)/etc/config/campus-auth
endef

define Package/campus-auth/conffiles
/etc/config/campus-auth
endef

$(eval $(call BuildPackage,campus-auth))
