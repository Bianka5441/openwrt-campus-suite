# OpenWrt Campus Auth — 校园网认证守护 + 多设备共存工具箱

[![Build OpenWrt packages](https://github.com/Bianka5441/openwrt-campus-suite/actions/workflows/ci.yml/badge.svg)](https://github.com/Bianka5441/openwrt-campus-suite/actions/workflows/ci.yml)
![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)

> ⚠️ **免责声明**：本项目仅供网络协议学习与个人研究。使用前请了解所在网络服务条款，自行承担合规风险；请勿用于商业或破坏性用途。门户如明确要求停止共享（`reasoncode:55`），请先遵守。

---

## 一、这是什么？（新手从这里开始）

如果你把校园网线插到 OpenWrt 路由器上，让宿舍所有设备（手机、电脑、平板）都通过它上网，通常会遇到两个麻烦：

1. **掉线要手动登录**：每次连接或被踢下线，都得打开浏览器输一遍校园网账号密码；
2. **多设备会被检测**：校园网有办法看出"这一个 IP 后面其实有好几台设备"，发现后会限速或暂停使用（本项目作者的学校是暂停 15 分钟）。

这个仓库提供一套**在路由器上运行**的组合方案，同时解决这两个问题：

| 组件 | 解决什么 | 一句话原理 |
|---|---|---|
| **campus-auth**（本仓库核心） | 掉线自动重连 | 后台每分钟检查一次门户状态，掉线自动帮你登录，还带 LuCI 网页管理界面 |
| **UA3F**（第三方开源工具） | 多设备被识别（User-Agent 特征） | 把所有设备网页请求里的"设备身份证"（User-Agent）统一改写成同一条 |
| **OpenClash** | 流量编排 | 只把需要改 UA 的流量送进 UA3F，其余直连，任何单点故障都不影响全网 |
| **防火墙加固** | 另外三种检测手段 | 统一 TTL、统一时钟、统一 DNS |

**它不能做什么**（说清楚，避免误解）：校网如果检测"同时访问了多少不同网站"（SNI/行为画像），本方案不覆盖——需要一台自己的 VPS 做全流量代理，属于进阶玩法。

## 二、30 秒名词表

| 名词 | 大白话 |
|---|---|
| 门户 / Portal | 校园网的登录页面（本项目默认 `192.168.99.2`，你的学校可能不同） |
| 认证 / auth | 登录校园网这个动作，成功后这个 IP 才能上外网 |
| User-Agent (UA) | 浏览器访问网站时自报的"我是谁"字符串，Chrome/手机 Safari 各不相同 |
| TTL | 每个网络包的"剩余生命值"，每经过一台设备减 1，不同系统初始值不同（Windows 128、Linux 64） |
| NAT | 所有设备的流量从路由器同一个出口出去，外面的网站只看到一个 IP |
| opkg / apk | OpenWrt 的包管理器（老系统 opkg，25.12 以后 apk），相当于手机上的应用商店 |

## 三、准备清单

- [ ] 一台刷好 OpenWrt/ImmortalWrt 的路由器，能通过 LAN（网线或 WiFi）连上你的电脑
- [ ] 路由器已设置 root 密码（全新刷机的系统，先在 LuCI 首页"系统→管理权"里设置，否则无法 SSH）
- [ ] 校园网账号、密码
- [ ] 一台能上网的电脑（Windows 用 Git Bash / Linux / macOS 均可）

**选填**（换学校时才需要）：学校门户地址、门户协议类型、AES 密钥——见[第 8 节](#八、换一所学校)。

## 四、三条部署路径，选一条

| 路径 | 适合谁 | 路由器需要联网吗 |
|---|---|---|
| **A. 在线一键** | 最常见：路由器已插校园网线且手动登录过一次门户 | 需要 |
| **B. 纯离线** | 路由器全程没有外网，只有电脑能连它 | **完全不需要** |
| **C. 手动分步** | 想理解每一步原理、或 A/B 出问题排错时 | 分步需要 |

**路径 A 和 B 装的东西完全一样**，区别只是安装包从哪来。两条路径跑完，直接跳到[第 6 节验证](#六、部署后验证5-分钟)。

## 五、部署

### 路径 A：在线一键（最常用，约 10 分钟）

**第 1 步**：让路由器有网。门户认证是按 IP 记账的——用局域网里**任意设备**的浏览器手动登录一次校园网（`http://192.168.99.2` 或你学校的门户地址），整个路由器就都通了。

**第 2 步**：把部署脚本传到路由器并执行（在电脑上）：

```sh
scp tools/bootstrap-stack.sh root@192.168.6.1:/tmp/
ssh root@192.168.6.1
# 以下在路由器上执行：
USERNAME='你的学号' PASSWORD='你的密码' sh /tmp/bootstrap-stack.sh
```

**你会看到什么**：脚本依次打印 5 个步骤（装认证插件 → 装 UA3F → 配置 OpenClash → 防火墙加固 → 启动服务），最后输出 `portal: ONLINE` 或 `OFFLINE`。脚本会自动探测 CPU 架构、包管理器、防火墙版本和 WAN 口，**全程不需要你选**。

**第 3 步**：装 OpenClash 本体（脚本只写配置不装本体）：从 [OpenClash Releases](https://github.com/vernesong/OpenClash/releases) 下载 `luci-app-openclash` 的 ipk 传上去安装，然后**重跑一次脚本**完成配置接管。

### 路径 B：纯离线（路由器全程无外网）

场景：新路由器还没通过门户认证、拿不到外网，只有电脑能连它。原理：电脑有网，由电脑下载全部安装包推给路由器，离线安装；最后插校园网线时由插件自己完成首次认证。

在**电脑上**运行（会提示输入路由器密码）：

```sh
sh tools/pc-stage-and-deploy.sh root@192.168.6.1 \
     --username '你的学号' --password '你的密码' --with-openclash
```

如果电脑访问 GitHub 也不稳定，先把 5 个安装包下载到一个目录再跑（加 `--local-dir 该目录`）：仓库 Releases 页有 `campus-auth` 与 `luci-app-campus-auth`（ipk/apk 两种格式），UA3F 从 [SunBK201/UA3F Releases](https://github.com/SunBK201/UA3F/releases) 下载**对应路由器架构**的包。

**学校参数不同**（非默认的 gportal），加参数：

```sh
sh tools/pc-stage-and-deploy.sh root@192.168.6.1 \
     --username '...' --password '...' \
     --auth-host '门户IP' --nas-name '学校代号' \
     --protocol 'gportal 或 ruijie' --aes-key '门户页JS里的密钥'
```

### 路径 C：手动分步（理解原理用）

<details>
<summary>展开 5 个手动步骤</summary>

**1. 安装认证插件**：从 [Releases](https://github.com/Bianka5441/openwrt-campus-suite/releases) 下载 `campus-auth` 与 `luci-app-campus-auth` 两个包（架构无关，`all` 包），传到路由器后：

```sh
opkg install campus-auth_*.ipk luci-app-campus-auth_*.ipk
uci set campus-auth.config.username='学号'
uci set campus-auth.config.password='密码'
uci commit campus-auth && chmod 600 /etc/config/campus-auth
/etc/init.d/campus-auth enable && /etc/init.d/campus-auth start
```

**2. 安装 UA3F**：到 [SunBK201/UA3F Releases](https://github.com/SunBK201/UA3F/releases) 下载**与路由器架构一致**的包（架构看 `/etc/openwrt_release` 里的 `DISTRIB_ARCH`），然后：

```sh
opkg install ua3f_*_你的架构.ipk
cp docs/ua3f-config.example /etc/config/ua3f    # 统一 UA 配置（重要，见下方警告）
/etc/init.d/ua3f enable && /etc/init.d/ua3f restart
netstat -ln | grep 1080                          # 必须看到 127.0.0.1:1080 才继续
```

> **警告**：网上视频教程的 UA3F 旧版配置（`rewrite_rules` JSON 格式）与 3.6.0 新版**不兼容**，会导致"看似运行实则不改写"的静默失败。务必用本仓库 `docs/ua3f-config.example` 的格式。

**3. 安装并配置 OpenClash**：安装后：

```sh
cp docs/openclash-ua3f.yaml /etc/openclash/config/openclash-ua3f.yaml
uci set openclash.config.enable='1'
uci set openclash.config.config_path='/etc/openclash/config/openclash-ua3f.yaml'
uci commit openclash && /etc/init.d/openclash restart
```

配置的核心思想：**只有 TCP 80**（明文 HTTP，检测方唯一能看到 UA 的地方）走 UA3F，其余全部直连——这样 UA3F 挂了只影响 http 网页，不会全网断。

**4. 防火墙加固**：

```sh
sh docs/campus-detect-hardening.sh apply     # 先确认脚本内 WAN_IF 与实际一致
```

**5. 启动顺序**：UA3F 必须先于 OpenClash 就绪（脚本已处理）。

</details>

## 六、部署后验证（5 分钟）

逐项执行，每项都有预期结果：

| # | 检查 | 命令（路由器上） | 预期 |
|---|---|---|---|
| 1 | 门户在线 | `/usr/bin/campus-auth --check; echo $?` | `0` |
| 2 | UA3F 监听 | `netstat -ln \| grep 1080` | `127.0.0.1:1080` |
| 3 | UA3F 参数 | `ps w \| grep ua3f` | 含 `-x GLOBAL -f Mozilla/...` |
| 4 | 三服务 | `pgrep -f campus-auth-loop` / `ps \| grep [c]lash` | 都存在 |
| 5 | 加固在位 | `iptables -t mangle -S \| grep ttl`（fw3） | 有 `ttl-set 64` |

最后从**局域网电脑**上验证 UA 统一（必须 http 不是 https）：

```sh
curl http://httpbin.org/user-agent
```

期望返回统一后的 UA（如 `Chrome/133.0.0.0 (Windows NT 10.0; Win64; x64)`）——不管你用手机还是电脑发这个请求，结果都一样，就说明成功了。

**网页界面**：浏览器打开 `http://路由器IP/cgi-bin/luci` → **服务 → Campus Auth**：Status 页实时显示在线状态/最近认证结果/日志，Settings 页改配置。

## 七、日常使用

**掉线了怎么办？** 什么都不用做。守护每 60 秒检查一次门户，连续两次确认离线后自动重连（一般 2 分钟内恢复）。LuCI 状态页的"最近认证"会留下记录。

**遇到 `reasoncode:55`（检测到共享，暂停 15 分钟）？** 冷却期内插件**自动停手**，15 分钟后删除标记文件重试一次：

```sh
rm /etc/campus-auth.reason55
/usr/bin/campus-auth        # 手动重试一次
```

**换密码 / 换账号？** LuCI → Settings 页改，或 `uci set campus-auth.config.password='新密码'` + `uci commit`。

**触发检测反复出现？** 按 [docs/TEST-PLAN.md](docs/TEST-PLAN.md) 做分阶段对照实验，定位是哪个特征在暴露（UA 已统一的情况下，下一个通常是 TTL 或 QUIC）。

**踩坑了？** 先看 [docs/LESSONS.md](docs/LESSONS.md) ——24 条实机部署踩坑实录，很可能你遇到的就是其中一条。

## 八、换一所学校

认证协议是插件式的：UCI 的 `protocol` 选项决定加载哪个适配器。

| 协议 | 状态 | 需要配置 |
|---|---|---|
| `gportal`（默认） | 生产可用（作者学校长期运行） | `auth_host`、`nas_name`、`aes_key`（密钥在门户登录页的 JS 里找） |
| `ruijie` 锐捷 eportal | 预览，未经实站验证 | 同上，接入前先抓浏览器登录包核对 |

新增协议只需写一个几十行的脚本（实现 `proto_check`/`proto_login` 两个函数），详见 `campus-auth/files/campus-auth.sh` 头部注释。

## 九、常见问题 FAQ

**Q：https 网站的 UA 会被改吗？**
不会，也不需要。TLS 加密让检测方看不到 https 的 UA；明文 http 才是 UA 暴露的地方，UA3F 只处理它。

**Q：会拖慢网速吗？**
几乎不会。只有 80 端口流量进 UA3F 改写一个请求头，其余流量直连；实测路由器负载接近 0。

**Q：为什么脚本一定要先有网（路径 A）？**
安装包要从 GitHub 下载。全新路由器没过门户就没外网——先在局域网设备上手动登录一次门户（会话按 IP 生效），或者直接走路径 B 纯离线。

**Q：手机连上后要装什么吗？**
什么都不用。所有处理都在路由器侧，设备无感知。

**Q：和 UA2F 什么关系？**
UA2F 是更早的内核态方案（需要编译进系统），UA3F 是用户态服务（opkg 即装），本方案选 UA3F 因为部署简单且支持 SOCKS5 模式与 OpenClash 配合。

## 十、故障排查速查

| 现象 | 一句话处理 |
|---|---|
| 全网断，OpenClash 大量连接 127.0.0.1:1080 失败 | UA3F 没跑：`/etc/init.d/ua3f start`，确认已 enable |
| 只有 http 打不开，https 正常 | 规则正确但 UA3F 挂了（预期降级），重启 UA3F |
| UA 没被改写 | `ps w \| grep ua3f` 看参数是否 `-x GLOBAL`；`docs/LESSONS.md` 第 6 条 |
| OpenClash running 但流量没进代理 | 启动被打断规则没装全，干净 restart 一次 |
| 认证失败：reasoncode 27"密码错误" | 先逐字符核对凭据大小写，再查套餐是否到期（门户把多种失败都报成这条） |
| 认证失败：reasoncode 55 | 真实检测信号，按第 7 节冷却 15 分钟 |
| 日志是空的 | 正常——日志只记认证事件，一直在线就是空的 |

更完整的踩坑案例：[docs/LESSONS.md](docs/LESSONS.md)。

## 十一、从源码构建

仓库本身是一个 OpenWrt feed，CI 会在 main 与 `v*` tag 上自动构建 ipk（24.10 SDK）与 apk（25.12 SDK）双格式，打 tag 自动发 Release：

```sh
./scripts/feeds update -a && ./scripts/feeds install -a
echo "src-link campusauth /path/to/openwrt-campus-auth" >> feeds.conf.default
./scripts/feeds install -f campus-auth luci-app-campus-auth
make defconfig && echo 'CONFIG_PACKAGE_luci-app-campus-auth=m' >> .config && make defconfig
make package/campus-auth/compile package/luci-app-campus-auth/compile V=s
```

无 SDK 本地快速打包：`python tools/build-ipk.py`。

## 十二、许可证与致谢

[Apache-2.0](LICENSE)。UA3F 为 [SunBK201](https://github.com/SunBK201/UA3F) 的独立开源项目，OpenClash 为 [vernesong](https://github.com/vernesong/OpenClash) 的独立开源项目，本方案仅做配置集成与文档。
