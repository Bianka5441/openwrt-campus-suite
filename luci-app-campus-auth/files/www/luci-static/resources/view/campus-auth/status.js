'use strict';
'require view';
'require dom';
'require poll';
'require rpc';
'require ui';

var callStatus = rpc.declare({
	object: 'campus-auth',
	method: 'status'
});

var callLog = rpc.declare({
	object: 'campus-auth',
	method: 'log',
	params: [ 'lines' ],
	expect: { log: '' }
});

var callAuthenticate = rpc.declare({
	object: 'campus-auth',
	method: 'authenticate'
});

var callPauseToday = rpc.declare({
	object: 'campus-auth',
	method: 'pause_today'
});

var callResume = rpc.declare({
	object: 'campus-auth',
	method: 'resume_auth'
});

var modeInfo = {
	normal:      { name: '普通路由器模式', color: '#9e9e9e', desc: '仅校园网自动登录，无伪装、无代理' },
	'anti-detect': { name: '反检测模式',   color: '#1e88e5', desc: '统一 UA / TTL · NTP·DNS 走路由器 · IPv6 已关闭' },
	proxy:       { name: '反检测 + 梯子模式', color: '#43a047', desc: '反检测全部功能 + OpenClash 代理运行中' }
};

function fmtResult(r) {
	switch (r) {
		case 'success':  return '成功';
		case 'failed':   return '失败';
		case 'cooldown': return '门户暂停（15 分钟冷却）';
		default:         return '-';
	}
}

function chip(label, on, onText, offText) {
	var color = on ? '#43a047' : '#e53935';
	var text = on ? (onText || '运行中') : (offText || '已停止');
	return E('span', { 'style': 'display:inline-block;margin:2px 6px 2px 0;padding:2px 10px;border-radius:12px;border:1px solid %s;color:%s;font-size:90%%'.format(color, color) },
		'%s：%s'.format(label, text));
}

