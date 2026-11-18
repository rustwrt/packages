'use strict';
'require view';
'require form';
'require uci';
'require netbraid';

return view.extend({
	load: function() { return Promise.all([ uci.load('netbraid'), uci.load('network'), netbraid.fetch('portal') ]); },
	render: function(results) {
		const map = netbraid.map(_('Captive Portal'), _('Prepare an optional guest welcome page and session settings. The portal is disabled by default. Saving or enabling these settings does not activate redirects or authorize clients; enforcement is unavailable in this preview.'));
		const section = map.section(form.NamedSection, 'portal', 'portal', _('Portal settings'));
		section.addremove = false;
		netbraid.flag(section, 'enabled', _('Request portal service'), false);
		const networkInterface = section.option(form.ListValue, 'interface', _('Guest interface'));
		networkInterface.optional = true;
		uci.sections('network', 'interface').forEach(function(entry) { networkInterface.value(entry['.name']); });
		const guestNetwork = section.option(form.Value, 'guest_network', _('Guest network name'));
		guestNetwork.default = 'guest';
		guestNetwork.datatype = 'uciname';
		netbraid.number(section, 'session_timeout', _('Session timeout (seconds)'), 60, 86400, 3600);
		const title = section.option(form.Value, 'title', _('Welcome title'));
		title.datatype = 'maxlength(120)';
		const terms = section.option(form.TextValue, 'terms', _('Terms of access'));
		terms.rows = 8;
		terms.datatype = 'maxlength(8192)';
		return map.render().then(function(formNode) {
			return E('div', {}, [
				E('div', { 'class': 'alert-message warning', 'role': 'note' }, _('Portal preview only. No redirect activation, guest authorization or session enforcement is available. Router administration, DHCP and DNS must remain reachable.')),
				netbraid.status('portal', _('Reported portal state'), results[2]), formNode
			]);
		});
	}
});
