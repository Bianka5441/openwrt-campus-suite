'use strict';
'require view';
'require form';

return view.extend({
	render: function() {
		var m = new form.Map('campus-auth', _('Campus Network Authentication'),
			_('Credentials and connection parameters used to authenticate against the campus network portal.'));

		var s = m.section(form.NamedSection, 'config', 'campus-auth', _('General Settings'));
		s.addremove = false;

		var o = s.option(form.Flag, 'enabled', _('Enable background service'));
		o.default = o.enabled;
		o.rmempty = false;
		o.description = _('Continuously probe connectivity and re-authenticate automatically after disconnects.');

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
		o.description = _('wlanacname parameter expected by the portal.');

		o = s.option(form.Value, 'check_url', _('Connectivity check URL'));
		o.placeholder = 'http://connectivitycheck.gstatic.com/generate_204';
		o.description = _('Endpoint that must respond with HTTP 204 when the campus network is reachable.');

		o = s.option(form.Value, 'interface', _('Interface (optional)'));
		o.placeholder = _('e.g. eth1 (leave empty to auto-detect)');
		o.description = _('Physical interface towards the campus uplink. Only set this if IP auto-detection picks the wrong source address.');

		o = s.option(form.Value, 'interval', _('Check interval (seconds)'));
		o.datatype = 'range(30,3600)';
		o.default = '120';

		return m.render();
	}
});
