'use strict';
'require view';
'require form';
'require uci';
'require netbraid';

return view.extend({
	load: function() { return Promise.all([ uci.load('netbraid'), uci.load('network') ]); },
	render: function() {
		const map = netbraid.map(_('Members'), _('A member links a logical network interface to a priority, weight and optional health profile. Lower priorities are preferred; weights divide new connections, not bandwidth.'));
		const section = netbraid.grid(map, 'member', _('Configured members'));
		netbraid.flag(section, 'enabled', _('Enabled'), true);
		const networkInterface = section.option(form.ListValue, 'interface', _('Logical interface'));
		uci.sections('network', 'interface').forEach(function(entry) { networkInterface.value(entry['.name']); });
		networkInterface.rmempty = false;
		networkInterface.validate = function(sectionId, selected) {
			return uci.get('network', selected) === 'interface' ? true : _('Select an existing logical network interface.');
		};
		netbraid.number(section, 'priority', _('Priority'), 1, 65535, 1);
		netbraid.number(section, 'weight', _('Weight'), 1, 256, 1);
		netbraid.reference(section, 'health', _('Health profile'), 'health', false).optional = true;
		netbraid.family(section);
		return map.render().then(function(formNode) { return E('div', {}, [ netbraid.preview(), formNode ]); });
	}
});
