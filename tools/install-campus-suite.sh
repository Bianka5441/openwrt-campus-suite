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
# The suite runs on both routers we deploy: mipsel_24kc (MT7621-class) and
# aarch64_cortex-a53. campus-auth/luci ipks are arch-all; only the ua3f
# binary is arch-specific. print-architecture lists every known arch with
# priorities - check membership, not the last line.
TARGET_ARCH=""
for a in $(opkg print-architecture 2>/dev/null | awk '{print $2}'); do
	case "$a" in
		mipsel_24kc|aarch64_cortex-a53) TARGET_ARCH="$a" ;;
	esac
done
[ -n "$TARGET_ARCH" ] || die "unsupported architecture for this suite"

# ------------------------------------------------------- packages ---
for f in campus-auth luci-app-campus-auth; do
	[ -s "$DIR/$f.ipk" ] || die "missing $DIR/$f.ipk"
done
# ua3f.ipk is only mandatory when no arch-correct ua3f is installed yet
if [ ! -x /usr/bin/ua3f ] && [ ! -s "$DIR/ua3f.ipk" ]; then
	die "missing $DIR/ua3f.ipk"
fi

info "1/4 installing campus-auth + luci-app"
opkg install "$DIR/campus-auth.ipk" || die "campus-auth install failed"
opkg install "$DIR/luci-app-campus-auth.ipk" || die "luci app install failed"

# opkg does NOT restore a deleted conffile when the package is already
# installed ("up to date"). A router whose config was wiped (or lost)
# would then boot with no /etc/config/campus-auth at all: restore it
# from the ipk's data tarball in that case.
if [ ! -e /etc/config/campus-auth ]; then
	info "   /etc/config/campus-auth missing: force-reinstalling to restore it"
	opkg install --force-reinstall "$DIR/campus-auth.ipk" >/dev/null 2>&1
fi
if [ ! -e /etc/config/campus-auth ]; then
	TMPD="/tmp/ca-conffile.$$"
	mkdir -p "$TMPD"
	tar -xzf "$DIR/campus-auth.ipk" -C "$TMPD" || die "campus-auth.ipk unreadable"
	tar -xzf "$TMPD/data.tar.gz" -C / ./etc/config/campus-auth \
		|| die "could not restore /etc/config/campus-auth from the ipk"
	rm -rf "$TMPD"
fi
chmod 600 /etc/config/campus-auth

# LuCI caches the menu index and compiled templates; stale entries hide
# the new app or keep serving old pages until the router reboots.
info "   clearing LuCI index/template caches"
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache* /tmp/luci-templates* 2>/dev/null
/etc/init.d/rpcd restart >/dev/null 2>&1

# ---------------------------------------------------------- ua3f ---
info "2/4 installing ua3f (files only: its declared iptables deps are"
info "   only needed for TPROXY mode; we run SOCKS5 and only need libc)"
if [ -x /usr/bin/ua3f ] && [ -e /etc/config/ua3f ]; then
	# An arch-correct ua3f is already installed AND its config survived:
	# reuse both regardless of which arch the bundled ipk was built for.
	info "   ua3f already installed, keeping the existing binary and config"
elif opkg install --force-depends "$DIR/ua3f.ipk" 2>/dev/null && [ -e /etc/config/ua3f ]; then
	:
else
	# opkg refused (deps) or the config is gone: full manual extraction
	# restores the binary, init script and default config in one go.
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
# the ipk's default config ships with the master switch OFF - without
# this the init script silently refuses to start ("enabled" section)
uci -q get ua3f.enabled.enabled >/dev/null 2>&1 || uci set ua3f.enabled=ua3f
uci set ua3f.enabled.enabled="1"
uci set ua3f.main.server_mode="SOCKS5"
uci set ua3f.main.port="1080"
uci set ua3f.main.bind="127.0.0.1"
uci set ua3f.main.rewrite_mode="GLOBAL"
uci set ua3f.main.ua="$UA"
uci set ua3f.main.log_level="WARN"
uci commit ua3f
/etc/init.d/ua3f enable
/etc/init.d/ua3f start 2>/dev/null
i=0; while ! netstat -ltn 2>/dev/null | grep -q ':1080 '; do
	i=$((i + 1)); [ "$i" -gt 6 ] && break; sleep 1
