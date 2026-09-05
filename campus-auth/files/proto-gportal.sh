#!/bin/sh
# gportal protocol adapter (the GKDX / wlanacname portal family).
#
# Flow: fetch the login page with the device IP, extract the per-session
# sign/iv fields, AES-128-CBC encrypt the form (ZeroPadding, configurable
# key via UCI "aes_key") and POST to /gportal/web/authLogin.
# State checks POST userIp+sign to /gportal/web/queryAuthState.
#
# Expects from the dispatcher: MODE, USERNAME, PASSWORD, AUTH_HOST, NAS_NAME,
# AES_KEY, CHECK_URL, CURL_IF, USER_IP, TMP, UA; helpers log/write_state/
# urlencode/field.

gportal_require_ip() {
	[ -n "$USER_IP" ] || {
		if [ "$MODE" = "--check" ]; then
			return 2
		fi
		log 'cannot determine campus IP'
		write_state failed 'cannot determine campus IP'
		return 1
	}
}

gportal_fetch_login_page() {
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
		return 2
	fi

	SIGN=$(field sign)
	[ -n "$SIGN" ] || {
		[ "$MODE" = "--check" ] || { log 'login page missing sign/iv'; write_state failed 'login page missing sign/iv'; }
		return 2
	}
	return 0
}

proto_check() {
	gportal_require_ip || return $?
	gportal_fetch_login_page || return $?

	STATUS_RESPONSE=$(curl -fsS --noproxy '*' $CURL_IF \
		-A "$UA" \
		-H 'Accept: application/json, text/javascript, */*; q=0.01' \
		-H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
		-H 'X-Requested-With: XMLHttpRequest' \
		-H "Origin: http://${AUTH_HOST}" \
		-H "Referer: ${LOGIN_URL}" \
		--cookie "$TMP.cookie" \
		--data "userIp=$(urlencode "$USER_IP")&sign=$(urlencode "$SIGN")" \
		"http://${AUTH_HOST}/gportal/web/queryAuthState") || return 2

	case "$STATUS_RESPONSE" in
		*'"authState":2'*) return 0;;
		*'"authState":1'*) return 1;;
		*) return 2;;
	esac
}

proto_login() {
	gportal_require_ip || return $?
	gportal_fetch_login_page || return $?

	IV=$(field iv)
	REDIRECT=$(field redirectUrl)
	TEMPLATE=$(field portalTemplateId)
	PID=$(field pid)
	VLAN=$(field vlan)
	[ "${#IV}" -eq 16 ] || {
		log 'login page missing sign/iv'
		write_state failed 'login page missing sign/iv'
		return 2
	}

	FORM="nasName=$(urlencode "$NAS_NAME")&nasIp=&userIp=$(urlencode "$USER_IP")&userMac=&ssid=&apMac=&pid=$(urlencode "$PID")&vlan=$(urlencode "$VLAN")&sign=$(urlencode "$SIGN")&iv=$(urlencode "$IV")&redirectUrl=$(urlencode "$REDIRECT")&portalTemplateId=$(urlencode "$TEMPLATE")&show_type=0&account_type=&name=$(urlencode "$USERNAME")&password=$(urlencode "$PASSWORD")"

	printf '%s' "$FORM" > "$TMP.plain"
	LEN=$(wc -c < "$TMP.plain")
	PAD=$((16 - LEN % 16))
	dd if=/dev/zero bs=1 count="$PAD" >> "$TMP.plain" 2>/dev/null

	# AES-128-CBC, ZeroPadding, key from UCI "aes_key" (ASCII form,
	# converted to hex here -- no `od` on stock OpenWrt), per-session IV.
	KEY=$(printf '%s' "$AES_KEY" | awk '
		BEGIN {
			for (i = 1; i <= 255; i++)
				ord[sprintf("%c", i)] = i
		}
		{
			s = $0
			for (i = 1; i <= length(s); i++)
				printf "%02X", ord[substr(s, i, 1)]
		}')
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
			*) REJECT_MSG='invalid IV'; return 2;;
		esac
		i=$((i + 1))
	done

	openssl enc -aes-128-cbc -K "$KEY" -iv "$IV_HEX" -nopad -in "$TMP.plain" -a -A -out "$TMP.data" || {
		log 'AES encryption failed'
		REJECT_MSG='AES encryption failed'
		return 1
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
		log 'authentication request failed'
		REJECT_MSG='authentication request failed'
		return 1
	}

	case "$RESPONSE" in
		*'"status":1'*) return 0;;
		*'"reasoncode":55'*) return 55;;
		*)
			REJECT_MSG=$(printf '%s' "$RESPONSE" | tr '\n' ' ' | cut -c1-240)
			return 1
			;;
	esac
}
