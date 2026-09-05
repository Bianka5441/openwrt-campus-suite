#!/bin/sh
# campus-auth-loop - probe connectivity and authenticate when offline.
# Started and supervised by /etc/init.d/campus-auth (procd).

. /lib/functions.sh
config_load campus-auth

config_get CHECK_URL config check_url 'http://connectivitycheck.gstatic.com/generate_204'
config_get INTERVAL  config interval  '120'
config_get INTERFACE config interface ''

case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=120;; esac
[ "$INTERVAL" -lt 30 ] && INTERVAL=30

CURL_IF=
[ -n "$INTERFACE" ] && CURL_IF="--interface $INTERFACE"

while :; do
	if ! curl -fsS $CURL_IF --max-time 8 -o /dev/null "$CHECK_URL"; then
		/usr/bin/campus-auth
	fi
	sleep "$INTERVAL"
done
