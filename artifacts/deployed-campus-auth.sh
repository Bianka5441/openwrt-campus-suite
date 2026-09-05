#!/bin/sh

CONFIG=${CONFIG:-/etc/campus-auth.conf}
LOG=${LOG:-/var/log/campus-auth.log}
PAUSE_FILE=${PAUSE_FILE:-/etc/campus-auth.reason55}
[ -r "$CONFIG" ] || { echo "missing $CONFIG" >&2; exit 2; }
. "$CONFIG"

AUTH_HOST=${AUTH_HOST:-192.168.99.2}
NAS_NAME=${NAS_NAME:-GKDX}
AUTH_INTERFACE=${INTERFACE:-eth1}
TMP=${TMPDIR:-/tmp}/campus-auth.$$ 
trap 'rm -f "$TMP".*' EXIT INT TERM

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

# A reasoncode:55 response requires a manual retry after the server's cooldown.
[ "$1" != "--check" ] && [ -e "$PAUSE_FILE" ] && exit 55

if [ -n "$INTERFACE" ]; then
    USER_IP=$(ip -4 -o addr show dev "$INTERFACE" | awk '{sub(/\/.*/,"",$4); print $4; exit}')
else
    USER_IP=$(ip -4 route get 192.168.99.2 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
fi
[ -n "$USER_IP" ] || { log 'cannot determine campus IP'; exit 1; }

LOGIN_URL="http://${AUTH_HOST}/gportal/web/login?wlanuserip=${USER_IP}&wlanacname=${NAS_NAME}"
if curl -fsS --noproxy '*' --interface "$AUTH_INTERFACE" \
    -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/152 Safari/537.36' \
    -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' \
    -H 'Accept-Language: zh-CN,zh;q=0.9' \
    -H 'Cache-Control: max-age=0' \
    -H 'Upgrade-Insecure-Requests: 1' \
    --cookie-jar "$TMP.cookie" --connect-timeout 5 --max-time 15 \
    "$LOGIN_URL" -o "$TMP.html"; then
    :
else
    [ "$1" = "--check" ] || log 'cannot fetch login page'
    exit 2
fi

field() { sed -n "s/.*name=\"$1\"[^>]*value=\"\([^\"]*\)\".*/\1/p" "$TMP.html" | head -n 1; }
SIGN=$(field sign)
IV=$(field iv)
REDIRECT=$(field redirectUrl)
TEMPLATE=$(field portalTemplateId)
PID=$(field pid)
VLAN=$(field vlan)
[ -n "$SIGN" ] && [ "${#IV}" -eq 16 ] || {
    [ "$1" = "--check" ] || log 'login page missing sign/iv'
    exit 2
}

# Match jQuery's encoding for the ASCII values used by this portal.
urlencode() {
    printf '%s' "$1" | sed 's/%/%25/g; s/ /%20/g; s/&/%26/g; s/=/\%3D/g; s/+/%2B/g; s|/|%2F|g; s/:/%3A/g; s/?/%3F/g'
}

if [ "$1" = "--check" ]; then
    STATUS_FORM="userIp=$(urlencode "$USER_IP")&sign=$(urlencode "$SIGN")"
    STATUS_RESPONSE=$(curl -fsS --noproxy '*' --interface "$AUTH_INTERFACE" \
        -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/152 Safari/537.36' \
        -H 'Accept: application/json, text/javascript, */*; q=0.01' \
        -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
        -H 'X-Requested-With: XMLHttpRequest' \
        -H "Origin: http://${AUTH_HOST}" \
        -H "Referer: ${LOGIN_URL}" \
        --cookie "$TMP.cookie" \
        --data "$STATUS_FORM" \
        "http://${AUTH_HOST}/gportal/web/queryAuthState") || exit 2

    case "$STATUS_RESPONSE" in
        *'"authState":2'*) exit 0;;
        *'"authState":1'*) exit 1;;
        *) exit 2;;
    esac
fi

FORM="nasName=$(urlencode "$NAS_NAME")&nasIp=&userIp=$(urlencode "$USER_IP")&userMac=&ssid=&apMac=&pid=$(urlencode "$PID")&vlan=$(urlencode "$VLAN")&sign=$(urlencode "$SIGN")&iv=$(urlencode "$IV")&redirectUrl=$(urlencode "$REDIRECT")&portalTemplateId=$(urlencode "$TEMPLATE")&show_type=0&account_type=&name=$(urlencode "$USERNAME")&password=$(urlencode "$PASSWORD")"

printf '%s' "$FORM" > "$TMP.plain"
LEN=$(wc -c < "$TMP.plain")
PAD=$((16 - LEN % 16))
dd if=/dev/zero bs=1 count="$PAD" >> "$TMP.plain" 2>/dev/null
KEY='31323334353637383837363534333231'
IV_HEX=
i=1
while [ "$i" -le 16 ]; do
    c=$(printf '%s' "$IV" | cut -c "$i")
    case "$c" in
        0) IV_HEX="${IV_HEX}30";; 1) IV_HEX="${IV_HEX}31";;
        2) IV_HEX="${IV_HEX}32";; 3) IV_HEX="${IV_HEX}33";;
        4) IV_HEX="${IV_HEX}34";; 5) IV_HEX="${IV_HEX}35";;
        6) IV_HEX="${IV_HEX}36";; 7) IV_HEX="${IV_HEX}37";;
        8) IV_HEX="${IV_HEX}38";; 9) IV_HEX="${IV_HEX}39";;
        a) IV_HEX="${IV_HEX}61";; b) IV_HEX="${IV_HEX}62";;
        c) IV_HEX="${IV_HEX}63";; d) IV_HEX="${IV_HEX}64";;
        e) IV_HEX="${IV_HEX}65";; f) IV_HEX="${IV_HEX}66";;
        *) log 'invalid IV'; exit 1;;
    esac
    i=$((i + 1))
done
openssl enc -aes-128-cbc -K "$KEY" -iv "$IV_HEX" -nopad -in "$TMP.plain" -a -A -out "$TMP.data" || {
    log 'AES encryption failed'; exit 1
}
DATA=$(sed 's/+/%2B/g; s|/|%2F|g; s/=/%3D/g' "$TMP.data")

RESPONSE=$(curl -fsS --noproxy '*' --connect-timeout 5 --max-time 15 \
    -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/152 Safari/537.36' \
    --interface "$AUTH_INTERFACE" \
    -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
    -H "Origin: http://${AUTH_HOST}" \
    -H "Referer: ${LOGIN_URL}" \
    --cookie "$TMP.cookie" \
    --data "data=${DATA}&iv=${IV}" \
    "http://${AUTH_HOST}/gportal/web/authLogin?round=$(( $(date +%s) % 1001 ))") || {
    log 'authentication request failed'; exit 1
}

case "$RESPONSE" in
    *'"status":1'*) log "authentication succeeded for ${USERNAME}"; exit 0;;
    *'"reasoncode":55'*)
        date +%s > "$PAUSE_FILE"
        log "authentication paused: server returned reasoncode 55; wait 15 minutes, then remove $PAUSE_FILE before one manual retry"
        exit 55
        ;;
    *) log "authentication rejected for ${USERNAME}: $(printf '%s' "$RESPONSE" | tr '\n' ' ' | cut -c1-240)"; exit 1;;
esac
