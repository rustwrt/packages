'use strict';
'require view';
'require form';
'require uci';
'require netbraid';

return view.extend({
	load: function() { return Promise.all([ uci.load('netbraid'), netbraid.fetch('interfaces') ]); },
	render: function(results) {
		const map = netbraid.map(_('Interfaces'), _('Interfaces are discovered from netifd. Health profiles below can be assigned to members. No virtual interface is created.'));
		const section = netbraid.grid(map, 'health', _('Health profiles'));
		netbraid.flag(section, 'enabled', _('Enabled'), true);
		const targets = section.option(form.DynamicList, 'target', _('Probe targets'));
		targets.datatype = 'host';
		targets.rmempty = false;
		netbraid.number(section, 'interval', _('Interval (seconds)'), 1, 3600, 5);
		netbraid.number(section, 'timeout', _('Timeout (seconds)'), 1, 60, 2);
		netbraid.number(section, 'failure_threshold', _('Failure threshold'), 1, 100, 3);
		netbraid.number(section, 'recovery_threshold', _('Recovery threshold'), 1, 100, 2);
		netbraid.number(section, 'recovery_delay', _('Recovery delay (seconds)'), 0, 86400, 0);
		const minimumTargets = section.option(form.Value, 'minimum_targets', _('Minimum successful targets'));
		minimumTargets.datatype = 'min(1)';
		minimumTargets.validate = function(sectionId, selected) {
			const probeTargets = targets.formvalue(sectionId) || [];
			return !selected || Number(selected) <= probeTargets.length ? true : _('Minimum successful targets cannot exceed the number of probe targets.');
		};
		return map.render().then(function(formNode) {
			return E('div', {}, [ netbraid.preview(), netbraid.status('interfaces', _('Discovered interfaces'), results[1]), formNode ]);
		});
	}
});