return view.extend({
	handleAuthenticate: function(ev) {
		var btn = ev.target;
		btn.disabled = true;
		btn.classList.add('spinning');

		return callAuthenticate().then(function(res) {
			if (res && res.result)
				ui.addNotification(null,
					E('p', '已触发认证，下方状态稍后自动更新。'),
					'info');
			else
				ui.addNotification(null,
					E('p', '触发失败：%s'.format((res && res.message) || '未知错误')),
					'error');
		}).catch(function(e) {
			ui.addNotification(null,
				E('p', '触发失败：%s'.format(e.message || e)),
				'error');
		}).finally(function() {
			btn.disabled = false;
			btn.classList.remove('spinning');
		});
	},

	handlePauseToday: function(ev) {
		var btn = ev.target;
		btn.disabled = true;
		return callPauseToday().then(function(res) {
			ui.addNotification(null,
				E('p', (res && res.message) || '已暂停'),
				'info');
		}).catch(function(e) {
			ui.addNotification(null, E('p', '操作失败：%s'.format(e.message || e)), 'error');
		}).finally(function() {
			btn.disabled = false;
		});
	},

	handleResume: function(ev) {
		var btn = ev.target;
		btn.disabled = true;
		return callResume().then(function(res) {
			ui.addNotification(null,
				E('p', (res && res.message) || '已恢复'),
				'info');
		}).catch(function(e) {
			ui.addNotification(null, E('p', '操作失败：%s'.format(e.message || e)), 'error');
		}).finally(function() {
			btn.disabled = false;
		});
	},

	render: function() {
		var banner = E('div', { 'style': 'display:flex;align-items:center;gap:14px;border-left:6px solid #ccc;border-radius:6px;padding:12px 16px;margin-bottom:14px;background:rgba(255,255,255,.65);flex-wrap:wrap' }, [
			E('div', { 'style': 'font-size:80%;color:#888' }, '加载中…')
		]);

		var table = E('table', { 'class': 'table' });

		var logBox = E('pre', {
			'style': 'max-height:24em; overflow:auto; white-space:pre-wrap; padding:.6em; '
				+ 'border:1px solid #d4d4d4; font-size:.9em'
		}, '加载中…');

		poll.add(L.bind(function() {
			return Promise.all([ callStatus(), callLog(200) ]).then(L.bind(function(data) {
				var st = data[0];
				var mi = modeInfo[st.mode] || { name: st.mode || '-', color: '#9e9e9e', desc: '' };

				var conn;
				if (st.online) {
					conn = '已联网（HTTP %s）'.format(st.http_code);
				}
				else {
					conn = '无网络（HTTP %s）'.format(st.http_code || '-');
					if (st.redirect)
						conn += ' → ' + st.redirect;
				}

				var svc;
				if (st.service_enabled)
					svc = st.service_running ? '运行中' : '未运行';
				else
					svc = '已停用';

				if (st.cooldown)
					svc += ' · 门户冷却中（检测到共享，15 分钟后自动恢复）';

				if (st.paused_today)
					svc += ' · 今日已暂停自动认证（配额保护）';

				var chips = E('div', { 'style': 'flex:1;min-width:220px' });
				if (st.mode && st.mode !== 'normal') {
					chips.appendChild(chip('网络', st.online, '已联网', '未认证'));
					chips.appendChild(chip('UA 统一 (UA3F)', st.ua3f_running));
					chips.appendChild(chip('TTL/NTP/DNS 加固', st.hardening, '已生效', '未生效'));
					if (st.mode === 'proxy')
						chips.appendChild(chip('OpenClash 梯子', st.openclash_running));
				}
				else {
					chips.appendChild(chip('网络', st.online, '已联网', '未认证'));
				}

				dom.content(banner, [
					E('div', { 'style': 'min-width:200px' }, [
						E('div', { 'style': 'font-size:130%;font-weight:bold;color:%s'.format(mi.color) }, mi.name),
						E('div', { 'style': 'font-size:85%;color:#666;margin-top:2px' }, mi.desc)
					]),
					chips
				]);

				var last = '-';
				if (st.last_time)
					last = '%s · %s%s'.format(st.last_time, fmtResult(st.last_result),
						st.last_message ? ' — ' + st.last_message : '');

				dom.content(table, [
					E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class': 'th' }, '项目'),
						E('th', { 'class': 'th' }, '状态')
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, '网络状态'),
						E('td', { 'class': 'td' }, conn)
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, '门户服务器'),
						E('td', { 'class': 'td' }, st.auth_host || '-')
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, '校园网 IP'),
						E('td', { 'class': 'td' }, st.user_ip || '-')
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, '后台守护'),
						E('td', { 'class': 'td' }, svc)
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, '最近一次认证'),
						E('td', { 'class': 'td' }, last)
					])
				]);

				logBox.textContent = data[1] || '暂无日志。';
			}, this));
		}, this), 5);

		var button = E('button', {
			'class': 'btn cbi-button cbi-button-action important',
			'click': ui.createHandlerFn(this, 'handleAuthenticate')
		}, [ '立即认证' ]);

		var pauseBtn = E('button', {
			'class': 'btn cbi-button cbi-button-negative',
			'click': ui.createHandlerFn(this, 'handlePauseToday')
		}, [ '今日暂停认证' ]);

		var resumeBtn = E('button', {
			'class': 'btn cbi-button cbi-button-positive',
			'click': ui.createHandlerFn(this, 'handleResume')
		}, [ '恢复今日认证' ]);

		return E([
			E('h2', {}, '校园网认证状态'),
			E('div', { 'class': 'cbi-map-descr' },
				'当前防护模式与各组件运行状态实时显示在顶部；切换模式请到「参数设置」页。'),
			banner,
			table,
			E('div', { 'class': 'cbi-page-actions' }, [ button, pauseBtn, resumeBtn ]),
			E('h3', {}, '认证日志'),
			logBox
		]);
	}
});
