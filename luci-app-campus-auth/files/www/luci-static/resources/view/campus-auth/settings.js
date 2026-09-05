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

			var o = s.option(form.Flag, 'enabled', _('Enable background service'));
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

			return m.render();
		});
	}
});
