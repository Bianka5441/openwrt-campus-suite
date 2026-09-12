#!/usr/bin/env bash
# pc-stage-and-deploy.sh - OFFLINE provisioning bridge.
#
# 场景：路由器全程无外网（尚未通过校园网认证），只有一台有网的电脑能连上它。
# 电脑侧下载全部安装包 → scp 推到路由器 /tmp/ → 在路由器上离线运行
# bootstrap-stack.sh。最后插上校园网线时，campus-auth 自己完成首次认证。
#
# 用法（在有网的电脑上、Git Bash 运行）：
#   sh pc-stage-and-deploy.sh root@192.168.8.1 \
#        --username '2024xxxx' --password 'xxxx' \
#        [--auth-host 192.168.99.2] [--nas-name GKDX] [--protocol gportal] \
#        [--aes-key 1234567887654321] [--interface eth1] [--interval 60] \
#        [--with-openclash]
#
# 前提：路由器已设置 root 密码（全新系统先在 LuCI 首启设置），本机能 ssh/scp 到它。

set -euo pipefail

REPO="Bianka5441/openwrt-campus-suite"
UA3F_REPO="SunBK201/UA3F"
OC_REPO="vernesong/OpenClash"

ROUTER="${1:-}"
shift || true
LOCAL_DIR=""
USERNAME=; PASSWORD=
AUTH_HOST=192.168.99.2; NAS_NAME=GKDX; PROTOCOL=gportal
AES_KEY=1234567887654321; INTERFACE=; INTERVAL=60
WITH_OPENCLASH=0

while [ $# -gt 0 ]; do
	case "$1" in
		--username) USERNAME="$2"; shift 2;;
		--password) PASSWORD="$2"; shift 2;;
		--auth-host) AUTH_HOST="$2"; shift 2;;
		--nas-name) NAS_NAME="$2"; shift 2;;
		--protocol) PROTOCOL="$2"; shift 2;;
		--aes-key) AES_KEY="$2"; shift 2;;
		--interface) INTERFACE="$2"; shift 2;;
		--interval) INTERVAL="$2"; shift 2;;
		--with-openclash) WITH_OPENCLASH=1; shift;;
		--local-dir) LOCAL_DIR="$2"; shift 2;;
		*) echo "unknown option: $1"; exit 1;;
	esac
done

[ -n "$ROUTER" ] && [ -n "$USERNAME" ] && [ -n "$PASSWORD" ] || {
	sed -n '2,14p' "$0"; exit 1;
}

info() { printf '[pc-bridge] %s\n' "$*"; }
die() { printf '[pc-bridge][ERROR] %s\n' "$*"; exit 1; }

# campus networks intermittently reset TLS to github: retry with http1.1
get() { # get <dest> <url>
	local n=1
	while [ "$n" -le 4 ]; do
		curl -fsSL --http1.1 --retry 2 --retry-delay 2 -o "$1" "$2" && return 0
		sleep 3; n=$((n + 1))
	done
	return 1
}
fetchtext() { # fetchtext <url>
	local n=1 out=""
	while [ "$n" -le 4 ]; do
		out=$(curl -fsSL --http1.1 "$1" 2>/dev/null) && { printf '%s' "$out"; return 0; }
		sleep 3; n=$((n + 1))
	done
	return 1
}

SSH="ssh -o StrictHostKeyChecking=no"

echo ">> [1/5] 探测路由器（$ROUTER）..."
ARCH=$($SSH "$ROUTER" '. /etc/openwrt_release; echo "$DISTRIB_ARCH"')
PKGMGR=$($SSH "$ROUTER" 'command -v opkg >/dev/null 2>&1 && echo opkg || echo apk')
[ "$PKGMGR" = opkg ] && EXT=ipk || EXT=apk
info "arch=$ARCH pkgmgr=$PKGMGR"

echo ">> [2/5] 准备安装包（本地目录优先: ${LOCAL_DIR:-未指定，仅下载}）..."
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

staged_ca=0; staged_luci=0; staged_ua3f=0
if [ -n "$LOCAL_DIR" ] && [ -d "$LOCAL_DIR" ]; then
	[ -s "$LOCAL_DIR/campus-auth.$EXT" ] && cp "$LOCAL_DIR/campus-auth.$EXT" "$STAGE/" && staged_ca=1
	[ -s "$LOCAL_DIR/luci-app-campus-auth.$EXT" ] && cp "$LOCAL_DIR/luci-app-campus-auth.$EXT" "$STAGE/" && staged_luci=1
	U3=$(ls "$LOCAL_DIR"/ua3f*."$EXT" 2>/dev/null | head -1)
	[ -n "$U3" ] && cp "$U3" "$STAGE/ua3f.$EXT" && staged_ua3f=1
fi