done
netstat -ltn 2>/dev/null | grep -q ':1080 ' && info "ua3f: listening on 1080" \
	|| info "WARNING: ua3f not listening yet (step-4 verification polls longer)"

# ---------------------------------------------- campus-auth mode ---
# Credentials/mode policy (LESSONS #21: never overwrite live credentials):
#   1. USERNAME/PASSWORD env given      -> set them + mode anti-detect
#   2. router already has non-empty creds -> KEEP them and KEEP its mode
#   3. nothing given, nothing configured  -> fresh install still lands in
#      mode anti-detect (user requirement: every flashed router comes up
#      with the full protection stack running; auth just waits for creds)
WANTED_MODE="${MODE:-anti-detect}"
EXISTING_USER=$(uci -q get campus-auth.config.username 2>/dev/null)
if [ -n "${USERNAME:-}" ] && [ -n "${PASSWORD:-}" ]; then
	info "4/4 campus-auth: credentials provided -> $WANTED_MODE"
	uci set campus-auth.config.username="$USERNAME"
	uci set campus-auth.config.password="$PASSWORD"
	uci set campus-auth.config.mode="$WANTED_MODE"
	uci set campus-auth.config.auth_host="${AUTH_HOST:-192.168.99.2}"
	uci set campus-auth.config.nas_name="${NAS_NAME:-GKDX}"
	uci commit campus-auth
elif [ -n "$EXISTING_USER" ]; then
	EXISTING_MODE=$(uci -q get campus-auth.config.mode 2>/dev/null)
	info "4/4 campus-auth: existing credentials kept (account ends ...${EXISTING_USER##*??????}); mode ${EXISTING_MODE:-anti-detect}"
	uci set campus-auth.config.mode="${EXISTING_MODE:-$WANTED_MODE}"
	uci commit campus-auth
else
	info "4/4 campus-auth: fresh install -> mode=$WANTED_MODE (no credentials yet: auth idles until an account is set)"
	uci set campus-auth.config.mode="$WANTED_MODE"
	uci delete campus-auth.config.username 2>/dev/null
	uci delete campus-auth.config.password 2>/dev/null
	uci commit campus-auth
fi
chmod 600 /etc/config/campus-auth
/etc/init.d/campus-auth enable
rm -f /etc/config/campus-auth-opkg

# --------------------------------------- openclash UA3F template ---
# Ship the proven "port-80 -> UA3F" clash config even in normal mode, and
# point OpenClash at it: mode 2/3 can then start OpenClash one-shot with
# NO subscription needed (80/tcp via UA3F, everything else direct; the
# user only adds nodes later if they want a ladder).
if [ -s /usr/share/campus-auth/openclash-ua3f.yaml ] && [ -d /etc/openclash ]; then
	mkdir -p /etc/openclash/config
	cp -f /usr/share/campus-auth/openclash-ua3f.yaml /etc/openclash/config/openclash-ua3f.yaml
	# touch uci only when a value actually changes: every openclash uci
	# commit triggers an ucitrack auto-restart that races (and can kill)
	# the core we start below
	OC_CHANGED=0
	if [ "$(uci -q get openclash.config.config_path)" != "/etc/openclash/config/openclash-ua3f.yaml" ]; then
		uci set openclash.config.config_path="/etc/openclash/config/openclash-ua3f.yaml"
		OC_CHANGED=1
	fi
	if [ "$(uci -q get openclash.config.enable)" != "1" ]; then
		uci set openclash.config.enable="1"
		OC_CHANGED=1
	fi
	# Transparent proxy mode, copied from the proven working router:
	# redir-host-tun creates the utun device + fwmark policy routing that
	# pulls LAN port-80 traffic into clash (and on to UA3F). The firmware
	# default (fake-ip / no tun) leaves LAN HTTP unproxied and UA3F idle -
	# UA unification would silently never happen.
	if [ "$(uci -q get openclash.config.en_mode)" != "redir-host-tun" ]; then
		uci set openclash.config.en_mode="redir-host-tun"
		OC_CHANGED=1
	fi
	if [ "$(uci -q get openclash.config.enable_redirect_dns)" != "1" ]; then
		uci set openclash.config.enable_redirect_dns="1"
		OC_CHANGED=1
	fi
	[ "$OC_CHANGED" = 1 ] && uci commit openclash
	info "openclash: config preset to the UA3F template (/etc/openclash/config/openclash-ua3f.yaml)"
	info "   (80 端口走 UA3F、其余直连；要梯子再在 OpenClash 页面加订阅)"
