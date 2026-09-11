#!/bin/sh
# install-campus-suite.sh - offline installer for OpenWrt 24.10 (mipsel_24kc).
#
# Expects the three .ipk files next to this script:
#   campus-auth.ipk  luci-app-campus-auth.ipk  ua3f.ipk
# Optional answer file (see credentials.example): ./campus-credentials.sh
#
# Usage (as root, on the router):
#   sh install-campus-suite.sh            # installs stack, mode=normal
#   USERNAME=... PASSWORD=... sh install-campus-suite.sh
#                                         # also configures + enables auth
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"

info() { echo "[install] $*"; }
die()  { echo "[install][FATAL] $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"
opkg print-architecture 2>/dev/null | grep -q mipsel_24kc || \
	die "this installer targets mipsel_24kc (wrong router/firmware?)"

# ------------------------------------------------------- packages ---
for f in campus-auth luci-app-campus-auth ua3f; do
	[ -s "$DIR/$f.ipk" ] || die "missing $DIR/$f.ipk"
done

info "1/4 installing campus-auth + luci-app"
opkg install "$DIR/campus-auth.ipk" || die "campus-auth install failed"
opkg install "$DIR/luci-app-campus-auth.ipk" || die "luci app install failed"

# LuCI caches the menu index and compiled templates; stale entries hide
# the new app or keep serving old pages until the router reboots.
info "   clearing LuCI index/template caches"
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache* /tmp/luci-templates* 2>/dev/null
/etc/init.d/rpcd restart >/dev/null 2>&1

# ---------------------------------------------------------- ua3f ---
info "2/4 installing ua3f (files only: its declared iptables deps are"
info "   only needed for TPROXY mode; we run SOCKS5 and only need libc)"
if opkg install --force-depends "$DIR/ua3f.ipk" 2>/dev/null; then
	:
else
	TMPD="/tmp/ua3f-unpack.$$"
	mkdir -p "$TMPD"
	tar -xzf "$DIR/ua3f.ipk" -C "$TMPD" || die "ua3f.ipk not a tar.gz ipk"
	tar -xzf "$TMPD/data.tar.gz" -C / || die "ua3f data.tar.gz extract failed"
	rm -rf "$TMPD"
	[ -x /usr/bin/ua3f ] || die "ua3f binary missing after extraction"
	chmod +x /usr/bin/ua3f
	[ -x /etc/init.d/ua3f ] && chmod +x /etc/init.d/ua3f
fi

# ------------------------------------------------- ua3f SOCKS5 cfg ---
info "3/4 configuring ua3f: SOCKS5 on 127.0.0.1:1080, GLOBAL Chrome UA"
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36'
uci set ua3f.main.server_mode="SOCKS5"
uci set ua3f.main.port="1080"
uci set ua3f.main.bind="127.0.0.1"
uci set ua3f.main.rewrite_mode="GLOBAL"
uci set ua3f.main.ua="$UA"
uci set ua3f.main.log_level="WARN"
uci commit ua3f
/etc/init.d/ua3f enable
/etc/init.d/ua3f start 2>/dev/null
sleep 2
netstat -ltn 2>/dev/null | grep -q ':1080 ' && info "ua3f: listening on 1080" \
	|| info "WARNING: ua3f not listening (check logread)"

# ---------------------------------------------- campus-auth mode ---
info "4/4 campus-auth: default mode=normal (plain router, no auth)"
uci set campus-auth.config.mode="normal"
uci delete campus-auth.config.username 2>/dev/null
uci delete campus-auth.config.password 2>/dev/null
uci commit campus-auth
chmod 600 /etc/config/campus-auth
/etc/init.d/campus-auth enable

if [ -n "${USERNAME:-}" ] && [ -n "${PASSWORD:-}" ]; then
	info "credentials provided: configuring + enabling anti-detect mode"
	uci set campus-auth.config.username="$USERNAME"
	uci set campus-auth.config.password="$PASSWORD"
	uci set campus-auth.config.mode="anti-detect"
	uci set campus-auth.config.auth_host="${AUTH_HOST:-192.168.99.2}"
	uci set campus-auth.config.nas_name="${NAS_NAME:-GKDX}"
	uci commit campus-auth
	chmod 600 /etc/config/campus-auth
	/etc/init.d/campus-auth restart
else
	# restart so the mode manager applies "normal" (stops ua3f etc.)
	/etc/init.d/campus-auth restart
	rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache* 2>/dev/null
	info "no credentials given: left in mode=normal; to enable later:"
	info "  LuCI -> 校园网认证 -> 参数设置, fill account, pick mode ②"
fi

info "done. Clock note: power-cycled routers may run hours slow; check"
info "  with 'date' and fix via 'date -u -s @<epoch>' before relying on"
info "  the nightly quiet window."

# ------------------------------------------------------------ verify ---
# One-shot completeness check: every file the suite needs at runtime.
# A missing core file here means the shipped ipk is broken - fail loudly
# instead of degrading silently (see LESSONS #28).
info "verifying installation..."
MISSING=
for f in \
	/usr/bin/campus-auth \
	/usr/bin/campus-auth-loop \
	/usr/bin/campus-auth-mode \
	/usr/share/campus-auth/proto/gportal.sh \
	/etc/init.d/campus-auth \
	/usr/libexec/rpcd/campus-auth \
	/usr/lib/lua/luci/controller/campus-auth.lua \
	/usr/lib/lua/luci/model/cbi/campus-auth/settings.lua \
	/usr/lib/lua/luci/view/campus-auth/status.htm \
	/usr/lib/lua/luci/view/campus-auth/status_content.htm \
	/usr/share/luci/menu.d/luci-app-campus-auth.json \
	/usr/share/rpcd/acl.d/luci-app-campus-auth.json \
	/usr/bin/ua3f \
	/etc/init.d/ua3f \
	/etc/config/campus-auth
do
	[ -e "$f" ] && continue
	MISSING="$MISSING $f"
	echo "[install][FATAL] missing:$f" >&2
done
[ -z "$MISSING" ] || die "incomplete install - do NOT use this router; rebuild the ipks"

opkg list-installed | grep -E '^(campus-auth|luci-app-campus-auth)' || \
	die "package db lost campus-auth?!"

# smoke: the mode manager must actually run (catches missing helpers)
/usr/bin/campus-auth-mode apply || die "campus-auth-mode apply failed"
/etc/init.d/campus-auth restart >/dev/null 2>&1
info "verification PASSED - suite is complete and running"
