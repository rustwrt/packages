'use strict';
'require view';
'require form';
'require uci';
'require netbraid';

return view.extend({
	load: function() { return uci.load('netbraid'); },
	render: function() {
		const map = netbraid.map(_('Policies'), _('Select members and a deterministic connection classifier. One member represents a single path; different member priorities describe failover and equal priorities describe weighted distribution in the preview.'));
		const section = netbraid.grid(map, 'policy', _('Configured policies'));
		netbraid.flag(section, 'enabled', _('Enabled'), true);
		const members = netbraid.reference(section, 'member', _('Members'), 'member', true);
		members.rmempty = false;
		const mode = section.option(form.ListValue, 'mode', _('Connection classifier'));
		mode.value('src-address', _('Source address'));
		mode.value('dst-address', _('Destination address'));
		mode.value('both-addresses', _('Source and destination addresses'));
		mode.value('src-port', _('Source port'));
		mode.value('dst-port', _('Destination port'));
		mode.value('both-ports', _('Source and destination ports'));
		mode.value('src-address-and-port', _('Source address and port'));
		mode.value('dst-address-and-port', _('Destination address and port'));
		mode.value('both-addresses-and-ports', _('Both addresses and ports'));
		mode.default = 'both-addresses';
		mode.rmempty = false;
		netbraid.family(section);
		netbraid.flag(section, 'router_originated', _('Include router-originated traffic in preview'), false);
		return map.render().then(function(formNode) { return E('div', {}, [ netbraid.preview(), formNode ]); });
	}
});
