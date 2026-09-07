#!/bin/sh
# bootstrap-stack.sh - one-shot provisioning of the campus-auth stack on a
# fresh OpenWrt router:
#   1. campus-auth + luci-app-campus-auth from the GitHub release
#   2. UA3F (matching CPU arch) with a unified realistic User-Agent
#   3. OpenClash config (only if OpenClash is already installed)
#   4. TTL / NTP / DNS anti-detection hardening (fw3 iptables AND fw4 nft)
#
# Usage (on the router, as root):
#   USERNAME='2024xxxx' PASSWORD='xxxxxx' sh bootstrap-stack.sh
# School-specific overrides (defaults are the author's school):
#   AUTH_HOST=192.168.99.2 NAS_NAME=GKDX PROTOCOL=gportal \
#   AES_KEY=1234567887654321 INTERFACE=eth1 INTERVAL=60 \
#   USERNAME=... PASSWORD=... sh bootstrap-stack.sh
# Existing non-empty credentials are kept on reruns unless FORCE_CREDS=1.
#
# Offline fallback: put pre-downloaded files in /tmp before running:
#   /tmp/campus-auth.ipk /tmp/luci-app-campus-auth.ipk /tmp/ua3f.ipk
# then the script skips the corresponding downloads.

set -u

REPO="Bianka5441/openwrt-campus-suite"
UA3F_REPO="SunBK201/UA3F"
# Keep aligned with the UA3F-unified UA.
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36'

USERNAME=${USERNAME:-}
PASSWORD=${PASSWORD:-}
AUTH_HOST=${AUTH_HOST:-192.168.99.2}
NAS_NAME=${NAS_NAME:-GKDX}
PROTOCOL=${PROTOCOL:-gportal}
AES_KEY=${AES_KEY:-1234567887654321}
INTERFACE=${INTERFACE:-}
INTERVAL=${INTERVAL:-60}

info() { printf '[bootstrap] %s\n' "$*"; }
die() { printf '[bootstrap][ERROR] %s\n' "$*"; exit 1; }

[ "$(id -u)" = "0" ] || die "must run as root"
[ -n "$USERNAME" ] && [ -n "$PASSWORD" ] || die "USERNAME and PASSWORD env are required"

# ---------------------------------------------------------------- detect ---
. /etc/openwrt_release
ARCH="${DISTRIB_ARCH}"
if command -v opkg >/dev/null 2>&1; then
	PKGMGR=opkg
else
	PKGMGR=apk
