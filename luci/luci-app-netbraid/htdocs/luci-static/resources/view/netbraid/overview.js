'use strict';
'require view';
'require form';
'require uci';
'require netbraid';

return view.extend({
	load: function() { return Promise.all([ uci.load('netbraid'), netbraid.fetch('status') ]); },
	render: function(results) {
		const map = netbraid.map(_('NetBraid Overview'), _('Configure the control plane and inspect the latest reported state.'));
		const section = map.section(form.NamedSection, 'main', 'netbraid', _('General settings'));
		section.addremove = false;
		netbraid.flag(section, 'enabled', _('Enable control plane'), false);
		netbraid.flag(section, 'health_enabled', _('Enable health checks'), true);
		netbraid.flag(section, 'router_originated', _('Include router-originated traffic in preview'), false);
		netbraid.number(section, 'mark_shift', _('Routing mark shift'), 16, 24, 16, _('Reserved mark bits must not overlap WARP or other routing services.'));
		netbraid.number(section, 'table_base', _('Routing table base'), 10000, 50000, 10000);
		netbraid.number(section, 'priority_base', _('Routing rule priority base'), 20000, 30000, 20000);
		const logLevel = section.option(form.ListValue, 'log_level', _('Log level'));
		[ 'debug', 'info', 'notice', 'warning', 'err' ].forEach(function(level) { logLevel.value(level); });
		logLevel.default = 'notice';
		return map.render().then(function(formNode) {
			return E('div', {}, [ netbraid.preview(), netbraid.status('status', _('Reported runtime state'), results[1]), formNode ]);
		});
	}
});
