'use strict';
'require view';
'require form';
'require rpc';

var callInterfaces = rpc.declare({
	object: 'campus-auth',
	method: 'interfaces',
	expect: { devices: [] }
});

var modeCards = [
	{
		title: '① 普通路由器',
		value: 'normal',
		color: '#9e9e9e',
		lines: ['只做校园网自动登录', '不做任何伪装和代理', '适合：学校不查多设备']
	},
	{
		title: '② 认证 + 反检测',
		value: 'anti-detect',
		color: '#1e88e5',
		lines: ['自动登录 + 防多设备检测', '统一 UA / TTL，NTP·DNS 走路由器', '关闭 LAN IPv6，不装梯子']
	},
	{
		title: '③ 反检测 + 梯子',
		value: 'proxy',
		color: '#43a047',
		lines: ['反检测全部功能 + OpenClash', '订阅、节点在 OpenClash 里管理', '当前推荐模式']
	}
];

return view.extend({
	render: function() {
		return L.resolveDefault(callInterfaces(), []).then(function(devices) {
			var cards = E('div', { 'style': 'display:flex;gap:10px;flex-wrap:wrap;margin:0 0 6px 0' });

			modeCards.forEach(function(c) {
				cards.appendChild(E('div', {
					'style': 'flex:1;min-width:200px;border:2px solid %s;border-radius:10px;padding:10px 12px;background:rgba(255,255,255,.65)'.format(c.color)
				}, [
					E('div', { 'style': 'font-size:110%;font-weight:bold;color:%s;margin-bottom:4px'.format(c.color) }, c.title),
					E('div', { 'style': 'font-size:90%;line-height:1.6' }, c.lines.map(function(l, i) {
						return E('div', {}, (i == 0 ? '' : '· ') + l);
					}))
				]));
			});

			cards.appendChild(E('div', { 'style': 'flex-basis:100%;font-size:90%;color:#666' },
				'切换模式后点「保存并应用」立即生效（开机也会自动应用）。未安装 UA3F / OpenClash 时自动降级，不会报错。'));

			var m = new form.Map('campus-auth', '校园网认证助手',
				'登录账号、认证协议与防护模式都在这里设置。');

			var s1 = m.section(form.NamedSection, 'config', 'campus-auth', '运行模式');
			s1.addremove = false;

			var o = s1.option(form.ListValue, 'mode', '当前模式');
			o.value('normal', '① 普通路由器（仅自动认证）');
			o.value('anti-detect', '② 校园网认证 + 反检测');
			o.value('proxy', '③ 反检测 + 梯子（OpenClash）');
			o.default = 'normal';
			o.rmempty = false;

			o = s1.option(form.Flag, 'enabled', '启用后台守护');
			o.default = o.enabled;
			o.rmempty = false;
			o.description = '每分钟检查一次门户状态，掉线自动重连。';

			var s2 = m.section(form.NamedSection, 'config', 'campus-auth', '账号与认证');
			s2.addremove = false;

			o = s2.option(form.ListValue, 'protocol', '认证协议');
			o.value('gportal', 'gportal（主流校园门户）');
			o.value('ruijie', '锐捷 eportal（预览）');
			o.default = 'gportal';
			o.description = '学校门户的认证方式。新学校可自行添加 /usr/share/campus-auth/proto/<名称>.sh 适配。';

			o = s2.option(form.Value, 'username', '账号');
			o.rmempty = false;
			o.description = '校园网账号（学号或手机号）。';

			o = s2.option(form.Value, 'password', '密码');
			o.password = true;
			o.rmempty = false;

			o = s2.option(form.Value, 'auth_host', '门户服务器');
			o.placeholder = '192.168.99.2';
			o.description = '校园网认证页的 IP（不带 http:// 和路径）。';

			o = s2.option(form.Value, 'nas_name', 'NAS 名称');
			o.placeholder = 'GKDX';
			o.description = '门户的 wlanacname 参数（gportal 协议使用）。';

			o = s2.option(form.Value, 'aes_key', '门户 AES 密钥');
			o.placeholder = '1234567887654321';
			o.description = 'gportal 登录页 JS 里的 AES-128 密钥，一般不用改。';

			o = s2.option(form.Value, 'check_url', '联网检测地址');
			o.placeholder = 'http://connectivitycheck.platform.hicloud.com/generate_204';
			o.description = '仅用于状态页显示；登录决策以门户状态接口为准。';

			o = s2.option(form.ListValue, 'interface', '上网网口（可选）');
			o.value('', '自动识别');
			(devices || []).forEach(function(d) {
				o.value(d, d);
			});
			o.description = '接校园网的物理网口（如 eth1）。选错会导致无法认证；不确定就保持自动。';

			var s3 = m.section(form.NamedSection, 'config', 'campus-auth', '调度与省配额');
			s3.addremove = false;

			o = s3.option(form.Value, 'interval', '检查间隔（秒）');
			o.datatype = 'range(30,3600)';
			o.default = '60';

			o = s3.option(form.Flag, 'quiet_enable', '夜间断网静默');
			o.default = o.enabled;
			o.description = '静默时段内完全不发认证请求。每次重新登录都可能消耗账号的设备绑定配额，登录越少越省。';

			o = s3.option(form.Value, 'quiet_start', '静默开始');
			o.placeholder = '00:00';
			o.datatype = 'time';
			o.description = '校园网断网时间（时:分）。';

			o = s3.option(form.Value, 'quiet_end', '静默结束');
			o.placeholder = '06:00';
			o.datatype = 'time';
			o.description = '校园网恢复时间（时:分），恢复后自动做当天第一笔登录。';

			o = s3.option(form.Value, 'login_holdoff', '登录失败退避（秒）');
			o.datatype = 'range(60,86400)';
			o.default = '900';
			o.description = '被门户拒绝（如绑定配额用完）后，等多久再试，避免反复撞墙。';

			return E([ cards, m.render() ]);
		});
	}
});
