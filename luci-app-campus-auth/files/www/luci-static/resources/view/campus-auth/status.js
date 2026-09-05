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

function fmtResult(r) {
	switch (r) {
		case 'success':  return _('Success');
		case 'failed':   return _('Failed');
		case 'cooldown': return _('Paused by portal (reason 55)');
		default:         return '-';
	}
}

return view.extend({
	handleAuthenticate: function(ev) {
		var btn = ev.target;
		btn.disabled = true;
		btn.classList.add('spinning');

		return callAuthenticate().then(function(res) {
			if (res && res.result)
				ui.addNotification(null,
					E('p', _('Authentication has been triggered, the status below will update shortly.')),
					'info');
			else
				ui.addNotification(null,
					E('p', _('Failed to trigger authentication: %s').format((res && res.message) || 'unknown error')),
					'error');
		}).catch(function(e) {
			ui.addNotification(null,
				E('p', _('Failed to trigger authentication: %s').format(e.message || e)),
				'error');
		}).finally(function() {
			btn.disabled = false;
			btn.classList.remove('spinning');
		});
	},

	render: function() {
		var table = E('table', { 'class': 'table' });

		var logBox = E('pre', {
			'style': 'max-height:24em; overflow:auto; white-space:pre-wrap; padding:.6em; '
				+ 'border:1px solid #d4d4d4; font-size:.9em'
		}, _('Loading…'));

		poll.add(L.bind(function() {
			return Promise.all([ callStatus(), callLog(200) ]).then(L.bind(function(data) {
				var st = data[0];

				var conn;
				if (st.online) {
					conn = '%s (HTTP %s)'.format(_('Connected'), st.http_code);
				}
				else {
					conn = '%s (HTTP %s)'.format(_('No connectivity'), st.http_code || '-');
					if (st.redirect)
						conn += ' -> ' + st.redirect;
				}

				var svc;
				if (st.service_enabled)
					svc = st.service_running ? _('Running') : _('Not running');
				else
					svc = _('Disabled');

				if (st.cooldown)
					svc += ' · %s'.format(_('Server cooldown active: automatic retries paused, remove /etc/campus-auth.reason55 after 15 minutes'));

				var last = '-';
				if (st.last_time)
					last = '%s · %s%s'.format(st.last_time, fmtResult(st.last_result),
						st.last_message ? ' — ' + st.last_message : '');

				dom.content(table, [
					E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class': 'th' }, _('Item')),
						E('th', { 'class': 'th' }, _('Value'))
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, _('Network status')),
						E('td', { 'class': 'td' }, conn)
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, _('Portal server')),
						E('td', { 'class': 'td' }, st.auth_host || '-')
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, _('Campus IP')),
						E('td', { 'class': 'td' }, st.user_ip || '-')
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, _('Background service')),
						E('td', { 'class': 'td' }, svc)
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, _('Last authentication')),
						E('td', { 'class': 'td' }, last)
					])
				]);

				logBox.textContent = data[1] || _('No log entries yet.');
			}, this));
		}, this), 5);

		var button = E('button', {
			'class': 'btn cbi-button cbi-button-action important',
			'click': ui.createHandlerFn(this, 'handleAuthenticate')
		}, [ _('Authenticate now') ]);

		return E([
			E('h2', {}, _('Campus Network Authentication')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Shows the current campus network connectivity and lets you trigger manual authentication attempts.')),
			table,
			E('div', { 'class': 'cbi-page-actions' }, [ button ]),
			E('h3', {}, _('Authentication log')),
			logBox
		]);
	}
});
