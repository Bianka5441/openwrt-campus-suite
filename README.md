# OpenWrt Campus Auth — 校园网认证守护 + 多设备共存全套方案

[![Build OpenWrt packages](https://github.com/Bianka5441/openwrt-campus-auth/actions/workflows/ci.yml/badge.svg)](https://github.com/Bianka5441/openwrt-campus-auth/actions/workflows/ci.yml)
![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)

一套在 OpenWrt 路由器上长期运行的组合方案，解决两件事：

1. **门户认证**：掉线自动重连的认证守护插件（本仓库核心，带 LuCI 界面）；
2. **多设备共存**：让校园网检测系统把 NAT 后的多台设备看成一台——统一 User-Agent、统一 TTL、统一 NTP/DNS。

> ⚠️ **免责声明**：本项目仅供网络协议学习与个人研究。使用前请了解所在网络服务条款，自行承担合规风险；请勿用于商业或破坏性用途。门户侧如明确要求停止共享（如 `reasoncode:55`），请先遵守。

## 方案架构

```
[手机/电脑等设备]
   │ WiFi / 有线
   ▼
[路由器]
   ├─ iptables/nft: DNS(53)/NTP(123) 强制走路由器   ← 统一 DNS 与时钟
   ├─ OpenClash (TUN): 终结所有 TCP/UDP 连接        ← 统一 TCP 栈指纹
   │    ├─ 门户/私网 → DIRECT（认证流量不碰）
   │    ├─ UDP → DIRECT
   │    ├─ TCP 80 → UA3F(127.0.0.1:1080) → 统一 UA  ← 检测最常用的向量
   │    └─ 其余 → DIRECT
   ├─ iptables/nft: 出 WAN 的 TTL 统一为 64          ← 经典检测向量
   └─ NAT: 全部流量以一个 IP 出校园网
```

| 检测向量 | 对策 | 实现位置 |
|---|---|---|
| TTL 差异（多设备） | 出 WAN 一律 64 | `docs/campus-detect-hardening.sh` |
| HTTP User-Agent 多样性 | 全部改写为同一条 Chrome UA | UA3F（GLOBAL 模式） |
| DNS 行为差异 | 53 端口强制走路由器 | 同上 |
| 时钟偏移（clock skew） | 123 端口 NTP 强制走路由器 | 同上 |
| TCP 栈/uptime 指纹 | clash TUN 终结后由路由器栈重发起 | OpenClash 配置 |
| IPv6 旁路 | 校园网未下发则无风险；有则关 LAN RA | 加固脚本 `ipv6-off` |
| SNI/Host 多样性、流量画像 | **当前方案不覆盖**——需自建 VPS 全代理，见下文 | — |

## 仓库内容

| 文件 | 说明 |
|---|---|
| `campus-auth/`、`luci-app-campus-auth/` | 认证插件源码（后端 + LuCI） |
| `tools/bootstrap-stack.sh` | **一键部署脚本**（其他路由器快速复刻） |
| `tools/build-ipk.py` | 无 SDK 本地打包（测试用） |
| `docs/openclash-ua3f.yaml` | OpenClash 配置（80→UA3F、其余直连、门户直连） |
| `docs/ua3f-config.example` | UA3F 配置（GLOBAL 统一 Chrome UA） |
| `docs/campus-detect-hardening.sh` | TTL/NTP/DNS 加固（fw3 iptables，幂等可回滚） |
| `docs/TEST-PLAN.md` | 触发检测后的分阶段对照实验方法 |
| `docs/LESSONS.md` | **实机部署全程踩坑实录**（24 条经验教训，按现象→根因→正确姿势） |

## 快速部署（推荐）

`tools/bootstrap-stack.sh` 在目标路由器上一次性完成全栈部署，自动探测 CPU 架构、包管理器（opkg/apk）、防火墙代际（fw3/iptables 与 fw4/nftables）和 WAN 口：

```sh
# 你学校（默认参数，只填凭据）：
USERNAME='学号' PASSWORD='密码' sh bootstrap-stack.sh

# 其他学校按需覆盖：
AUTH_HOST='10.x.x.x' NAS_NAME='XXXX' PROTOCOL='ruijie' \
AES_KEY='...' USERNAME='...' PASSWORD='...' sh bootstrap-stack.sh
```

- **幂等**：可重复执行，不会堆积状态；
- **离线兜底**：校网访问 GitHub 不稳时，把安装包预放到 `/tmp/`（`campus-auth.ipk`、`luci-app-campus-auth.ipk`、`ua3f.ipk`）再跑，脚本自动跳过下载；
- **OpenClash 本体不自动安装**（仅写配置）——从 [OpenClash Releases](https://github.com/vernesong/OpenClash/releases) 安装后重跑脚本即可。

**全新刷机机器的三个前提**（脚本会自动检测第一条并给出指引）：

1. **先过门户再跑脚本**：门户会话按 IP 生效——用局域网任意设备浏览器手动登录一次校园网，路由器随之有网；或者离线预置 `/tmp/` 安装包（见上）；
2. **OpenClash 手动装**：脚本不装本体；
3. **先设 root 密码**：全新系统 dropbear 拒绝空密码登录，scp/ssh 前先在 LuCI 首启设置。

已验证环境：ImmortalWrt 21.02 / fw3 / `aarch64_cortex-a53`，作者实机长期运行。fw4（22.03+，nftables drop-in）与 apk（25.12+）路径已实现但未经实机验证；`ruijie` 协议为预览版。

## 手动部署（分步）

以下步骤复刻作者实机的当前配置。

### 1. 认证插件 campus-auth

```sh
# 到 Releases 下载 ipk（OpenWrt ≤24.10）或 apk（25.12+），arch 无关（PKGARCH=all）
opkg install campus-auth_1.0.1-r1_all.ipk luci-app-campus-auth_1.0.1-r1_all.ipk
uci set campus-auth.config.username='学号'
uci set campus-auth.config.password='密码'
uci commit campus-auth && chmod 600 /etc/config/campus-auth
/etc/init.d/campus-auth enable && /etc/init.d/campus-auth start
```

### 2. UA3F（统一 User-Agent）

从 [SunBK201/UA3F Releases](https://github.com/SunBK201/UA3F/releases) 下载**与本机架构一致**的包（`opkg print-architecture` 或 `/etc/openwrt_release` 里的 `DISTRIB_ARCH`），然后：

```sh
opkg install ua3f_<版本>_<架构>.ipk
cp docs/ua3f-config.example /etc/config/ua3f   # GLOBAL 统一为 Chrome/133 (Windows)
/etc/init.d/ua3f enable && /etc/init.d/ua3f restart
netstat -ln | grep 1080                        # 必须看到 127.0.0.1:1080 再进行下一步
```

**重要**：视频教程里 2.3.0 旧格式的 `/etc/config/ua3f`（`rewrite_rules` JSON）与 3.6.0 的 init 脚本不兼容，会以"规则模式 + 零规则"启动、什么都不改写且无报错。务必用 `docs/ua3f-config.example` 这个格式，并确认进程参数为 `-x GLOBAL -f <UA>`（`ps w | grep ua3f`）。

### 3. OpenClash（流量编排）

安装 OpenClash 后，上传 [`docs/openclash-ua3f.yaml`](docs/openclash-ua3f.yaml) 为配置文件并启用：

```sh
cp docs/openclash-ua3f.yaml /etc/openclash/config/openclash-ua3f.yaml
uci set openclash.config.enable='1'
uci set openclash.config.config_path='/etc/openclash/config/openclash-ua3f.yaml'
uci commit openclash
/etc/init.d/openclash restart
```

配置要点（防断网设计）：只有 **TCP 80** 走 UA3F（明文 HTTP 是检测方唯一能看到 UA 的地方），其余全部 DIRECT——UA3F 挂了只影响纯 HTTP 网页，不再全网断；私有网段和门户永远直连。注意 OpenClash 自管端口（mixed=7893、redirect=7892、dns=7874），yaml 里的 `mixed-port: 7890` 会被覆盖，属正常。

### 4. 防火墙加固（TTL/NTP/DNS）

```sh
sh docs/campus-detect-hardening.sh apply      # 先确认脚本里 WAN_IF 与实际一致
sh docs/campus-detect-hardening.sh status
```

fw4（OpenWrt 22.03+）系统用 `bootstrap-stack.sh` 部署，它会生成等价的 nftables drop-in（`/etc/nftables.d/campus-detect.nft`）。

### 5. 验证

```sh
# 门户与链路
/usr/bin/campus-auth --check; echo $?         # 0=在线
curl -4 --noproxy '*' --interface <WAN口> -o /dev/null -w '%{http_code}\n' https://www.baidu.com

# UA 统一（从局域网设备，必须 http 而非 https）
curl http://httpbin.org/user-agent            # 期望: 统一后的 Chrome UA

# 80 端口确实走了 UA3F
grep "using ua3f" /tmp/openclash.log | tail
```

LuCI 界面：**服务 → Campus Auth**（Status 实时状态 / Settings 配置）。

## 状态判定与 reason55 冷却

守护**不以** HTTP 204 探测作为认证依据，每轮调用 `campus-auth --check` 查询门户状态：

| `--check` 退出码 | 含义 | 守护行为 |
|---|---|---|
| `0` | 在线（`authState:2`） | 清零失败计数；登录后需一次在线确认才会再次认证 |
| `1` | 离线（`authState:1`） | 失败计数 +1，连续两次离线触发**恰好一次**登录 |
| `2` | 请求/解析错误 | 计数清零，**绝不**自动认证 |

登录响应含 `reasoncode:55`（服务器要求关闭代理/共享）时写入 `/etc/campus-auth.reason55`：守护与 LuCI 的 **Authenticate now** 按钮都会拒绝在冷却期登录；15 分钟后删除该标记手动重试一次。

## 触发检测后怎么办

按 [`docs/TEST-PLAN.md`](docs/TEST-PLAN.md) 的分阶段对照实验定位暴露向量：一次只改一个变量，利用 15 分钟冷却窗口逐项验证（UA → TTL → NTP/DNS → QUIC → VPS 全代理）。记录表和现场取证命令都在文档里。

## 多学校适配

认证协议为插件式分发：UCI `protocol` 选项加载 `/usr/share/campus-auth/proto/<name>.sh`。

| 协议 | 状态 | 说明 |
|---|---|---|
| `gportal` | **生产可用** | `auth_host`、`nas_name`、`aes_key` 均可配置 |
| `ruijie` | **预览，未经实站验证** | 锐捷 eportal，接入前抓包核对密码哈希与路径 |

新增学校/协议：实现 `proto_check` / `proto_login` 两个函数即可（退出码契约见 `campus-auth/files/campus-auth.sh` 头部注释），`settings.js` 的下拉框加一行。

## 从源码构建

仓库本身是一个 OpenWrt feed，CI（GitHub Actions）会在 main 与 `v*` tag 上自动构建 ipk（24.10 SDK）与 apk（25.12 SDK）双格式，打 tag 自动发布 Release：

```sh
curl -fLO https://downloads.openwrt.org/releases/24.10.8/targets/x86/64/openwrt-sdk-24.10.8-x86-64_gcc-13.3.0_musl.Linux-x86_64.tar.zst
tar --zstd -xf openwrt-sdk-*.tar.zst && cd openwrt-sdk-*
./scripts/feeds update -a && ./scripts/feeds install -a
echo "src-link campusauth /path/to/openwrt-campus-auth" >> feeds.conf.default
./scripts/feeds install -f campus-auth luci-app-campus-auth
make defconfig
echo 'CONFIG_PACKAGE_luci-app-campus-auth=m' >> .config && make defconfig
make package/campus-auth/compile package/luci-app-campus-auth/compile V=s
```

无 SDK 的本地快速打包：`python tools/build-ipk.py`。

## 故障排查

| 现象 | 处置 |
|---|---|
| 全部网页打不开、OpenClash 大量连向 127.0.0.1:1080 失败 | UA3F 没在跑：`/etc/init.d/ua3f start`，并确认已 `enable` |
| 只有 http 打不开，https 正常 | 规则正确但 UA3F 挂了（预期降级），重启 UA3F |
| 80 端口在 OpenClash 里走 DIRECT 而非 ua3f | 规则顺序被改，`DST-PORT,80,ua3f` 必须在 `MATCH` 前 |
| 门户认证失败 | 先停 OpenClash 验证是否代理引起；确认未开"本机代理"；`logread \| grep campus` |
| UA 没被改写 | `ps w \| grep ua3f` 看 `-x/-r/-f` 参数；路由器本机 `curl --socks5-hostname 127.0.0.1:1080 http://httpbin.org/user-agent` 隔离测试 |
| OpenClash 状态 running 但没接管流量 | 防火墙规则没装全（启动被打断），干净 `restart` 一次，看 `iptables -t mangle -S \| grep openclash` |
| 日志无内容 | 正常——日志只记录认证事件，一直在线就是空的 |

## 许可证

[Apache-2.0](LICENSE)。UA3F 为 [SunBK201](https://github.com/SunBK201/UA3F) 的独立开源项目，本方案仅做配置集成与文档。
