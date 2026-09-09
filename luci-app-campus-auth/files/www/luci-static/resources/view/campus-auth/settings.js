'use strict';
'require view';
'require form';
'require rpc';

var callInterfaces = rpc.declare({
	object: 'campus-auth',
	method: 'interfaces',
	expect: { devices: [] }
});

return view.extend({
	render: function() {
		return L.resolveDefault(callInterfaces(), []).then(function(devices) {
			var m = new form.Map('campus-auth', _('Campus Network Authentication'),
				_('Credentials and connection parameters used to authenticate against the campus network portal.'));

			var s = m.section(form.NamedSection, 'config', 'campus-auth', _('General Settings'));
			s.addremove = false;

			var o = s.option(form.ListValue, 'mode', _('Protection mode'));
			o.value('normal', _('Normal router (authentication only)'));
			o.value('anti-detect', _('Campus auth + anti-detection'));
			o.value('proxy', _('Anti-detection + proxy (OpenClash)'));
			o.default = 'normal';
			o.rmempty = false;
			o.description = _('normal: automatic authentication only. anti-detect: additionally unifies the User-Agent (UA3F), rewrites TTL, redirects NTP/DNS through the router and turns LAN IPv6 off. proxy: additionally runs OpenClash for actual proxying - the subscription and nodes stay managed inside OpenClash itself. Applied on Save & Apply and at boot.');

			o = s.option(form.Flag, 'enabled', _('Enable background service'));
			o.default = o.enabled;
			o.rmempty = false;
			o.description = _('Continuously probe connectivity and re-authenticate automatically after disconnects.');

			o = s.option(form.ListValue, 'protocol', _('Portal protocol'));
			o.value('gportal', 'gportal (wlanacname + AES-CBC)');
			o.value('ruijie', 'Ruijie eportal (preview)');
			o.default = 'gportal';
			o.description = _('Authentication protocol spoken by the school portal. Add /usr/share/campus-auth/proto/<name>.sh to support new schools.');

			o = s.option(form.Value, 'username', _('Username'));
			o.rmempty = false;
			o.description = _('Student ID or campus account name.');

			o = s.option(form.Value, 'password', _('Password'));
			o.password = true;
			o.rmempty = false;

			o = s.option(form.Value, 'auth_host', _('Portal server'));
			o.placeholder = '192.168.99.2';
			o.description = _('IP address of the campus authentication portal (no scheme, no path).');

			o = s.option(form.Value, 'nas_name', _('NAS name'));
			o.placeholder = 'GKDX';
			o.description = _('wlanacname parameter expected by the portal (gportal protocol).');

			o = s.option(form.Value, 'aes_key', _('Portal AES key (gportal)'));
			o.placeholder = '1234567887654321';
			o.description = _('AES-128 key the gportal web page uses to encrypt the login form. Only change this if your school\'s portal JS shows a different key.');

			o = s.option(form.Value, 'check_url', _('Connectivity check URL'));
			o.placeholder = 'http://connectivitycheck.platform.hicloud.com/generate_204';
			o.description = _('Endpoint that must respond with HTTP 204 when the campus network is reachable. Display only: authentication decisions are made against the portal state endpoint.');

			o = s.option(form.ListValue, 'interface', _('Interface (optional)'));
			o.value('', _('Auto-detect'));
			(devices || []).forEach(function(d) {
				o.value(d, d);
			});
			o.description = _('Physical interface towards the campus uplink (e.g. eth1, an eth0.2 VLAN or pppoe-wan). Auto-detect picks the source address of the route towards the portal.');

			o = s.option(form.Value, 'interval', _('Check interval (seconds)'));
			o.datatype = 'range(30,3600)';
			o.default = '60';

			o = s.option(form.Flag, 'quiet_enable', _('Nightly quiet window'));
			o.default = o.enabled;
			o.description = _('Make no portal requests during the scheduled nightly outage (checks and logins both). Every re-login after an outage can consume a device-binding slot, so logins must stay rare.');

			o = s.option(form.Value, 'quiet_start', _('Quiet window start'));
			o.placeholder = '00:00';
			o.datatype = 'time';
			o.description = _('Campus network goes offline at this time (HH:MM).');

			o = s.option(form.Value, 'quiet_end', _('Quiet window end'));
			o.placeholder = '06:00';
			o.datatype = 'time';
			o.description = _('Campus network comes back at this time (HH:MM); the first login happens shortly after.');

			o = s.option(form.Value, 'login_holdoff', _('Holdoff after failed login (seconds)'));
			o.datatype = 'range(60,86400)';
			o.default = '900';
			o.description = _('Wait this long after a rejected login before trying again, so a persistent reject (e.g. device-binding quota exhausted) does not hammer the portal.');

			return m.render();
		});
	}
});
