#!/bin/sh
# campus-auth - automatic authentication for gportal-based campus network
# portals. Reproduces the browser login flow: fetch the login page, extract
# the per-session sign/iv fields, AES-128-CBC encrypt the request payload
# (ZeroPadding) and POST it to /gportal/web/authLogin.
#
# Usage:
#   campus-auth          attempt one login (exit 0 success / non-zero failure)
#   campus-auth --check  query portal auth state only
#                        exit 0 online (authState:2), 1 offline (authState:1),
#                        2 request/parse error or unexpected response
#
# A "reasoncode:55" login response means the portal ordered proxy/sharing to
# be disabled for 15 minutes. The marker file /etc/campus-auth.reason55 is
# created and the loop daemon makes no login attempt while it exists; the
# marker must be removed before the next manual retry.
#
# Configuration lives in /etc/config/campus-auth (UCI).

LOG=/var/log/campus-auth.log
STATE=/tmp/campus-auth.state
MARKER=/etc/campus-auth.reason55
# Keep the UA aligned with the UA unified by UA3F on the same network.
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36'

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

write_state() {
	{
		printf 'time=%s\n' "$(date '+%F %T')"
		printf 'result=%s\n' "$1"
		printf 'message=%s\n' "$2"
		printf 'user_ip=%s\n' "${USER_IP:-}"
	} > "$STATE"
}

. /lib/functions.sh
config_load campus-auth

config_get USERNAME  config username  ''
config_get PASSWORD  config password  ''
config_get INTERFACE config interface ''
config_get AUTH_HOST config auth_host '192.168.99.2'
config_get NAS_NAME  config nas_name  'GKDX'

TMP=/tmp/campus-auth.$$
trap 'rm -f "$TMP".*' EXIT INT TERM

MODE="$1"

# While the reason55 cooldown marker exists, no login attempt is made;
# state checks (--check) are still allowed.
[ "$MODE" != "--check" ] && [ -e "$MARKER" ] && exit 55

if [ "$MODE" != "--check" ]; then
	[ -n "$USERNAME" ] && [ -n "$PASSWORD" ] || {
		log 'username/password not configured'
		write_state failed 'username/password not configured'
		exit 1
	}
fi

# Bind the requests to the campus uplink only when the user pinned one.
CURL_IF=
if [ -n "$INTERFACE" ]; then
	CURL_IF="--interface $INTERFACE"
	USER_IP=$(ip -4 -o addr show dev "$INTERFACE" | awk '{sub(/\/.*/,"",$4); print $4; exit}')
else
	USER_IP=$(ip -4 route get "$AUTH_HOST" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
fi
[ -n "$USER_IP" ] || {
	if [ "$MODE" = "--check" ]; then
		exit 2
	fi
	log 'cannot determine campus IP'
	write_state failed 'cannot determine campus IP'
	exit 1
}

LOGIN_URL="http://${AUTH_HOST}/gportal/web/login?wlanuserip=${USER_IP}&wlanacname=${NAS_NAME}"

if curl -fsS --noproxy '*' $CURL_IF \
	-A "$UA" \
	-H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' \
	-H 'Accept-Language: zh-CN,zh;q=0.9' \
	-H 'Cache-Control: max-age=0' \
	-H 'Upgrade-Insecure-Requests: 1' \
	--cookie-jar "$TMP.cookie" --connect-timeout 5 --max-time 15 \
	"$LOGIN_URL" -o "$TMP.html"; then
	:
else
	[ "$MODE" = "--check" ] || { log 'cannot fetch login page'; write_state failed 'cannot fetch login page'; }
	exit 2
fi

field() { sed -n "s/.*name=\"$1\"[^>]*value=\"\([^\"]*\)\".*/\1/p" "$TMP.html" | head -n 1; }
SIGN=$(field sign)

# Percent-encode like jQuery $.param(): keep [A-Za-z0-9._~-] literal,
# encode space as %20 and every other byte as %XX.
urlencode() {
	printf '%s' "$1" | awk '
		BEGIN {
			for (i = 1; i <= 255; i++)
				ord[sprintf("%c", i)] = i
		}
		{
			s = $0
			for (i = 1; i <= length(s); i++) {
				c = substr(s, i, 1)
				if (c ~ /[A-Za-z0-9._~-]/)
					printf "%s", c
				else if (c == " ")
					printf "%%20"
				else
					printf "%%%02X", ord[c]
			}
		}'
}

# The state query only needs a fresh sign; the login flow additionally
# needs the 16-character session IV.
if [ "$MODE" = "--check" ]; then
	[ -n "$SIGN" ] || exit 2

	STATUS_RESPONSE=$(curl -fsS --noproxy '*' $CURL_IF \
		-A "$UA" \
		-H 'Accept: application/json, text/javascript, */*; q=0.01' \
		-H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
		-H 'X-Requested-With: XMLHttpRequest' \
		-H "Origin: http://${AUTH_HOST}" \
		-H "Referer: ${LOGIN_URL}" \
		--cookie "$TMP.cookie" \
		--data "userIp=$(urlencode "$USER_IP")&sign=$(urlencode "$SIGN")" \
		"http://${AUTH_HOST}/gportal/web/queryAuthState") || exit 2

	case "$STATUS_RESPONSE" in
		*'"authState":2'*) exit 0;;
		*'"authState":1'*) exit 1;;
		*) exit 2;;
	esac
