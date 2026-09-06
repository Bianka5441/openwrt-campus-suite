# 校园网共享检测：分阶段对照实验方法

> 本文档是[仓库 README](../README.md) 所述方案的配套实验方法：当触发检测时如何定位暴露向量。

> 目的：检测触发后只停用 15 分钟（`reasoncode:55`），代价可控——用这个窗口做**逐项对照实验**，
> 找出到底是哪个特征在暴露多设备，而不是把所有对策一股脑堆上去。
> 一次只改一个变量，否则触发了也不知道是哪个对策没起效。

> **✅ 进展（2026-09-05 晚）**
> - Stage 0 已完成：**IPv6**——eth1 无全局地址，校园网未给路由器下发 v6，无泄漏（ra=hybrid 无害）；**TTL/NTP/DNS**——视频配套 iptables 套件早已在位且持久化于 `/etc/firewall.user`（TTL-set 64 全接口 + NTP/DNS 重定向 + NTP 强制本机）。
> - **重要线索**：16:51 那次触发 55 时 TTL/NTP/DNS 都已在位、唯独 UA3F 没在跑（且曾以"零规则"状态空转）→ UA 多样性基本锁定为触发向量。
> - Stage 1（UA 统一）已部署并端到端实测通过：curl / iPhone / Chrome 三种 UA → 同一条 `Chrome/133 (Windows NT 10.0; Win64; x64)`；门户认证不受影响。
> - **当前处于 Stage 1 观察期**：多设备正常使用 1–2 天，按 §0 判定与 §6 记录表执行。
> - 若 Stage 1 观察期内再次触发 55，下一个变量候选（按优先级）：① `l3_rewrite_tcpts '1'`（TCP 时间戳/uptime 指纹，改 `/etc/config/ua3f` 后 restart）；② 真实 VPS 全代理（SNI/Host 多样性）。

---

## 0. 基本认知

- `reasoncode:55` 在**认证/重新认证时**返回，含义是"检测到代理/共享行为"。也就是说：服务端先在日常流量里发现异常并给账号打标，下次认证时爆发。
- 所以判定某个阶段"是否有效"不能只看登录成功——**账号可能带着上次的残留标记**。正确的判定方法是：
  1. 冷却 15 分钟后完成一次干净的登录（`campus-auth --check` 退出码 0）；
  2. 在该配置下多设备**正常使用 1–2 天**；
  3. 期间若发生自然掉线重连/手动重新认证且**没有**再出 55 → 该对策有效；
  4. 只要再出一次 55 → 该对策不足，记录现场，进入下一阶段。
- 冷却期（`/etc/campus-auth.reason55` 存在时）**不要手动反复提交登录**，campus-auth 服务会自动遵守冷却；窗口内正好用来部署下一阶段。
- 每次触发都记一笔（见 §6 记录表），几次之后规律会自己浮出来。

## 1. Stage 0：基线 + 两个"免费"检查

**目的**：确认检测仍会触发（复现已知行为），并排除最容易忽略的两个大破绽。

```sh
# 部署前状态快照（多设备挂上后执行）
/usr/bin/campus-auth --check; echo exit=$?
tail -n 20 /var/log/campus-auth.log
```

**检查 A：IPv6 泄漏（重要，先做这个）。** 如果校园网下发 IPv6，NAT 之后每台设备照样拿到**独立的公网 IPv6 地址**——等于每台设备都实名签到，IPv4 侧做任何伪装都没用。在任意 LAN 设备上：

```
浏览器访问 https://test-ipv6.com/
# 或: curl -6 https://api64.ipify.org
```

若显示公网 IPv6（240e:/2408:/2xxx 开头）→ 立即 `sh campus-detect-hardening.sh ipv6-off`，设备重连 WiFi 后复测，确认没有全局 IPv6。**这项无论实验怎么排都建议直接做掉。**

