# 架构与设计思路

> 本文档回答"这套东西为什么长这样"。逐步的实现细节与踩坑实录见 [LESSONS.md](LESSONS.md),部署操作见 [README](../README.md)。

## 一、一句话目标

**一台刷好 OpenWrt 的路由器,插上校园网线就是可用状态**:自动登录、多设备不被识别、坏了自己爬起来;装它的过程也必须是一条命令、零交互、一次到位。

## 二、设计原则

这五条是从实机事故里长出来的,改代码前先对照:

1. **一次到位(one-shot)**:所有配置进安装脚本,现场零交互。刷机时不许出现"装完还要手工补两步"——凡是需要补的步骤都算脚本的 bug,当场修进脚本(每刷一台优化一次安装脚本)。
2. **验证不过关不下班**:安装器和模式切换的每一步都有显式验证(文件清单、模式值、监听口、核心进程、透明接口),失败必须 FAIL 退出,绝不静默降级——静默降级是历史上最贵的一类事故(见 LESSONS #28)。
3. **凭据是禁区**:安装器对已有凭据只保留不覆写;日志、状态、文档、仓库任何地方不回显凭据;GitHub 仓库不出现任何真实账号/密码/手机号。
4. **自愈优先于人工**:路由器长期无人值守,一切"偶尔会挂"的东西(OpenClash 核心、加固规则、TTL 内核模块)都要有 60 秒级守护或热插拔触发,而不是等用户发现没网。
5. **UI 只读缓存**:LuCI 状态页毫秒级渲染(读 `/tmp` 探针缓存),探测链全部后台化——老路由器的串行探测能把页面卡死 6 秒(LESSONS #26)。

## 三、三种模式

| 模式 | 启动什么 | 停掉什么 | 典型用途 |
|---|---|---|---|
| ① `normal` | 仅 campus-auth 停止认证 | UA3F、OpenClash、加固规则,恢复 IPv6 | 不需要认证功能 |
| ② `anti-detect` | 认证守护 + UA3F + OpenClash(UA3F 模板,80 端口改写 UA)+ TTL/NTP/DNS 加固 + 关 LAN IPv6 | — | 查多设备、不要梯子 |
| ③ `proxy` | ② 的全部 + UA3F 重定向模板 | — | 之后要在 OpenClash 里加订阅 |

模式管理器(`campus-auth-mode.sh`)是幂等的:重复应用同模式无害,切回 ① 会干净还原所有副作用。

## 四、反检测链路

检测方在看什么,我们就在什么上做文章:

```
LAN 客户端 ── 80/tcp ──▶ PREROUTING (fwmark 0x162)
                              │ 策略路由 table 354
                              ▼
                          utun (redir-host-tun)
                              │ clash 规则: DST-PORT,80 → ua3f
                              ▼
                     UA3F (SOCKS5 127.0.0.1:1080, GLOBAL Chrome UA)
                              │ 其余流量 MATCH,DIRECT
                              ▼
                          校园网出口
```

同时防火墙加固抹掉另外三个指纹:

| 指纹 | 对策 | 生效时机 |
|---|---|---|
| TTL 差异(Windows 128 / Linux 64) | mangle POSTROUTING `TTL --ttl-set 64`(出口设备统一) | 内核模块缺失时,守护循环首次在线周期自动 `opkg install kmod-ipt-ipopt` 后补齐 |
| 时钟偏移 | NTP 重定向到本机 + `sysntpd` 服务端 | 插线即生效(规则基于出口设备,无 IP 也能先打上) |
| 外部 DNS 查询(绕过路由器) | 53 端口重定向到 dnsmasq | 同上 |
| IPv6 侧信道 | `dhcp.lan` 的 RA/DHCPv6 关闭 | 切模式即生效,切回恢复 |

**设计取舍**:只有 80 端口进代理。https 的 UA 检测方本来就看不见;只改明文 http 意味着 UA3F/OpenClash 任何一环挂掉,影响面只有 http 网页,不会全网断。

## 五、认证生命周期与配额

- **守护节奏**:每 60 秒一个周期;连续两次确认离线才发起登录;夜间静默窗口(默认 00:00–06:00)完全不动作;失败按 `login_holdoff` 退避。
- **探针**:`--probe` 把 HTTP/UA3F/OpenClash/loop/加固五项状态写进 `/tmp/campus-auth.probe`(原子写),UI 和远程巡检都只读它;`--check` 是人工排障用的门户状态查询。
- **配额模型(实测)**:门户绑定 = **账号 × 物理位置(网口)**。复用绑定不消耗;换位置登录消耗;`reasoncode:7` = 次数用完。
- **省配额与自愈**:
  - reasoncode:7 → 先尝试**自己换绑给自己**(reBindMac = 本机 MAC,移动既有绑定,实测可不消耗次数;r13 起),失败再退避;
  - reasoncode:43 → 门户主动发换绑提议,bindmac 等于本机才自动确认(v1.0.10 起);
  - reasoncode:55 → 冷却 15 分钟自动过期;
  - 全部记录在日志,状态页可见。
- **时钟纪律**:断电重启后无 RTC 时钟会漂移,所有时间调度(静默窗口、暂停过期)先对表再谈;flash.sh 收尾自动从 PC 同步一次。

## 六、自愈体系

三层,从事件驱动到轮询兜底:

1. **netifd 热插拔**(`/etc/hotplug.d/iface/99-campus-auth`):ifup 后每 5 秒查一次默认路由,最长等 2 分钟——覆盖"插线晚/校园网 DHCP 慢"。加固规则基于出口设备名,无 IP 也能先应用,所以大多数场景插线即生效。
2. **60 秒守护循环**(`campus-auth-loop.sh`):每周期自检——OpenClash 核心死了就置 `openclash.config.enable=1` 拉起(避开 ucitrack 重启风暴,值没变不 commit);加固规则丢了且路由可达就重新 apply;TTL 内核模块缺失且已联网就 `opkg install` 一次性补上,再重新应用模式。
3. **安装器收尾验证**:部署时就保证关键组件在线(UA3F 监听轮询、核心进程轮询带一次自愈、utun 接口存在性),自愈只是长期保险,不是首次配置手段。

## 七、部署流水线

```
python tools/build-ipk.py            # 本地打包(文件清单必须与 Makefile 对表,LESSONS #28)
        │
        ▼
/tmp/campus-suite-offline/           # 离线 bundle:两个插件 ipk + ua3f_<arch>.ipk + install-campus-suite.sh
        │
        ▼
sh tools/flash.sh <ip> [user pass]   # PC 侧:scp 上传 → 安装器 → 时钟同步 → 清理
        │
        ▼
install-campus-suite.sh              # 路由器侧:双架构自检 → conffile 恢复 → ua3f 复用/安装并置开关
        │                            #   → OpenClash 模板预设 → 凭据策略 → 落地模式② → 15 项验证
        ▼
刷完自检(README"模式②全功能自检")    # UA 改写实测 + 自愈实测,每台必做
```

安装器的三条自动化兜底:opkg 同版本重装不恢复 conffile(`--force-reinstall` + tar 提取双保险);ua3f 已装则复用二进制但强制纠正配置;`ua3f.enabled.enabled` 默认为 0 是个静默陷阱(LESSONS #28),一律置 1。

## 八、兼容矩阵

| 组件 | mt7621(24.10.3, fw3 + iptables-legacy) | mt7981(21.02-SNAPSHOT, DSA) |
|---|---|---|
| campus-auth / LuCI | ✅ Lua 旧版 dispatcher(注意 tparser 限制,LESSONS #26) | ✅ 现代客户端渲染 |
| UA3F | ✅ mipsel 包 | ✅ aarch64 包 |
| OpenClash | ✅ 核心路径两种布局都兼容 | ✅ |
| TTL 模块 | feed 在线补装(守护循环) | 同左 |
| failsafe 救援 | — | **只监听 LAN1 口**(LESSONS #31) |

## 九、安全与隐私边界

- 仓库中**不允许出现**:任何真实账号、密码、手机号、临时调试用密码。每次发布前 grep 校验(手机号正则 + 已知敏感串)。
- `/etc/config/campus-auth` 权限 600;日志只记事件与 IP,不记凭据。
- README 与本文档使用占位符(`你的学号` / `你的密码`)示范。

## 十、已知限制与后续方向

- **不覆盖 SNI/行为画像**:检测方若统计"一个 IP 后访问了多少不同站点",本方案无解——需要全流量代理(模式 ③ 加订阅是入口)。
- TTL 模块在首次联网时才补装(离线窗口期 TTL 未统一,属于已知可接受窗口)。
- 配额自愈的 reasoncode:7 自换绑(r13)尚待下一次真实断网清晨的实战确认。
- 多台路由器同账号会互相消耗绑定配额:**一台一个账号一个网口**,别搬。
