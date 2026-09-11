#!/bin/sh
# campus-auth-mode - apply the protection mode selected in UCI/LuCI.
#
# Modes (UCI campus-auth.config.mode):
#   normal      campus authentication only. No UA unification, no
#               multi-device hardening, no proxy.
#   anti-detect auth + UA3F (unified User-Agent) + TTL/NTP/DNS hardening +
#               LAN IPv6 off. For schools that flag multi-device sharing.
#   proxy       anti-detect + OpenClash. The "ladder" itself (subscription,
#               nodes, port-80-to-UA3F rule) stays under OpenClash's own
#               management; this only makes sure the service runs.
#
# Called by /etc/init.d/campus-auth on start/restart (and therefore at
# boot). Safe to re-run: every step is a no-op when the system already
# matches the mode. Missing components degrade gracefully with a log line.

LOG=/var/log/campus-auth.log
FW_USER=/etc/firewall.user
MARK_BEGIN='# >>> campus-auth hardening >>>'
MARK_END='# <<< campus-auth hardening <<<'
UA3F_PORT=1080
OPENCLASH_TEMPLATE=/usr/share/campus-auth/openclash-ua3f.yaml
OPENCLASH_CONFIG_DIR=/etc/openclash/config

log() { printf '%s %s\n' "$(date '+%F %T')" "mode: $*" >> "$LOG"; }

have_init() { [ -x "/etc/init.d/$1" ]; }

ua3f_listening() { netstat -ltn 2>/dev/null | grep -q ":$UA3F_PORT "; }

openclash_running() { pgrep -f openclash >/dev/null 2>&1; }

. /lib/functions.sh
config_load campus-auth
config_get MODE config mode 'normal'
config_get INTERFACE config interface ''
config_get AUTH_HOST config auth_host '192.168.99.2'

case "$MODE" in
	normal|anti-detect|proxy) ;;
	*) log "unknown mode '$MODE', falling back to normal"; MODE=normal ;;
esac

wan_if() {
	if [ -n "$INTERFACE" ]; then
		echo "$INTERFACE"
	else
		ip -4 route get "$AUTH_HOST" 2>/dev/null | grep -o 'dev [^ ]* ' | awk '{print $2; exit}'
	fi
}

hardening_rules() {
	local wan="$1"
	cat <<EOF
$MARK_BEGIN
# TTL unification: every packet leaving the campus uplink shows TTL 64
iptables -t mangle -A POSTROUTING -o $wan -j TTL --ttl-set 64
ip6tables -t mangle -A POSTROUTING -o $wan -j HL --hl-set 64 2>/dev/null
# NTP: all clients sync through the router (clock-skew defence)
iptables -t nat -A PREROUTING -p udp --dport 123 -j REDIRECT --to-ports 123
# DNS: force every client through router dnsmasq (external-DNS defence)
iptables -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 53
iptables -t nat -A PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 53
$MARK_END
EOF
}

# Delete hardening lines from firewall.user: our marked block plus any
# legacy unmarked copies left by earlier manual provisioning.
fw_clean() {
	[ -f "$FW_USER" ] || return 0
	sed -i -e "/^${MARK_BEGIN}$/,/^${MARK_END}$/d" \
		-e '/--ttl-set 64/d' \
		-e '/--hl-set 64/d' \
		-e '/--dport 123 -j REDIRECT --to-ports 123/d' \
		-e '/--dport 53 -j REDIRECT --to-ports 53/d' "$FW_USER"
}

live_rules_present() {
	iptables -t mangle -S POSTROUTING 2>/dev/null | grep -q 'TTL --ttl-set 64' \
		|| iptables -t nat -S PREROUTING 2>/dev/null | grep -q 'dport 123'
}

delete_live_rules() {
	local wan
	wan="$(wan_if)"
	[ -n "$wan" ] || return 0
	iptables -t mangle -D POSTROUTING -o "$wan" -j TTL --ttl-set 64 2>/dev/null
	ip6tables -t mangle -D POSTROUTING -o "$wan" -j HL --hl-set 64 2>/dev/null
	iptables -t nat -D PREROUTING -p udp --dport 123 -j REDIRECT --to-ports 123 2>/dev/null
	iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null
	iptables -t nat -D PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null
}

apply_hardening() {
	local wan
	wan="$(wan_if)"
	if [ -z "$wan" ]; then
		log 'campus uplink not found; hardening skipped'
		return 1
	fi
	if grep -q "^${MARK_BEGIN}$" "$FW_USER" 2>/dev/null \
		&& grep -q -- "-o $wan -j TTL" "$FW_USER" 2>/dev/null; then
		return 0
	fi
	fw_clean
	hardening_rules "$wan" >> "$FW_USER"
	uci set system.ntp.enable_server='1'
	uci commit system
	/etc/init.d/sysntpd restart 2>/dev/null
	/etc/init.d/firewall restart 2>/dev/null
	log "hardening applied on $wan (TTL 64, NTP/DNS redirect)"
}

