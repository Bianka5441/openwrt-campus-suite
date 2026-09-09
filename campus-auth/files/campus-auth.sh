#!/bin/sh
# campus-auth - dispatcher for campus portal authentication protocols.
#
# Usage:
#   campus-auth          attempt one login (exit 0 success / non-zero failure)
#   campus-auth --check  query portal auth state only
#                        exit 0 online, 1 offline, 2 request/parse error
#
# Protocol implementations live in /usr/share/campus-auth/proto/<name>.sh
# (UCI option "protocol", default "gportal") and must define two functions:
#
#   proto_check   exit 0 online / 1 offline / 2 unknown. Silent on failure.
#   proto_login   exit 0 success / 55 portal-ordered cooldown / other = reject.
#                 On reject set REJECT_MSG to a short reason (no secrets).
#
# Helpers available to protocol scripts: log, write_state, urlencode, field
# (field reads "$TMP.html"), plus the environment: MODE, USERNAME, PASSWORD,
# AUTH_HOST, NAS_NAME, AES_KEY, CHECK_URL, INTERFACE, CURL_IF, USER_IP, TMP, UA.
#
# A "portal-ordered cooldown" (exit 55, e.g. gportal reasoncode:55) creates
# the marker /etc/campus-auth.reason55; the loop daemon and the LuCI button
# refuse to login while it exists.

LOG=/var/log/campus-auth.log
STATE=/tmp/campus-auth.state
MARKER=/etc/campus-auth.reason55
PAUSE=/etc/campus-auth.pause
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

field() { sed -n "s/.*name=\"$1\"[^>]*value=\"\([^\"]*\)\".*/\1/p" "$TMP.html" | head -n 1; }

. /lib/functions.sh
config_load campus-auth

config_get USERNAME  config username  ''
config_get PASSWORD  config password  ''
config_get INTERFACE config interface ''
config_get AUTH_HOST config auth_host '192.168.99.2'
config_get NAS_NAME  config nas_name  'GKDX'
config_get CHECK_URL config check_url 'http://connectivitycheck.platform.hicloud.com/generate_204'
config_get AES_KEY   config aes_key   '1234567887654321'
config_get PROTOCOL  config protocol  'gportal'

TMP=/tmp/campus-auth.$$
trap 'rm -f "$TMP".*' EXIT INT TERM

MODE="$1"

# Quota-pause helpers: --pause-today suspends every authentication attempt
# until midnight (e.g. device-binding quota exhausted), --resume clears it.
if [ "$MODE" = "--pause-today" ]; then
	date +%F > "$PAUSE"
	log 'automatic authentication paused by administrator for today'
	echo "paused until $(date +%F) 23:59:59"
	exit 0
fi
if [ "$MODE" = "--resume" ]; then
	rm -f "$PAUSE"
	log 'automatic authentication resumed by administrator'
	echo 'resumed'
	exit 0
fi

# While the cooldown marker exists, no login attempt is made;
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
	if ! ip link show dev "$INTERFACE" >/dev/null 2>&1; then
		if [ "$MODE" = "--check" ]; then
			exit 2
		fi
		log "configured interface '$INTERFACE' does not exist"
		write_state failed "interface '$INTERFACE' does not exist"
		exit 1
	fi
	CURL_IF="--interface $INTERFACE"
	USER_IP=$(ip -4 -o addr show dev "$INTERFACE" | awk '{sub(/\/.*/,"",$4); print $4; exit}')
else
	USER_IP=$(ip -4 route get "$AUTH_HOST" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
fi

PROTO_FILE="/usr/share/campus-auth/proto/${PROTOCOL}.sh"
if [ ! -r "$PROTO_FILE" ]; then
	log "unknown protocol '$PROTOCOL'"
	write_state failed "unknown protocol '$PROTOCOL'"
	exit 1
fi
# shellcheck disable=SC1090
. "$PROTO_FILE"

REJECT_MSG=
if [ "$MODE" = "--check" ]; then
	proto_check
	exit $?
fi

proto_login
rc=$?
case "$rc" in
	0)
		write_state success 'authenticated'
		# Log the WAN IP with every success: portals that count a changed
		# address as a new device burn a binding slot per re-login, and
		# this line is the evidence for that correlation.
		log "authentication succeeded for ${USERNAME} (${PROTOCOL}) wan_ip=${USER_IP:-unknown}"
		exit 0
		;;
	55)
		date +%s > "$MARKER"
		write_state cooldown 'server requested pause (reason 55)'
		log "authentication paused: portal requested a cooldown; wait 15 minutes, then remove $MARKER before one manual retry"
		exit 55
		;;
	*)
		msg="${REJECT_MSG:-rejected}"
		write_state failed "$msg"
		log "authentication rejected for ${USERNAME}: ${msg}"
		exit "$rc"
		;;
esac
