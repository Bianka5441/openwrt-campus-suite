#!/bin/sh
# campus-auth - automatic authentication for gportal-based campus network
# portals. Reproduces the browser login flow: fetch the login page, extract
# the per-session sign/iv fields, AES-128-CBC encrypt the request payload
# (ZeroPadding) and POST it to /gportal/web/authLogin.
#
# Configuration lives in /etc/config/campus-auth (UCI).

LOG=/var/log/campus-auth.log
STATE=/tmp/campus-auth.state
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36'

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

write_state() {
	{
		printf 'time=%s\n' "$(date '+%F %T')"
		printf 'result=%s\n' "$1"
		printf 'message=%s\n' "$2"
		printf 'user_ip=%s\n' "${USER_IP:-}"
	} > "$STATE"
}

fail() {
	log "$1"
	write_state failed "$1"
	exit 1
}

. /lib/functions.sh
config_load campus-auth

config_get USERNAME  config username  ''
config_get PASSWORD  config password  ''
config_get INTERFACE config interface ''
config_get AUTH_HOST config auth_host '192.168.99.2'
config_get NAS_NAME  config nas_name  'GKDX'

[ -n "$USERNAME" ] && [ -n "$PASSWORD" ] || fail 'username/password not configured'

TMP=/tmp/campus-auth.$$
trap 'rm -f "$TMP".*' EXIT INT TERM

# Bind the requests to the campus uplink only when the user pinned one.
CURL_IF=
if [ -n "$INTERFACE" ]; then
	CURL_IF="--interface $INTERFACE"
	USER_IP=$(ip -4 -o addr show dev "$INTERFACE" | awk '{sub(/\/.*/,"",$4); print $4; exit}')
else
	USER_IP=$(ip -4 route get "$AUTH_HOST" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
fi
[ -n "$USER_IP" ] || fail 'cannot determine campus IP'

LOGIN_URL="http://${AUTH_HOST}/gportal/web/login?wlanuserip=${USER_IP}&wlanacname=${NAS_NAME}"

curl -fsS $CURL_IF \
	-A "$UA" \
	-H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' \
	-H 'Accept-Language: zh-CN,zh;q=0.9' \
	-H 'Cache-Control: max-age=0' \
	-H 'Upgrade-Insecure-Requests: 1' \
	--cookie-jar "$TMP.cookie" --connect-timeout 5 --max-time 15 \
	"$LOGIN_URL" -o "$TMP.html" || fail 'cannot fetch login page'

field() { sed -n "s/.*name=\"$1\"[^>]*value=\"\([^\"]*\)\".*/\1/p" "$TMP.html" | head -n 1; }
SIGN=$(field sign)
IV=$(field iv)
REDIRECT=$(field redirectUrl)
TEMPLATE=$(field portalTemplateId)
PID=$(field pid)
VLAN=$(field vlan)
[ -n "$SIGN" ] && [ "${#IV}" -eq 16 ] || fail 'login page missing sign/iv'

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
		*) fail 'invalid IV'
	esac
	i=$((i + 1))
done

openssl enc -aes-128-cbc -K "$KEY" -iv "$IV_HEX" -nopad -in "$TMP.plain" -a -A -out "$TMP.data" || fail 'AES encryption failed'
DATA=$(sed 's/+/%2B/g; s|/|%2F|g; s/=/%3D/g' "$TMP.data")

RESPONSE=$(curl -fsS $CURL_IF \
	-A "$UA" \
	--connect-timeout 5 --max-time 15 \
	-H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
	-H "Origin: http://${AUTH_HOST}" \
	-H "Referer: ${LOGIN_URL}" \
	--cookie "$TMP.cookie" \
	--data "data=${DATA}&iv=${IV}" \
	"http://${AUTH_HOST}/gportal/web/authLogin?round=$(( $(date +%s) % 1001 ))") || fail 'authentication request failed'

case "$RESPONSE" in
	*'"status":1'*)
		write_state success 'authenticated'
		log "authentication succeeded for ${USERNAME}"
		exit 0
		;;
	*)
		MSG=$(printf '%s' "$RESPONSE" | tr '\n' ' ' | cut -c1-240)
		fail "authentication rejected: ${MSG}"
		;;
esac
