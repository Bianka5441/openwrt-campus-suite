#!/bin/sh
# =============================================================================
# 校园网多设备检测加固：TTL / NTP / DNS / IPv6（参考视频配套命令整理版）
#
# 与 UA3F/OpenClash 相互独立，可单独使用。适用于 ImmortalWrt 21.02（fw3 + iptables）。
# 按 TEST-PLAN.md 分阶段逐项应用，一次只加一项。
#
# 对应的检测手段：
#   TTL 统一    —— 不同系统默认 TTL 不同（Windows 128 / Linux 64），网关据此判断
#                  多设备；即使只挂一台设备，路由器自身(64)与转发流量(128)也会
#                  混出两种 TTL。出 WAN 的包统一为 64 后只呈现一个值。
#   NTP 重定向  —— 时钟偏移(clock skew)检测：各设备时钟漂移不同，强制全网 NTP
#                  走路由器后完全一致。
#   DNS 重定向  —— 设备手动设置外部 DNS（8.8.8.8 等）会形成多设备特征，强制全部
#                  走路由器 dnsmasq。
#   IPv6 关闭   —— 若校园网下发 IPv6，NAT 之后每台设备仍会拿到独立的公网 IPv6
#                  地址，等于"实名"暴露多设备，且完全绕过 IPv4 侧一切伪装。
#                  关闭 LAN 侧 RA/DHCPv6 即可。
#
# 用法（root 执行）：
#   sh campus-detect-hardening.sh apply      # TTL + NTP + DNS（写入开机持久化）
#   sh campus-detect-hardening.sh ipv6-off   # 关闭 LAN 侧 IPv6 RA/DHCPv6
#   sh campus-detect-hardening.sh ipv6-on    # 恢复 IPv6
#   sh campus-detect-hardening.sh status     # 查看当前生效项
#   sh campus-detect-hardening.sh remove     # 撤销 TTL/NTP/DNS
# =============================================================================

WAN_IF="eth1"              # 校园网上行口，按实际修改（ip -4 addr 确认）

MARK_BEGIN="# >>> campus-detect-hardening >>>"
MARK_END="# <<< campus-detect-hardening <<<"

fw_user="/etc/firewall.user"

rules() {
cat <<EOF
${MARK_BEGIN}
# TTL 统一：出校园网口的包 TTL 一律 64
iptables -t mangle -A POSTROUTING -o ${WAN_IF} -j TTL --ttl-set 64
# IPv6 跳数统一（未启用 IPv6 时该命令报错，属正常）
ip6tables -t mangle -A POSTROUTING -o ${WAN_IF} -j HL --hl-set 64 2>/dev/null
# NTP 强制走本机（apply 会先开启路由器 NTP 服务器）
iptables -t nat -A PREROUTING -p udp --dport 123 -j REDIRECT --to-ports 123
# DNS 强制走本机 dnsmasq
iptables -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 53
iptables -t nat -A PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 53
${MARK_END}
EOF
}

remove_persist_block() {
  [ -f "$fw_user" ] || return 0
  sed -i "/^${MARK_BEGIN}$/,/^${MARK_END}$/d" "$fw_user" 2>/dev/null
}

apply() {
  # 0) 开启路由器自身的 NTP 服务器，供 REDIRECT 后的设备对时
  uci set system.ntp.enable_server='1'
  uci commit system
  /etc/init.d/sysntpd restart 2>/dev/null

  # 1) 写入持久化块（幂等：先清旧块再追加）
  remove_persist_block
  rules >> "$fw_user"
  chmod 644 "$fw_user" 2>/dev/null

  # 2) 立即生效（与持久化块内容一致）
  eval "$(rules | grep -v '^#' | grep -v '^$')"

  echo "== TTL/NTP/DNS 已应用并持久化 =="
  status
}

ipv6_off() {
  uci set dhcp.lan.ra='disabled'
  uci set dhcp.lan.dhcpv6='disabled'
  uci set dhcp.lan.ndp='disabled'
  uci commit dhcp
  /etc/init.d/odhcpd restart 2>/dev/null
  echo "== LAN 侧 IPv6 RA/DHCPv6 已关闭；设备重连 WiFi 后生效 =="
  echo "   验证：设备断开重连后 curl -6 https://api64.ipify.org 应失败（无全局 IPv6）"
  echo "   恢复：sh $0 ipv6-on"
}

ipv6_on() {
  uci set dhcp.lan.ra='server'
  uci set dhcp.lan.dhcpv6='server'
  uci set dhcp.lan.ndp='disabled'
  uci commit dhcp
  /etc/init.d/odhcpd restart 2>/dev/null
  echo "== LAN 侧 IPv6 已恢复 =="
}

remove() {
  remove_persist_block
  iptables -t mangle -D POSTROUTING -o "$WAN_IF" -j TTL --ttl-set 64 2>/dev/null
  ip6tables -t mangle -D POSTROUTING -o "$WAN_IF" -j HL --hl-set 64 2>/dev/null
  iptables -t nat -D PREROUTING -p udp --dport 123 -j REDIRECT --to-ports 123 2>/dev/null
  iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null
  iptables -t nat -D PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null
  echo "== TTL/NTP/DNS 已移除 =="
}

status() {
  echo "-- mangle TTL（出 WAN）--"
  iptables -t mangle -S POSTROUTING 2>/dev/null | grep -i ttl || echo "  无"
  echo "-- nat NTP/DNS 重定向 --"
  iptables -t nat -S PREROUTING 2>/dev/null | grep -Ei 'dport (123|53) ' || echo "  无"
  echo "-- NTP server --"
  uci -q get system.ntp.enable_server || echo "  未开启"
  echo "-- LAN IPv6 RA/DHCPv6 --"
  uci -q get dhcp.lan.ra; uci -q get dhcp.lan.dhcpv6
  echo "-- firewall.user 持久化块 --"
  grep -c "$MARK_BEGIN" "$fw_user" 2>/dev/null || echo "  0（未持久化）"
}

case "$1" in
  apply)     apply ;;
  ipv6-off)  ipv6_off ;;
  ipv6-on)   ipv6_on ;;
  remove)    remove ;;
  status)    status ;;
  *) echo "用法: sh $0 {apply|ipv6-off|ipv6-on|remove|status}"; exit 1 ;;
esac