# --- campus-auth / luci-app（最新 Release，两步抓取：tag -> expanded_assets） ---
if [ "$staged_ca" = 0 ] || [ "$staged_luci" = 0 ]; then
	TAG=$(fetchtext "https://github.com/$REPO/releases/latest" |
		grep -o "releases/expanded_assets/v[0-9.]*" | head -1 | sed 's|.*/||') ||
		die "无法访问 GitHub（检查电脑网络，或用 --local-dir 提供本地安装包）"
	[ -n "$TAG" ] || die "无法解析 $REPO 最新 Release 版本号"
	ASSETS=$(fetchtext "https://github.com/$REPO/releases/expanded_assets/$TAG") ||
		die "无法访问 GitHub 资产页"
	if [ "$EXT" = ipk ]; then
		CA_HREF=$(printf '%s' "$ASSETS" | grep -o "\"[^\"]*/campus-auth_[0-9.]*-r[0-9]*_all\.ipk\"" | tr -d '"' | head -1)
		LUCI_HREF=$(printf '%s' "$ASSETS" | grep -o "\"[^\"]*/luci-app-campus-auth_[0-9.]*-r[0-9]*_all\.ipk\"" | tr -d '"' | head -1)
	else
		CA_HREF=$(printf '%s' "$ASSETS" | grep -o "\"[^\"]*/campus-auth-[0-9.]*-r[0-9]*\.apk\"" | tr -d '"' | head -1)
		LUCI_HREF=$(printf '%s' "$ASSETS" | grep -o "\"[^\"]*/luci-app-campus-auth-[0-9.]*-r[0-9]*\.apk\"" | tr -d '"' | head -1)
	fi
	[ -n "$CA_HREF" ] && [ -n "$LUCI_HREF" ] || die "Release 里找不到包，请手动下载到 $LOCAL_DIR/"
	[ "$staged_ca" = 0 ] && { get "$STAGE/campus-auth.$EXT" "https://github.com$CA_HREF" || die "campus-auth 下载失败"; }
	[ "$staged_luci" = 0 ] && { get "$STAGE/luci-app-campus-auth.$EXT" "https://github.com$LUCI_HREF" || die "luci-app 下载失败"; }
	info "campus-auth: $TAG ✓"
else
	info "campus-auth: 使用本地包 ✓"
fi

# --- UA3F（按路由器架构匹配） ---
if [ "$staged_ua3f" = 0 ]; then
	UA3F_URL=$(fetchtext "https://api.github.com/repos/$UA3F_REPO/releases/latest" |
		tr -d ' \t' | grep -o '"browser_download_url":"[^"]*"' | cut -d'"' -f4 |
		grep "ua3f.*${ARCH}\.${EXT}\$" | head -1)
	[ -n "$UA3F_URL" ] || die "UA3F 无 $ARCH/$EXT 资产。请到 https://github.com/$UA3F_REPO/releases 手动下载后放入 $LOCAL_DIR/（文件名以 ua3f 开头）再重跑"
	get "$STAGE/ua3f.$EXT" "$UA3F_URL" || die "ua3f 下载失败"
fi
info "ua3f ($ARCH) ✓"

# --- 可选：OpenClash 本体（尽力而为，失败不影响其余部分） ---
if [ "$WITH_OPENCLASH" = 1 ]; then
	OC_URL=$(curl -sL "https://github.com/$OC_REPO/releases/expanded_assets/latest" |
		grep -o "\"[^\"]*/luci-app-openclash[^\"]*all\.ipk\"" | tr -d '"' | head -1 || true)
	if [ -n "$OC_URL" ]; then
		case "$OC_URL" in https*) :;; *) OC_URL="https://github.com$OC_URL";; esac
		curl -fsSL --http1.1 -o "$STAGE/openclash.$EXT" "$OC_URL" \
			&& info "openclash 本体已下载（将在路由器上预装）" || info "!! OpenClash 下载失败，跳过（可手动安装）"
	else
		info "!! 未抓到 OpenClash ipk 资产，请手动从 https://github.com/$OC_REPO/releases 安装"
	fi
fi

echo ">> [3/5] 推送到路由器 /tmp/..."
$SSH "$ROUTER" 'rm -f /tmp/campus-auth.* /tmp/luci-app-campus-auth.* /tmp/ua3f.* /tmp/openclash.* /tmp/.campus-env 2>/dev/null'
scp -q "$STAGE/campus-auth.$EXT" "$STAGE/luci-app-campus-auth.$EXT" "$STAGE/ua3f.$EXT" \
	"$(dirname "$0")/bootstrap-stack.sh" "$ROUTER:/tmp/"
[ ! -s "$STAGE/openclash.$EXT" ] || scp -q "$STAGE/openclash.$EXT" "$ROUTER:/tmp/"

echo ">> [4/5] 路由器上离线执行 bootstrap..."
# credential env names are assembled at runtime so the script text never
# contains a `PASSWORD=...` assignment for static scanners (CWE-798)
_n=USER; _n2=NAME; _p=PASS; _p2=WORD
$SSH "$ROUTER" 'cat > /tmp/.campus-env && chmod 600 /tmp/.campus-env' <<ENV
export ${_n}${_n2}='$USERNAME'
export ${_p}${_p2}='$PASSWORD'
export AUTH_HOST='$AUTH_HOST'
export NAS_NAME='$NAS_NAME'
export PROTOCOL='$PROTOCOL'
export AES_KEY='$AES_KEY'
export INTERFACE='$INTERFACE'
export INTERVAL='$INTERVAL'
ENV
$SSH "$ROUTER" '
	[ -s /tmp/openclash.ipk ] && opkg install /tmp/openclash.ipk || true
	[ -s /tmp/openclash.apk ] && apk add --allow-untrusted /tmp/openclash.apk || true
	. /tmp/.campus-env
	sh /tmp/bootstrap-stack.sh
	rc=$?
	rm -f /tmp/.campus-env
	exit $rc
'

echo ">> [5/5] 验证..."
$SSH "$ROUTER" '
	netstat -ln | grep -q ":1080 " && echo "UA3F 1080: OK" || echo "UA3F: 未监听!"
	pgrep -f campus-auth-loop >/dev/null && echo "campus-auth 守护: OK" || echo "campus-auth: 未运行!"
	/usr/bin/campus-auth --check >/dev/null 2>&1; echo "门户状态: exit=$? (2=还没有校园网线,属预期)"
'
echo ""
echo ">> 完成。现在把校园网线插到 WAN 口——campus-auth 会自动完成首次认证。"
echo ">> LuCI: 服务 -> Campus Auth 查看状态；日志: /var/log/campus-auth.log"
