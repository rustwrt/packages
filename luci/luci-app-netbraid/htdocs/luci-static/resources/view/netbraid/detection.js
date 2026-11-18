'use strict';
'require view';
'require form';
'require uci';
'require netbraid';

return view.extend({
	load: function() { return Promise.all([ uci.load('netbraid'), netbraid.fetch('detection') ]); },
	render: function(results) {
		const map = netbraid.map(_('Detection'),
			_('Six bounded, read-only sensors provide evidence instead of blocking. Classification is explainable and whitelist entries suppress alerts. No sensor reads packet payloads or runs per-packet code in userspace.'));
		const section = map.section(form.NamedSection, 'detector', 'detector', _('Sensor settings'));
		section.addremove = false;
		netbraid.flag(section, 'enabled', _('Enable detection'), false);
		netbraid.number(section, 'interval', _('Sampling interval (seconds)'), 5, 60, 30);
		netbraid.number(section, 'retention', _('Evidence retention (seconds)'), 60, 86400, 900);
		netbraid.flag(section, 'neighbor', _('MAC, ARP and NDP correlation'), true, _('/proc/net/arp and ip -6 neigh are read with bounded limits.'));
		netbraid.flag(section, 'dhcp', _('DHCP leases and client options'), true, _('/tmp/dhcp.leases and ubus dhcp.leases are read when available.'));
		netbraid.flag(section, 'ttl', _('IPv4 TTL and IPv6 Hop Limit'), true, _('Only bounded nftables counter sets are read. NAT, tunnels and hardware offload limit accuracy.'));
		netbraid.flag(section, 'conntrack', _('Connection flow aggregation'), true, _('/proc/net/nf_conntrack is sampled and aggregated; flows are not devices.'));
		netbraid.flag(section, 'syn', _('TCP SYN fingerprint counters'), false, _('Requires kernel-side nftables aggregation; no per-packet userspace capture.'));
		netbraid.flag(section, 'wifi', _('Wi-Fi AP, STA and WDS topology'), true, _('hostapd ubus and network.wireless status are read when drivers expose them.'));
		section.addOption(form.DynamicList, 'whitelist', _('Whitelist'),
			_('MAC addresses, IPs or device keys on this list never produce a suspect classification.'));
		return map.render().then(function(formNode) {
			const status = results[1] || {};
			const blocks = [ netbraid.status('detection', _('Reported sensor state'), status) ];
			if (status.capabilities) {
				let names = Object.keys(status.capabilities).sort();
				let table = E('table', { 'class': 'table' }, [
					E('tr', {}, [ E('th', {}, _('Sensor')), E('th', {}, _('Available')), E('th', {}, _('Source')) ])
				]);
				for (let i = 0; i < names.length; i++) {
					let c = status.capabilities[names[i]] || {};
					push(table, E('tr', {}, [
						E('td', {}, names[i]),
						E('td', {}, c.available ? _('yes') : _('no')),
						E('td', {}, c.reason || '')
					]));
				}
				push(blocks, E('h3', {}, _('Capability detection')), table);
			}
			if (status.sources) {
				let sourceRows = [ E('tr', {}, [
					E('th', {}, _('Sensor')), E('th', {}, _('Source')),
					E('th', {}, _('Records')), E('th', {}, _('Bounded'))
				]) ];
				for (let i = 0; i < status.sources.length; i++) {
					let s = status.sources[i] || {};
					push(sourceRows, E('tr', {}, [
						E('td', {}, s.sensor || ''), E('td', {}, s.source || ''),
						E('td', {}, String(s.records || 0)), E('td', {}, s.limited ? _('yes') : _('no'))
					]));
				}
				push(blocks, E('h3', {}, _('Sampled sources')), E('table', { 'class': 'table' }, sourceRows));
			}
			if (status.classifications) {
				let classRows = [ E('tr', {}, [ E('th', {}, _('Device')), E('th', {}, _('Status')),
					E('th', {}, _('Confidence')), E('th', {}, _('Evidence')) ]) ];
				for (let i = 0; i < status.classifications.length; i++) {
					let c = status.classifications[i] || {};
					push(classRows, E('tr', {}, [
						E('td', {}, c.device || ''), E('td', {}, c.status || 'Normal'),
						E('td', {}, String(c.confidence || 0)),
						E('td', {}, (c.reasons || []).join(', '))
					]));
				}
				push(blocks, E('h3', {}, _('Classification')), E('table', { 'class': 'table' }, classRows));
			}
			for (let key in status.caveats || [])
				push(blocks, E('p', { 'class': 'caveat' }, key));
			push(blocks, formNode);
			return E('div', {}, blocks);
		});
	}
});