fi

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
	# restart so the mode manager applies the effective mode
	/etc/init.d/campus-auth restart
	rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache* 2>/dev/null
	if [ -z "$EXISTING_USER" ]; then
		info "no credentials given: auth idles until an account is set in"
		info "  LuCI -> 校园网认证 -> 参数设置 (protection stack already running)"
	fi
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
	/etc/hotplug.d/iface/99-campus-auth \
	/usr/share/campus-auth/openclash-ua3f.yaml \
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

# the protection stack MUST be up after every flash (mode 2 by default)
[ "$(uci -q get campus-auth.config.mode)" = "$WANTED_MODE" ] \
	|| die "mode is '$(uci -q get campus-auth.config.mode)', expected $WANTED_MODE"

i=0
until netstat -ltn 2>/dev/null | grep -q ':1080 '; do
	i=$((i + 1)); [ "$i" -gt 12 ] && die "ua3f not listening on 1080 after flash"
	sleep 2
done
info "ua3f: listening on 1080"

if [ -x /etc/init.d/openclash ]; then
	# a preset en_mode/config_path only takes effect at core (re)start:
	# restart whenever the installer changed openclash settings, then let
	# the wait-with-heal below confirm the core came back
	if [ "$OC_CHANGED" = 1 ]; then
		info "openclash: restarting to apply transparent mode (redir-host-tun)"
		/etc/init.d/openclash restart >/dev/null 2>&1
	fi
	i=0; healed=0
	until pgrep -f "/etc/openclash/" >/dev/null 2>&1; do
		i=$((i + 1))
		if [ "$i" -gt 20 ] && [ "$healed" = 0 ]; then
			# ucitrack may have raced us; wait out its grace window and
			# bring the core up once more
			info "openclash core died during setup; healing"
			uci -q set openclash.config.enable="1"; uci -q commit openclash
			/etc/init.d/openclash start >/dev/null 2>&1
			healed=1; i=0
		fi
		if [ "$healed" = 1 ] && [ "$i" -gt 20 ]; then
			die "openclash core not running after flash (see /tmp/openclash.log)"
		fi
		sleep 3
	done
	info "openclash: core running with the UA3F template"
	if [ "$(uci -q get openclash.config.en_mode)" = "redir-host-tun" ]; then
		# the core comes up first; OpenClash creates the utun device a few
		# seconds later in its startup sequence - poll for it
		i=0
		until ip link | grep -qi utun; do
			i=$((i + 1)); [ "$i" -gt 20 ] && \
				die "utun device missing after 60s - transparent proxy is OFF (see /tmp/openclash.log)"
			sleep 3
		done
		info "openclash: utun transparent interface up"
	fi
else
	info "note: openclash is not installed on this firmware; only UA3F + hardening run"
fi

# hardening needs the campus uplink: either already applied, or it will
# be applied automatically by the netifd hotplug hook when the cable
# goes in - make that expectation explicit instead of a silent pending
if iptables -t mangle -S POSTROUTING 2>/dev/null | grep -q "TTL --ttl-set 64"; then
	info "hardening: TTL/NTP/DNS rules active on the uplink"
elif grep -q "campus-auth hardening" /etc/firewall.user 2>/dev/null; then
	info "hardening: rules persisted, waiting for the campus uplink"
else
	info "hardening: pending - will auto-apply via hotplug when the campus cable is plugged in"
fi

info "verification PASSED - mode $WANTED_MODE, UA3F + OpenClash up, suite complete"
