#!/bin/sh
# flash.sh - one-click flash of the campus-suite onto a router (run on PC).
#
# Usage (from the repo root or anywhere; uses the offline bundle dir):
#   ./flash.sh <router-ip>                    # fresh router: mode 2, no account
#   ./tools/flash.sh 192.168.5.1 user pass    # also set the campus account
#
# What it does: uploads the offline bundle, runs install-campus-suite.sh
# (which self-verifies: mode anti-detect, UA3F on 1080, OpenClash core with
# the UA3F template, all files present), then syncs the router clock from
# this PC (power-cycled routers run hours slow) and prints a final status.
set -e
IP="${1:?usage: flash.sh <router-ip> [username] [password]}"
USERNAME="${2:-}"
PASSWORD="${3:-}"
DIR="$(cd "$(dirname "$0")/.." && pwd)/artifacts/flash"
BUNDLE="/tmp/campus-suite-offline"

mkdir -p "$DIR"
for f in campus-auth.ipk luci-app-campus-auth.ipk ua3f.ipk install-campus-suite.sh; do
	[ -s "$BUNDLE/$f" ] && cp "$BUNDLE/$f" "$DIR/" || true
done
[ -s "$DIR/campus-auth.ipk" ] || { echo "[flash] missing $BUNDLE bundle"; exit 1; }

echo "[flash] 1/3 uploading suite to $IP ..."
scp -O -o ConnectTimeout=10 "$DIR/campus-auth.ipk" "$DIR/luci-app-campus-auth.ipk" \
	"$DIR/ua3f.ipk" "$DIR/install-campus-suite.sh" "root@$IP:/tmp/" \
	|| { echo "[flash] upload failed (router reachable? ssh key set?)"; exit 1; }

echo "[flash] 2/3 installing (self-verifies mode 2 + UA3F + OpenClash) ..."
if [ -n "$USERNAME" ] && [ -n "$PASSWORD" ]; then
	ssh -o ConnectTimeout=10 "root@$IP" \
		"USERNAME='$USERNAME' PASSWORD='$PASSWORD' sh /tmp/install-campus-suite.sh" \
		|| { echo "[flash] INSTALL FAILED - see messages above"; exit 1; }
else
	ssh -o ConnectTimeout=10 "root@$IP" "sh /tmp/install-campus-suite.sh" \
		|| { echo "[flash] INSTALL FAILED - see messages above"; exit 1; }
fi

echo "[flash] 3/3 syncing router clock from PC ..."
EPOCH=$(date +%s)
ssh -o ConnectTimeout=10 "root@$IP" "date -u -s @$EPOCH >/dev/null && date" || true

echo "[flash] cleaning temp files ..."
ssh -o ConnectTimeout=10 "root@$IP" "rm -f /tmp/*.ipk /tmp/install-campus-suite.sh /etc/config/campus-auth-opkg" 2>/dev/null || true

echo "[flash] DONE. Plug the campus cable into the WAN port; auth + hardening +"
echo "[flash] OpenClash/UA3F all come up automatically (loop + hotplug self-heal)."
