-- Legacy-LuCI settings form for campus-auth (server-rendered CBI).
-- Mirrors the modern client-side settings view: same UCI options.

local m, s, o

m = Map("campus-auth", "校园网认证助手",
	"账号、认证协议与防护模式都在这里设置。更改后点击「保存并应用」生效。")

s = m:section(NamedSection, "config", "campus-auth", "运行模式")
s.addremove = false

o = s:option(ListValue, "mode", "当前模式")
o:value("normal", "① 普通路由器（不认证、不伪装）")
o:value("anti-detect", "② 校园网认证 + 反检测（UA3F/加固/OpenClash）")
o:value("proxy", "③ 反检测 + 梯子（含 UA3F 重定向模板）")
o.default = "normal"
o.rmempty = false
o.description = "选「①」就是纯普通路由器：不自动登录校园网、不装任何伪装。选「②/③」才启用自动登录。"

o = s:option(Flag, "enabled", "启用后台守护")
o.default = o.enabled
o.rmempty = false
o.description = "每分钟检查一次门户状态，掉线自动重连（仅 ②/③ 模式运行）。"

s = m:section(NamedSection, "config", "campus-auth", "账号与认证")
s.addremove = false

o = s:option(ListValue, "protocol", "认证协议")
o:value("gportal", "gportal（主流校园门户）")
o:value("ruijie", "锐捷 eportal（预览）")
o.default = "gportal"
o.description = "学校门户的认证方式。"

o = s:option(Value, "username", "账号")
o.rmempty = false
o.description = "校园网账号（学号或手机号）。"

o = s:option(Value, "password", "密码")
o.password = true
o.rmempty = false

o = s:option(Value, "auth_host", "门户服务器")
o.placeholder = "192.168.99.2"
o.description = "校园网认证页的 IP（不带 http:// 和路径）。"

o = s:option(Value, "nas_name", "NAS 名称")
o.placeholder = "GKDX"
o.description = "门户的 wlanacname 参数（gportal 协议使用）。"

o = s:option(Value, "aes_key", "门户 AES 密钥")
o.placeholder = "1234567887654321"
o.description = "gportal 登录页 JS 里的 AES-128 密钥，一般不用改。"

o = s:option(Value, "interface", "上网网口（可选）")
o.placeholder = "自动识别"
o.description = "接校园网的物理网口（如 eth1）。留空自动识别。"

s = m:section(NamedSection, "config", "campus-auth", "调度与省配额")
s.addremove = false

o = s:option(Value, "interval", "检查间隔（秒）")
o.default = "60"

o = s:option(Flag, "quiet_enable", "夜间断网静默")
o.default = o.enabled
o.description = "静默时段内完全不发认证请求，省设备绑定配额。"

o = s:option(Value, "quiet_start", "静默开始")
o.placeholder = "00:00"
o.default = "00:00"

o = s:option(Value, "quiet_end", "静默结束")
o.placeholder = "06:00"
o.default = "06:00"
o.description = "恢复后自动做当天第一笔登录。"

o = s:option(Value, "login_holdoff", "登录失败退避（秒）")
o.default = "900"
o.description = "被门户拒绝后等多久再试，避免反复撞墙。"

return m
