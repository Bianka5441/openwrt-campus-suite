#!/bin/sh
# campus-auth-loop - portal-state-driven reauthentication daemon.
# Started and supervised by /etc/init.d/campus-auth (procd).
#
# Decision logic (matches the project handoff contract):
#   1. While /etc/campus-auth.reason55 exists, make no portal requests.
#   2. The authoritative state source is the portal state endpoint, queried
#      through `campus-auth --check` (exit 0 online / 1 offline / 2 unknown).
#      A public HTTP-204 reachability probe is never used as the state
#      source: a captive portal can answer probes and a probe failure says
#      nothing about the account state.
#   3. Two consecutive explicit offline results trigger exactly one login
#      attempt.
#   4. After a successful login a transient marker blocks further logins
#      until an explicit online check succeeds.
#   5. Unknown/error results never trigger authentication.

. /lib/functions.sh
config_load campus-auth

config_get INTERVAL config interval '60'

case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=60;; esac
[ "$INTERVAL" -lt 30 ] && INTERVAL=30

MARKER=/etc/campus-auth.reason55
ONLINE_MARKER=/tmp/campus-auth.await-online
LOG=/var/log/campus-auth.log

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

FAILS=0

while :; do
	if [ -e "$MARKER" ]; then
		sleep "$INTERVAL"
		continue
	fi

	/usr/bin/campus-auth --check
	rc=$?

	if [ "$rc" = 0 ]; then
		FAILS=0
		rm -f "$ONLINE_MARKER"
	elif [ "$rc" = 1 ]; then
		if [ ! -e "$ONLINE_MARKER" ]; then
			FAILS=$((FAILS + 1))
			if [ "$FAILS" -ge 2 ]; then
				log 'campus account reported offline twice; attempting authentication'
				if /usr/bin/campus-auth; then
					touch "$ONLINE_MARKER"
				fi
				FAILS=0
			fi
		fi
	else
		FAILS=0
	fi

	sleep "$INTERVAL"
done
