#!/bin/sh
# campus-auth-loop - portal-state-driven reauthentication daemon.
# Started and supervised by /etc/init.d/campus-auth (procd).
#
# Decision logic (matches the project handoff contract):
#   1. While /etc/campus-auth.reason55 exists, make no portal requests.
#      The marker stores its creation time; it expires after 15 minutes.
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
#   6. During the configured quiet window (default 00:00-06:00, matching a
#      nightly campus outage) no requests are made at all: the portal is
#      down, checks are pointless, and every post-outage re-login consumes
#      one of the account's daily device-binding slots, so logins must
#      stay rare.
#   7. After a failed login the loop holds off for login_holdoff seconds
#      before trying again, so a persistent reject (e.g. binding quota
#      exhausted) does not hammer the portal.

. /lib/functions.sh
config_load campus-auth

config_get INTERVAL config interval '60'
config_get QUIET_ENABLE config quiet_enable '1'
config_get QUIET_START config quiet_start '00:00'
config_get QUIET_END config quiet_end '06:00'
config_get HOLDOFF config login_holdoff '900'

case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=60;; esac
[ "$INTERVAL" -lt 30 ] && INTERVAL=30
case "$HOLDOFF" in ''|*[!0-9]*) HOLDOFF=900;; esac
[ "$HOLDOFF" -lt 60 ] && HOLDOFF=60

MARKER=/etc/campus-auth.reason55
ONLINE_MARKER=/tmp/campus-auth.await-online
LOG=/var/log/campus-auth.log
# Portal-ordered cooldowns (reasoncode:55) last 15 minutes.
COOLDOWN_SECS=900

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

# True while the campus network is in its scheduled off window.
# Handles windows that span midnight (start > end); equal values disable.
in_quiet_window() {
	[ "$QUIET_ENABLE" = 1 ] || return 1
	[ -n "$QUIET_START" ] && [ -n "$QUIET_END" ] || return 1
	awk -v now="$(date +%H:%M)" -v a="$QUIET_START" -v b="$QUIET_END" 'BEGIN {
		split(now, x, ":"); n = x[1] * 60 + x[2] + 0
		split(a, y, ":"); A = y[1] * 60 + y[2] + 0
		split(b, z, ":"); B = z[1] * 60 + z[2] + 0
		if (A == B) exit 1
		if (A < B) exit !(n >= A && n < B)
		exit !(n >= A || n < B)
	}'
}

FAILS=0

while :; do
	if in_quiet_window; then
		FAILS=0
		sleep "$INTERVAL"
		continue
	fi

	if [ -e "$MARKER" ]; then
		age=$(( $(date +%s) - $(cat "$MARKER" 2>/dev/null || echo 0) ))
		if [ "$age" -ge "$COOLDOWN_SECS" ]; then
			rm -f "$MARKER"
			log 'reason55 cooldown marker expired; resuming normal checks'
		fi
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
				else
					log "login failed; holding off ${HOLDOFF}s to conserve the device-binding quota"
					sleep "$HOLDOFF"
				fi
				FAILS=0
			fi
		fi
	else
		FAILS=0
	fi

	sleep "$INTERVAL"
done
