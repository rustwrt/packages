'use strict';
'require view';
'require form';
'require uci';
'require netbraid';

return view.extend({
	load: function() { return Promise.all([ uci.load('netbraid') ]); },
	render: function() {
		const map = netbraid.map(_('Rules'), _('Rules steer matching traffic to a policy. They are stored configuration and are not enforced: no firewall, route, mark or conntrack change is applied by this page.'));
		const section = netbraid.grid(map, 'rule', _('Configured rules'));
		netbraid.flag(section, 'enabled', _('Enabled'), true);
		netbraid.reference(section, 'policy', _('Target policy'), 'policy', false).rmempty = false;
		netbraid.number(section, 'priority', _('Priority'), 1, 65535, 1, _('Lower values are evaluated first.'));
		netbraid.family(section);
		const protocol = section.option(form.ListValue, 'protocol', _('Protocol'));
		[ 'all', 'tcp', 'udp', 'icmp', 'icmpv6' ].forEach(function(name) { protocol.value(name); });
		protocol.default = 'all';
		protocol.rmempty = false;
		const source = section.option(form.DynamicList, 'source', _('Source address or subnet'));
		source.datatype = 'cidr';
		source.modalonly = false;
		const destination = section.option(form.DynamicList, 'destination', _('Destination address or subnet'));
		destination.datatype = 'cidr';
		const sourcePort = section.option(form.Value, 'source_port', _('Source port or range'));
		sourcePort.datatype = 'or(range(1,65535),portrange)';
		const destinationPort = section.option(form.Value, 'destination_port', _('Destination port or range'));
		destinationPort.datatype = 'or(range(1,65535),portrange)';
		const ingress = section.option(form.Value, 'ingress', _('Ingress interface'));
		ingress.datatype = 'uciname';
		return map.render().then(function(formNode) {
			return E('div', {}, [
				E('div', { 'class': 'alert-message warning', 'role': 'note' }, _('Rules are preview-only. They require a backend that parses the rule section; on an older backend the whole configuration may be reported invalid.')),
				formNode
			]);
		});
	}
});