**检查 B：TTL 现状。** 在 LAN 设备连续上网几分钟后，路由器上抓出 WAN 的 TTL 分布（若装有 tcpdump）：`tcpdump -i eth1 -nn -c 50 'ip and not icmp' 2>/dev/null | grep -o 'ttl [0-9]*' | sort | uniq -c`。出现多种 ttl 值（如 64 与 128 混杂）即证实 TTL 向量可用——**即使只挂一台设备**也会这样（路由器自身流量 TTL=64、转发自 Windows 的 TTL=128），这是"单设备也被判共享"的最常见原因。

## 2. Stage 1：UA3F + OpenClash（UA 统一）——本包默认部署

**前提**：完成本文档套件的部署（一键 `tools/bootstrap-stack.sh`，或按 README 手动步骤）。

**部署后立即验证**（判定部署本身成功，而非检测有效）：

```sh
# PC（接路由器）上：必须走 http，不走 https
curl http://cip.cc          # UserAgent 行应显示统一后的值
curl http://httpbin.org/user-agent
# 路由器上：80 端口连接应显示走 ua3f，443 走 DIRECT（OpenClash 连接页可看）
```

**实验**：多设备正常使用 1–2 天，按 §0 判定。
- 若通过 → 说明触发向量主要就是 UA 多样性，收工，保持现状。
- 若仍触发 → 记录现场，冷却窗口内做 Stage 2。

## 3. Stage 2：+ TTL 统一

```sh
# 路由器上（WAN_IF 已按 eth1 写好）
sh /usr/bin/campus-detect-hardening.sh apply
sh /usr/bin/campus-detect-hardening.sh status
```

复测：从 LAN 设备访问外网确认无异常后，多设备使用 1–2 天，按 §0 判定。

## 4. Stage 3：+ NTP/DNS 统一（包含在 apply 里）与 IPv6

`apply` 已同时加上 NTP/DNS 重定向；IPv6 用 `ipv6-off` 单独控制（若 Stage 0 检查 A 已确认无 IPv6，此步跳过）。本阶段主要价值是排除"个别设备手动配了外部 DNS/时间漂移"类低概率向量，与前两阶段合并观察即可。

## 5. Stage 4：以上全过仍触发 → 剩下的向量与对策

| 向量 | 说明 | 对策 |
| --- | --- | --- |
| HTTP Host / SNI 多样性 | 多设备同时访问不同网站，站点列表直接暴露"这是一群人" | 真实 VPS 节点全代理（`openclash-ua3f.yaml` 内注释有示例，`MATCH` 指向节点），校园网只见一条到 VPS 的加密流 |
| 流量画像/并发 | 多设备同时高带宽、长连接模式 | 无法完全伪装，收敛使用习惯（错峰大流量） |
| DPI 深度包检测 | UA3F 3.6.0 自带 desync 参数可对抗部分注入/RST | 已在 `/etc/config/ua3f` 启用（desync_*），观察即可 |

## 6. 记录表（每次 55 都填）

| 时间 | 当时生效的对策 | 在线设备数 | 当时在做什么 | 登录返回 | 备注 |
| --- | --- | --- | --- | --- | --- |
| 例 09-05 14:30 | 无 | 3 | 手机看视频+PC 下载 | 55 | 触发前约 10 分钟开始高带宽 |

配套查询命令（触发时立刻跑）：

```sh
date; ls -l /etc/campus-auth.reason55 2>/dev/null
iptables -t mangle -S POSTROUTING | grep -i ttl      # TTL 是否在位
netstat -ln | grep 1080                              # UA3F 是否在位（不在位=实验变量失效，结果作废）
uci -q get dhcp.lan.ra                               # IPv6 RA 是否关着
tail -n 5 /var/log/campus-auth.log
```

**注意**：若触发时发现 UA3F 没在监听（1080 空）或规则失效，本次 55 **不能**算作对策失败——那是部署回退，修好部署再测。
