#!/bin/sh
# Ruijie (锐捷) eportal protocol adapter -- PREVIEW.
#
# Covers the common web eportal deployments: while offline, any plain-HTTP
# probe is 302-redirected to
#   http://<portal>[:port]/eportal/....&queryString=<urlencoded session>
# and login is a form POST to /eportal/InterFace.do?method=login carrying
# that queryString plus credentials. Verify the flow against your school
# (some deployments expect a hashed password or different paths) before
# trusting it; the gportal adapter remains the reference implementation.
#
# Expects from the dispatcher: MODE, USERNAME, PASSWORD, AUTH_HOST,
# CHECK_URL, CURL_IF, TMP, UA; helpers log/write_state/urlencode.

ruijie_probe() {
	# Returns the redirect target on the wire, empty when not redirected.
	curl -s -o /dev/null -m 6 $CURL_IF -w '%{redirect_url}' "$CHECK_URL" 2>/dev/null
}

proto_check() {
	# While offline the portal 302-redirects any plain-HTTP probe to the
	# eportal host; an unredirected 200/204 means already online.
	redir=$(ruijie_probe)
	[ -n "$redir" ] && return 1
	out=$(curl -s -o /dev/null -m 6 $CURL_IF -w '%{http_code}' "$CHECK_URL" 2>/dev/null)
	case "$out" in
		200|204) return 0;;
		*) return 2;;
	esac
}

proto_login() {
	redir=$(ruijie_probe)
	case "$redir" in
		*/eportal/*|*InterFace.do*) : ;;
		'')
			REJECT_MSG='no portal redirect detected; network seems already reachable'
			return 1
			;;
		*)
			REJECT_MSG="unexpected redirect target: $(printf '%s' "$redir" | cut -c1-120)"
			return 1
			;;
	esac

	HOSTPORT=$(printf '%s' "$redir" | sed -n 's#^[a-zA-Z]*://\([^/]*\)/.*#\1#p')
	[ -n "$HOSTPORT" ] || { REJECT_MSG='cannot parse portal host from redirect'; return 1; }
	QS=$(printf '%s' "$redir" | sed -n 's/.*[?&]queryString=\([^&]*\).*/\1/p')
	[ -n "$QS" ] || { REJECT_MSG='redirect missing queryString'; return 1; }

	RESPONSE=$(curl -fsS --noproxy '*' $CURL_IF \
		-A "$UA" \
		--connect-timeout 5 --max-time 15 \
		-H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
		-H "Referer: $redir" \
		--data "method=login&queryString=$(urlencode "$QS")&username=$(urlencode "$USERNAME")&password=$(urlencode "$PASSWORD")&port=&isSave=1" \
		"http://${HOSTPORT}/eportal/InterFace.do?method=login") || {
		REJECT_MSG='login request failed'
		return 1
	}

	case "$RESPONSE" in
		*'"result":"success"'*) return 0;;
		*)
			REJECT_MSG=$(printf '%s' "$RESPONSE" | tr '\n' ' ' | cut -c1-240)
			return 1
			;;
	esac
}