fi
FW4=0
[ -x /usr/sbin/fw4 ] && FW4=1
WAN_IF="$INTERFACE"
if [ -z "$WAN_IF" ]; then
	WAN_IF=$(ip -4 route get "$AUTH_HOST" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
fi
info "arch=$ARCH pkgmgr=$PKGMGR firewall=$([ "$FW4" = 1 ] && echo fw4/nft || echo fw3/iptables) wan_if=${WAN_IF:-auto}"

# Chicken-and-egg guard: a freshly flashed router behind a campus portal has
# no internet until SOMEONE authenticates - and portal sessions are per-IP,
# so a manual login from any LAN device unlocks the router too.
STAGED=0
for f in /tmp/campus-auth.ipk /tmp/campus-auth.apk /tmp/luci-app-campus-auth.ipk /tmp/luci-app-campus-auth.apk /tmp/ua3f.ipk /tmp/ua3f.apk; do
	[ -s "$f" ] && STAGED=$((STAGED + 1))
done
if [ "$STAGED" -lt 2 ] && ! curl -s -o /dev/null -m 8 --http1.1 https://github.com; then
	cat <<WARN

[bootstrap][BLOCKED] 这台路由器当前无法访问互联网（全新机器尚未通过门户认证）。
两条路任选其一：
  A. 用局域网任意设备浏览器手动登录一次校园网门户（会话按 IP 生效，
     路由器随之有网），然后重新运行本脚本；
  B. 离线预置：在一台有网的电脑上从 GitHub Releases 下载
     campus-auth / luci-app-campus-auth（ipk 或 apk）与对应架构的 UA3F 包，
     scp 到路由器 /tmp/ 并改名为 campus-auth.ipk、luci-app-campus-auth.ipk、
     ua3f.ipk，再重新运行本脚本（将完全离线安装）。
OpenClash 本体同样需要预先安装（脚本只负责配置）。

WARN
	exit 1
fi

# ------------------------------------------------------- 1. campus-auth ---
info "1/5 installing campus-auth from the GitHub release"
EXT=ipk; [ "$PKGMGR" = apk ] && EXT=apk
CA_IPK="/tmp/campus-auth.$EXT"
LUCI_IPK="/tmp/luci-app-campus-auth.$EXT"
if [ "$PKGMGR" = opkg ]; then
	CA_PAT='/campus-auth_[0-9.]*-r[0-9]*_all\.ipk'
	LUCI_PAT='/luci-app-campus-auth_[0-9.]*-r[0-9]*_all\.ipk'
else
	CA_PAT='/campus-auth-[0-9.]*-r[0-9]*\.apk'
	LUCI_PAT='/luci-app-campus-auth-[0-9.]*-r[0-9]*\.apk'
fi

scrape_asset() {
	# $1 = asset grep pattern; echoes a full https URL or an absolute path.
	# Prefer the GitHub API, fall back to scraping the release page
	# (assets are hidden behind the expanded_assets fragment there).
	JSON=$(curl -s "https://api.github.com/repos/$REPO/releases/latest")
	HREF=$(printf '%s' "$JSON" | tr -d ' \t' |
		grep -o '"browser_download_url":"[^"]*"' | cut -d'"' -f4 |
		grep "$1" | head -1)
	[ -n "$HREF" ] && { printf '%s' "$HREF"; return 0; }
	sleep 2
	TAG=$(curl -sL "https://github.com/$REPO/releases/latest" |
		grep -o "releases/expanded_assets/v[0-9.]*" | head -1 | sed "s|.*/||")
	[ -n "$TAG" ] || return 1
	sleep 1
	HREF=$(curl -sL "https://github.com/$REPO/releases/expanded_assets/$TAG" |
		grep -o "\"[^\"]*releases/download/$TAG/[^\"]*\"" | tr -d '"' |
		grep "$1" | head -1)
	[ -n "$HREF" ] || return 1
	case "$HREF" in
		https*) printf '%s' "$HREF";;
		/*) printf 'https://github.com%s' "$HREF";;
		*) printf 'https://github.com/%s' "$HREF";;
	esac
}

if [ ! -s "$CA_IPK" ]; then
	CA_URL=$(scrape_asset "$CA_PAT") || true
	LUCI_URL=$(scrape_asset "$LUCI_PAT") || true
	if [ -z "${CA_URL:-}" ] || [ -z "${LUCI_URL:-}" ]; then
		die "cannot resolve release assets; download them manually to /tmp/campus-auth.ipk / /tmp/luci-app-campus-auth.ipk and rerun"
	fi
	n=1
	while [ "$n" -le 3 ]; do
		curl -fsSL --http1.1 -o "$CA_IPK" "$CA_URL" && break
		sleep 2; n=$((n + 1))
	done
	[ -s "$CA_IPK" ] || die "download failed: $CA_URL"
	n=1
	while [ "$n" -le 3 ]; do
		curl -fsSL --http1.1 -o "$LUCI_IPK" "$LUCI_URL" && break
		sleep 2; n=$((n + 1))
	done
	[ -s "$LUCI_IPK" ] || die "download failed: $LUCI_URL"
	info "downloaded release assets"
fi
if [ "$PKGMGR" = opkg ]; then
	opkg install "$CA_IPK" && opkg install "$LUCI_IPK" || die "opkg install failed"
else
	apk add --allow-untrusted "$CA_IPK" "$LUCI_IPK" || die "apk add failed"
fi

info "writing UCI config (credentials are not echoed)"
# Never clobber working credentials on an already-configured router:
# a rerun must not replace a known-good password with the env value
# (or a placeholder). FORCE_CREDS=1 overrides this guard.
EXISTING_U=$(uci -q get campus-auth.config.username)
EXISTING_P=$(uci -q get campus-auth.config.password)
if [ -n "${FORCE_CREDS:-}" ] || [ -z "$EXISTING_U" ] || [ -z "$EXISTING_P" ]; then
	uci set campus-auth.config.username="$USERNAME"
	uci set campus-auth.config.password="$PASSWORD"
	info "credentials written${FORCE_CREDS:+ (forced)}"
else
	info "credentials already configured - keeping them (FORCE_CREDS=1 to overwrite)"
fi
uci set campus-auth.config.protocol="$PROTOCOL"
uci set campus-auth.config.aes_key="$AES_KEY"
uci set campus-auth.config.auth_host="$AUTH_HOST"
uci set campus-auth.config.nas_name="$NAS_NAME"
uci set campus-auth.config.interval="$INTERVAL"
uci set campus-auth.config.interface="${INTERFACE}"
uci commit campus-auth
chmod 600 /etc/config/campus-auth

# ------------------------------------------------------------- 2. UA3F ---
info "2/5 installing UA3F (arch: $ARCH)"
if netstat -ln | grep -q ':1080 '; then
	info "UA3F already listening on 1080 - keeping the running installation"
else
	UA3F_PKG="/tmp/ua3f.$EXT"
	if ! opkg list-installed 2>/dev/null | grep -q '^ua3f '; then
		if [ ! -s "$UA3F_PKG" ]; then
			info "resolving the latest UA3F release asset for $ARCH ..."
			UA3F_URL=$(curl -s "https://api.github.com/repos/$UA3F_REPO/releases/latest" |
				tr -d ' \t' |
				grep -o '"browser_download_url":"[^"]*"' | cut -d'"' -f4 |
				grep "ua3f.*${ARCH}\.${EXT}\$" | head -1)
			if [ -z "$UA3F_URL" ]; then
				info "!! cannot auto-resolve UA3F for $ARCH."
				info "!! download the matching package from https://github.com/$UA3F_REPO/releases"
				info "!! to /tmp/ua3f.ipk (or /tmp/ua3f.apk) and rerun; skipping UA3F for now."
			else
				n=1
				while [ "$n" -le 3 ]; do
					curl -fsSL --http1.1 -o "$UA3F_PKG" "$UA3F_URL" && break
					sleep 2; n=$((n + 1))
				done
				[ -s "$UA3F_PKG" ] || die "UA3F download failed"
			fi
		fi
		if [ -s "$UA3F_PKG" ]; then
			if [ "$PKGMGR" = opkg ]; then
				opkg install "$UA3F_PKG" || {
					info "dependency resolution failed, retrying with --force-depends (SOCKS5 mode needs no nfqueue)"
					opkg install --force-depends "$UA3F_PKG" || die "UA3F install failed"
				}
			else
				apk add --allow-untrusted "$UA3F_PKG" || die "UA3F apk add failed"
			fi
		fi
	fi
	[ -x /etc/init.d/ua3f ] && {
		/etc/init.d/ua3f enable 2>/dev/null
		/etc/init.d/ua3f restart 2>/dev/null || /etc/init.d/ua3f start
		sleep 2
	}
fi
if [ -x /etc/init.d/ua3f ] || [ -f /etc/config/ua3f ]; then
	cat > /etc/config/ua3f <<UAF
config ua3f 'enabled'
	option enabled '1'

config ua3f 'main'
	option server_mode 'SOCKS5'
	option port '1080'
	option bind '127.0.0.1'
	option ua '$UA'
	option rewrite_mode 'GLOBAL'
	option log_level 'WARN'
UAF
	/etc/init.d/ua3f enable 2>/dev/null
	/etc/init.d/ua3f restart 2>/dev/null || /etc/init.d/ua3f start
	sleep 2
	netstat -ln | grep -q ':1080 ' || die "UA3F is not listening on 1080 - fix it before starting OpenClash"
	info "UA3F listening on 127.0.0.1:1080, unified UA = Chrome/133 (Windows NT 10.0; Win64; x64)"
else
	info "!! UA3F not available on this router; UA unification disabled (check School detection may see multiple UAs)"
fi

# -------------------------------------------------------- 3. OpenClash ---
info "3/5 configuring OpenClash"
if [ -x /etc/init.d/openclash ]; then
	mkdir -p /etc/openclash/config
	cat > /etc/openclash/config/openclash-ua3f.yaml <<YML
mixed-port: 7890
ipv6: false
mode: rule
dns:
  enable: true
  listen: 0.0.0.0:7874
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - '*.lan'
    - '+.local'
  default-nameserver:
    - 223.5.5.5
    - 119.29.29.29
  nameserver:
    - https://223.5.5.5/dns-query
    - https://doh.pub/dns-query
proxies:
  - name: "ua3f"
    type: socks5
    server: 127.0.0.1
    port: 1080
    url: http://connectivitycheck.platform.hicloud.com/generate_204
    udp: false
rules:
  - PROCESS-NAME,ua3f,DIRECT
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,100.64.0.0/10,DIRECT,no-resolve
  - NETWORK,udp,DIRECT
  - DST-PORT,80,ua3f
  - MATCH,DIRECT
YML
	uci set openclash.config.enable='1'
	uci set openclash.config.config_path='/etc/openclash/config/openclash-ua3f.yaml'
	uci commit openclash
	/etc/init.d/openclash restart
	sleep 20
	ps | grep -q '[c]lash' && info "OpenClash running (80 -> ua3f, rest DIRECT)" || info "!! OpenClash did not start: check logread | grep -i clash"
else
	info "!! OpenClash not installed - install luci-app-openclash, then rerun this script"
fi

# ------------------------------------------------ 4. detect hardening ---
info "4/5 applying TTL / NTP / DNS hardening (WAN: $WAN_IF)"
uci set system.ntp.enable_server='1'
uci commit system
/etc/init.d/sysntpd restart 2>/dev/null

if [ "$FW4" = 1 ]; then
	mkdir -p /etc/nftables.d
	cat > /etc/nftables.d/campus-detect.nft <<NFT
chain campus_detect_postrouting {
	type filter hook postrouting priority mangle; policy accept;
	oifname "$WAN_IF" counter ttl set 64
}
chain campus_detect_prerouting {
	type nat hook prerouting priority dstnat - 5; policy accept;
	iifname != "lo" udp dport 123 counter redirect to :123
	iifname != "lo" udp dport 53 counter redirect to :53
	iifname != "lo" tcp dport 53 counter redirect to :53
}
NFT
	/etc/init.d/firewall reload 2>/dev/null || /etc/init.d/firewall restart
	info "fw4 drop-in written: /etc/nftables.d/campus-detect.nft"
else
	MARK_B="# >>> campus-auth-stack >>>"
	MARK_E="# <<< campus-auth-stack <<<"
	sed -i "/^$MARK_B\$/,/^$MARK_E\$/d" /etc/firewall.user 2>/dev/null
	cat >> /etc/firewall.user <<FWU
$MARK_B
iptables -t mangle -A POSTROUTING -o $WAN_IF -j TTL --ttl-set 64
ip6tables -t mangle -A POSTROUTING -o $WAN_IF -j HL --hl-set 64 2>/dev/null
iptables -t nat -A PREROUTING -p udp --dport 123 -j REDIRECT --to-ports 123
iptables -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 53
iptables -t nat -A PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 53
$MARK_E
FWU
	iptables -t mangle -C POSTROUTING -o "$WAN_IF" -j TTL --ttl-set 64 2>/dev/null ||
		iptables -t mangle -A POSTROUTING -o "$WAN_IF" -j TTL --ttl-set 64
	iptables -t nat -C PREROUTING -p udp --dport 123 -j REDIRECT --to-ports 123 2>/dev/null ||
		iptables -t nat -A PREROUTING -p udp --dport 123 -j REDIRECT --to-ports 123
	iptables -t nat -C PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null ||
		iptables -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 53
	iptables -t nat -C PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null ||
		iptables -t nat -A PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 53
	info "fw3 rules applied and persisted to /etc/firewall.user"
fi

# ----------------------------------------------------- 5. auth service ---
info "5/5 starting campus-auth"
/etc/init.d/campus-auth enable
/etc/init.d/campus-auth restart
sleep 2
pgrep -f campus-auth-loop >/dev/null && info "campus-auth loop running" || die "campus-auth loop failed to start"
/etc/init.d/rpcd restart 2>/dev/null

# ---------------------------------------------------------- 6. verify ---
info "=== verification ==="
/usr/bin/campus-auth --check
rc=$?
case $rc in
	0) info "portal: ONLINE";;
	1) info "portal: OFFLINE (first login will happen automatically after two checks)";;
	*) info "portal: UNKNOWN (check AUTH_HOST reachability on $WAN_IF)";;
esac
netstat -ln | grep -q ':1080 ' && info "ua3f: 1080 OK" || info "ua3f: NOT listening"
info "done. LuCI: Services -> Campus Auth. Log: /var/log/campus-auth.log"
info "IPv6 note: if the campus hands out IPv6, disable LAN RA/DHCPv6 - every device gets its own global v6 otherwise."