fi

IV=$(field iv)
REDIRECT=$(field redirectUrl)
TEMPLATE=$(field portalTemplateId)
PID=$(field pid)
VLAN=$(field vlan)
[ -n "$SIGN" ] && [ "${#IV}" -eq 16 ] || {
	log 'login page missing sign/iv'
	write_state failed 'login page missing sign/iv'
	exit 2
}

FORM="nasName=$(urlencode "$NAS_NAME")&nasIp=&userIp=$(urlencode "$USER_IP")&userMac=&ssid=&apMac=&pid=$(urlencode "$PID")&vlan=$(urlencode "$VLAN")&sign=$(urlencode "$SIGN")&iv=$(urlencode "$IV")&redirectUrl=$(urlencode "$REDIRECT")&portalTemplateId=$(urlencode "$TEMPLATE")&show_type=0&account_type=&name=$(urlencode "$USERNAME")&password=$(urlencode "$PASSWORD")"

printf '%s' "$FORM" > "$TMP.plain"
LEN=$(wc -c < "$TMP.plain")
PAD=$((16 - LEN % 16))
dd if=/dev/zero bs=1 count="$PAD" >> "$TMP.plain" 2>/dev/null

# AES-128-CBC with key "1234567887654321" (hex encoded) and the session IV.
KEY='31323334353637383837363534333231'
IV_HEX=
i=1
while [ "$i" -le 16 ]; do
	c=$(printf '%s' "$IV" | cut -c "$i" | tr 'A-F' 'a-f')
	case "$c" in
		0) IV_HEX="${IV_HEX}30";; 1) IV_HEX="${IV_HEX}31";;
		2) IV_HEX="${IV_HEX}32";; 3) IV_HEX="${IV_HEX}33";;
		4) IV_HEX="${IV_HEX}34";; 5) IV_HEX="${IV_HEX}35";;
		6) IV_HEX="${IV_HEX}36";; 7) IV_HEX="${IV_HEX}37";;
		8) IV_HEX="${IV_HEX}38";; 9) IV_HEX="${IV_HEX}39";;
		a) IV_HEX="${IV_HEX}61";; b) IV_HEX="${IV_HEX}62";;
		c) IV_HEX="${IV_HEX}63";; d) IV_HEX="${IV_HEX}64";;
		e) IV_HEX="${IV_HEX}65";; f) IV_HEX="${IV_HEX}66";;
		*) log 'invalid IV'; write_state failed 'invalid IV'; exit 2;;
	esac
	i=$((i + 1))
done

openssl enc -aes-128-cbc -K "$KEY" -iv "$IV_HEX" -nopad -in "$TMP.plain" -a -A -out "$TMP.data" || {
	log 'AES encryption failed'; write_state failed 'AES encryption failed'; exit 1
}
DATA=$(sed 's/+/%2B/g; s|/|%2F|g; s/=/%3D/g' "$TMP.data")

RESPONSE=$(curl -fsS --noproxy '*' $CURL_IF \
	-A "$UA" \
	--connect-timeout 5 --max-time 15 \
	-H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
	-H "Origin: http://${AUTH_HOST}" \
	-H "Referer: ${LOGIN_URL}" \
	--cookie "$TMP.cookie" \
	--data "data=${DATA}&iv=${IV}" \
	"http://${AUTH_HOST}/gportal/web/authLogin?round=$(( $(date +%s) % 1001 ))") || {
	log 'authentication request failed'; write_state failed 'authentication request failed'; exit 1
}

case "$RESPONSE" in
	*'"status":1'*)
		write_state success 'authenticated'
		log "authentication succeeded for ${USERNAME}"
		exit 0
		;;
	*'"reasoncode":55'*)
		date +%s > "$MARKER"
		write_state cooldown 'server requested pause (reason 55)'
		log "authentication paused: server returned reasoncode 55; wait 15 minutes, then remove $MARKER before one manual retry"
		exit 55
		;;
	*)
		MSG=$(printf '%s' "$RESPONSE" | tr '\n' ' ' | cut -c1-240)
		write_state failed "rejected: ${MSG}"
		log "authentication rejected for ${USERNAME}: ${MSG}"
		exit 1
		;;
esac
