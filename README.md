# OpenWrt Campus Auth

[![Build OpenWrt packages](https://github.com/Bianka5441/openwrt-campus-auth/actions/workflows/ci.yml/badge.svg)](https://github.com/Bianka5441/openwrt-campus-auth/actions/workflows/ci.yml)
![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)

在 OpenWrt 路由器上自动完成 **gportal 型校园网 Portal 认证**的插件:后台守护进程掉线自动重连,并提供 **LuCI Web 界面**用于输入校园网账号密码、查看网络状态和手动触发认证。

脚本完全复刻浏览器登录流程(已通过 HAR 抓包核对):每次认证先抓取登录页获取新鲜的 `sign` / `iv` 字段,再用 AES-128-CBC(密钥 `1234567887654321`,ZeroPadding)加密表单后 POST 到 `/gportal/web/authLogin`。

> 与 [UA3F](https://github.com/SunBK201/UA3F)/OpenClash 那类"改写 UA 绕过多设备检测"的方案完全互补:本插件负责**认证上线**,上线之后的多设备共享方案可以另行部署。

## 组成

| 包名 | 说明 |
|---|---|
| `campus-auth` | 后端:`/usr/bin/campus-auth` 认证脚本、`campus-auth-loop` 探测守护、procd init 服务、rpcd ubus 状态接口 |
| `luci-app-campus-auth` | 前端:LuCI 界面(**Services → Campus Auth**),依赖 `campus-auth` |

LuCI 界面提供:

- **Status 页**:实时网络连通性(HTTP 204 探测)、认证 Portal 地址、校园网 IP、后台服务运行状态、最近一次认证结果、认证日志(每 5 秒刷新),以及 **Authenticate now** 手动认证按钮;
- **Settings 页**:账号、密码、Portal 地址、NAS 名(wlanacname)、探测 URL、绑定网卡、探测间隔,基于 UCI 配置(`Save & Apply` 自动重载服务)。

## 安装

### 方式一:从 Release 下载安装(推荐)

到 [Releases](https://github.com/Bianka5441/openwrt-campus-auth/releases) 下载与你路由器架构无关的 `all` 包(`PKGARCH=all`,纯脚本):

```sh
# OpenWrt 24.10 及更早(opkg / ipk)
cd /tmp
wget -O campus-auth.ipk       https://github.com/Bianka5441/openwrt-campus-auth/releases/latest/download/campus-auth_..._all.ipk
wget -O luci-app.ipk          https://github.com/Bianka5441/openwrt-campus-auth/releases/latest/download/luci-app-campus-auth_..._all.ipk
opkg install campus-auth.ipk luci-app.ipk
/etc/init.d/campus-auth enable && /etc/init.d/campus-auth start
```

```sh
# OpenWrt 25.12 及以后(APK 包管理器)
cd /tmp
wget -O campus-auth.apk  https://github.com/Bianka5441/openwrt-campus-auth/releases/latest/download/campus-auth_..._all.apk
wget -O luci-app.apk     https://github.com/Bianka5441/openwrt-campus-auth/releases/latest/download/luci-app-campus-auth_..._all.apk
apk add --allow-untrusted campus-auth.apk luci-app.apk
/etc/init.d/campus-auth enable && /etc/init.d/campus-auth start
```

> 说明:OpenWrt 自 24.10 起仍使用 `opkg`(ipk),新的 25.x 系列改用 Alpine 式的 `apk` 包管理器(**这里的 apk 指 OpenWrt 新包格式,不是安卓 APK**)。CI 会同时产出两种格式。

### 方式二:添加为软件源 feed

```sh
# opkg(24.10)
echo 'src-git campusauth https://github.com/Bianka5441/openwrt-campus-auth.git' >> /etc/opkg/customfeeds.conf
opkg update && opkg install luci-app-campus-auth

# apk(25.12)在 /etc/apk/repositories.d/ 下新增一行指向包含本包的仓库索引后:
# apk update && apk add luci-app-campus-auth
```

### 配置

LuCI 界面(**Services → Campus Auth → Settings**)或直接编辑 `/etc/config/campus-auth`:

| UCI 选项 | 默认值 | 说明 |
|---|---|---|
| `enabled` | `1` | 是否启动后台守护(procd) |
| `protocol` | `gportal` | 门户认证协议,见下方"适配其他学校" |
| `username` / `password` | 空 | 校园网账号密码 |
| `auth_host` | `192.168.99.2` | 认证 Portal 服务器地址 |
| `nas_name` | `GKDX` | `wlanacname` 参数(gportal 协议) |
| `aes_key` | `1234567887654321` | gportal 登录表单的 AES-128 密钥,不同学校可能不同 |
| `check_url` | hicloud generate_204 | 连通性探测 URL(需 HTTP 204),**仅用于界面展示**;gportal 的认证决策一律以 Portal 状态接口为准 |
| `interface` | 空 | 绑定校园网上行口(如 `eth1`、`eth0.2` VLAN、`pppoe-wan`),留空自动探测;LuCI 里是真实网口下拉框 |
| `interval` | `60` | 探测间隔(秒,最小 30) |

命令行等价操作:

```sh
uci set campus-auth.config.username='你的学号'
uci set campus-auth.config.password='你的密码'
uci commit campus-auth
/etc/init.d/campus-auth restart
```

### 状态判定与冷却(reason 55)

后台守护**不以** HTTP 204 探测作为认证依据,而是每轮调用 `/usr/bin/campus-auth --check` 查询 Portal 的 `queryAuthState`:

| `--check` 退出码 | 含义 | 守护行为 |
|---|---|---|
| `0` | 在线(`authState:2`) | 清零失败计数;连续登录后需等到一次在线确认才会再次认证 |
| `1` | 离线(`authState:1`) | 失败计数 +1,连续两次离线触发**恰好一次**登录 |
| `2` | 请求/解析错误 | 计数清零,**绝不**自动认证 |

登录响应包含 `reasoncode:55` 时(服务器要求关闭代理/共享并等待),脚本写入 `/etc/campus-auth.reason55` 冷却标记:守护循环与 LuCI 的 **Authenticate now** 按钮都会拒绝在冷却期内发起登录;15 分钟后手动删除该标记再重试一次。

日志:`logread | grep campus-auth` 或 `cat /var/log/campus-auth.log`。

## 从源码构建

仓库本身就是一个 OpenWrt feed,SDK 中如下构建:

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

GitHub Actions 会在 `main` 分支和 tag 上自动构建 ipk(24.10.8 SDK)与 apk(25.12.5 SDK)两种产物,打 `v*` tag 时自动发布 Release。

## 适配其他学校

认证协议做成了插件式分发:UCI 的 `protocol` 选项决定加载 `/usr/share/campus-auth/proto/<protocol>.sh`。内置两个协议:

| 协议 | 状态 | 说明 |
|---|---|---|
| `gportal` | **生产可用**(本仓库作者的学校长期运行) | gportal 家族:`/gportal/web/authLogin`,AES-128-CBC(密钥 `1234567887654321`,不同学校可在 `aes_key` 里改),`queryAuthState` 查状态 |
| `ruijie` | **预览,未经实站验证** | 锐捷 eportal:离线时 HTTP 探测会被 302 到 eportal,携带 `queryString` POST `/eportal/InterFace.do?method=login`。部分学校密码需要哈希或路径不同,接入前请抓包核对 |

**新增一个学校/协议**只需三步:

1. 写 `/usr/share/campus-auth/proto/<name>.sh`,实现两个函数(分发器会提供 helpers 和配置环境):

```sh
# 退出码:0 在线 / 1 离线 / 2 未知错误。失败时保持安静(不写日志)。
proto_check() { ... }

# 退出码:0 成功 / 55 门户要求冷却(分发器自动写冷却标记) / 其他=失败。
# 失败前设置 REJECT_MSG="简短原因"(不要包含密码)。
proto_login() { ... }
```

2. 可用的环境与 helpers:`MODE`(`--check` 或空)、`USERNAME`、`PASSWORD`、`AUTH_HOST`、`NAS_NAME`、`AES_KEY`、`CHECK_URL`、`INTERFACE`、`CURL_IF`(curl 绑定参数)、`USER_IP`(尽力探测)、`TMP`(临时文件前缀)、`UA`;函数 `log`、`write_state`、`urlencode`、`field`(解析 `$TMP.html` 中的表单域)。

3. LuCI 的"Portal protocol"下拉框会自动出现该协议——不过下拉列表写死在 `settings.js` 里,新协议需在其中加一行 `o.value('<name>', '<说明>')`。

协议参数(gportal 家族)都可配置:`auth_host`、`nas_name`、`aes_key`。新学校接入时抓一次浏览器登录的 HAR 核对表单字段与密钥即可。

## 许可证

[Apache-2.0](LICENSE)

---

**English**: OpenWrt package (ipk for 24.10 / apk for 25.12+) that automatically authenticates against gportal-style campus network portals via AES-128-CBC encrypted POST requests, with a procd-supervised connectivity monitor and a LuCI web interface for credentials, live status and manual authentication. See the sections above; the code is self-documenting and the CI builds both package formats.