# The campus uplink often comes up AFTER the mode switch (cable plugged in
# later, campus DHCP slow). Retry in the background instead of skipping
# until the next mode change - skipped hardening is invisible to the user
# and defeats the whole mode.
hardening_wait_bg() {
	(
		i=0
		while [ "$i" -lt 60 ]; do
			sleep 10
			# stay quiet while the uplink is still absent (already logged once)
			[ -n "$(wan_if)" ] || { i=$((i + 1)); continue; }
			apply_hardening && exit 0
			i=$((i + 1))
		done
		log 'uplink still absent after 10 minutes; hardening NOT applied - plug the campus cable and re-apply the mode'
	) >/dev/null 2>&1 &
}

ua3f_start_logged() {
	if have_init ua3f; then
		if ua3f_listening; then
			return 0
		fi
		svc_up ua3f 1
		sleep 2
		if ua3f_listening; then
			log 'ua3f started (unified User-Agent)'
		else
			log 'ua3f FAILED to start - UA unification is OFF; check syslog and /usr/bin/ua3f'
		fi
	else
		log 'ua3f not installed; UA unification unavailable, install it for full anti-detection'
	fi
}

remove_hardening() {
	if ! grep -q "^${MARK_BEGIN}$" "$FW_USER" 2>/dev/null && ! live_rules_present; then
		return 0
	fi
	fw_clean
	delete_live_rules
	/etc/init.d/firewall restart 2>/dev/null
	log 'hardening removed'
}

ipv6_off() {
	[ "$(uci -q get dhcp.lan.ra)" = 'disabled' ] \
		&& [ "$(uci -q get dhcp.lan.dhcpv6)" = 'disabled' ] && return 0
	uci set dhcp.lan.ra='disabled'
	uci set dhcp.lan.dhcpv6='disabled'
	uci commit dhcp
	/etc/init.d/odhcpd restart 2>/dev/null
	log 'LAN IPv6 RA/DHCPv6 disabled'
}

ipv6_restore() {
	[ "$(uci -q get dhcp.lan.ra)" = 'server' ] \
		&& [ "$(uci -q get dhcp.lan.dhcpv6)" = 'server' ] && return 0
	uci set dhcp.lan.ra='server'
	uci set dhcp.lan.dhcpv6='server'
	uci commit dhcp
	/etc/init.d/odhcpd restart 2>/dev/null
	log 'LAN IPv6 RA/DHCPv6 restored'
}

svc_up() { # <name> <up-wanted>
	if [ "$2" = 1 ]; then
		/etc/init.d/"$1" enable 2>/dev/null
		/etc/init.d/"$1" start 2>/dev/null
	else
		/etc/init.d/"$1" disable 2>/dev/null
		/etc/init.d/"$1" stop 2>/dev/null
	fi
}

case "$MODE" in
	normal)
		if have_init ua3f && ua3f_listening; then
			svc_up ua3f 0
			log 'ua3f stopped'
		fi
		have_init ua3f && /etc/init.d/ua3f disable 2>/dev/null
		if have_init openclash && openclash_running; then
			svc_up openclash 0
			log 'openclash stopped'
		fi
		have_init openclash && /etc/init.d/openclash disable 2>/dev/null
		remove_hardening
		ipv6_restore
		;;
	anti-detect|proxy)
		# Both protection modes bring up the full stack: UA3F + OpenClash
		# (when installed) + hardening. proxy mode additionally drops the
		# UA3F redirect template for OpenClash's own config management.
		ua3f_start_logged
		if have_init openclash; then
			if openclash_running; then
				:
			else
				svc_up openclash 1
				sleep 2
				if openclash_running; then
					log 'openclash started'
				else
					log 'openclash FAILED to start (no subscription/config? start it once from its own LuCI page)'
				fi
			fi
			if [ -f "$OPENCLASH_TEMPLATE" ] && [ -d "$OPENCLASH_CONFIG_DIR" ] \
				&& [ ! -f "$OPENCLASH_CONFIG_DIR/openclash-ua3f.yaml" ]; then
				cp "$OPENCLASH_TEMPLATE" "$OPENCLASH_CONFIG_DIR/openclash-ua3f.yaml"
				log 'installed openclash-ua3f.yaml template into /etc/openclash/config/'
			fi
		else
			log 'openclash not installed; only UA3F + hardening protect this mode'
		fi
		apply_hardening || hardening_wait_bg
		ipv6_off
		;;
esac

log "mode '$MODE' applied"
