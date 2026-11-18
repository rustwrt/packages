'use strict';

import { createCollector, sample } from '../../../net/netbraid/files/usr/lib/netbraid/detection.uc';

function assert(condition, message) {
	if (!condition)
		die('FAIL: ' + message);
};

function rejects(callback, message) {
	let rejected = false;
	try { callback(); }
	catch (error) { rejected = true; }
	assert(rejected, message);
};

const NOW = 1700000000;

let model = {
	main: { detectorEnabled: true },
	detector: { enabled: true, interval: 30, retention: 30, mode: 'sensitive',
		neighborEnabled: true, dhcpEnabled: true, conntrackEnabled: true,
		ttlEnabled: true, synEnabled: true, wifiEnabled: true, whitelist: [] }
};

let files = {
	'/proc/net/arp': [
		'IP address       HW type     Flags       HW address            Mask     Device',
		'192.168.1.20     0x1         0x2         00:11:22:33:44:66     *        br-lan'
	],
	'/tmp/dhcp.leases': [
		'1700000000 00:11:22:33:44:66 192.168.1.20 01:00:11:22:33:44:66 client-a'
	],
	'/proc/net/nf_conntrack': [
		'ipv4     2 tcp      6 100 ESTABLISHED src=192.168.1.10 dst=1.1.1.1 sport=1000 dport=443 packets=10 bytes=1000 src=1.1.1.1 dst=192.168.1.10 sport=443 dport=1000 packets=10 bytes=1000 [ASSURED] mark=0 use=2 dir=original'
	]
};

let commands = {
	'nft --version': [ 'nftables v1.0.9' ],
	'ip -6 neigh show': [ 'fe80::1 dev br-lan lladdr 00:11:22:33:44:55 REACHABLE' ],
	'nft -j list set inet netbraid nb_ttl4': [ '{"set":[{"name":"nb_ttl4","elem":[{"key":64,"counter":{"packets":12,"bytes":1200}}]}]}' ],
	'nft -j list set inet netbraid nb_ttl6': [ '{"set":[{"name":"nb_ttl6","elem":[{"key":64,"counter":{"packets":8,"bytes":800}}]}]}' ],
	'nft -j list set inet netbraid nb_syn': [ '{"set":[{"name":"nb_syn","elem":[{"key":{"mss":1460,"ws":7,"window":64240,"sack":true,"ttl":64},"counter":{"packets":3,"bytes":180}}]}]}' ]
};

let ubus = {
	dhcp: { leases: { call: function() {
		return { leases: [ { expires: 1700003600, mac: 'aa:bb:cc:dd:ee:77', ip: '192.168.1.30',
			clientid: '01:aa:bb:cc:dd:ee:77', hostname: 'wired-client' } ] };
	} } },
	'network.wireless': { status: { call: function() {
		return { radio0: { interfaces: [ { ifname: 'wlan0', ssid: ' guest ', bssid: 'aa:bb:cc:dd:ee:01',
			network: [ 'lan' ], wds: false } ] } };
	} } },
	'hostapd.wlan0': {
		status: { call: function() { return { ssid: 'guest', bssid: 'aa:bb:cc:dd:ee:01' }; } },
		get_clients: { call: function() {
			return { clients: { '00:11:22:33:44:66': { connected_time: 30, wds: true },
				'aa:bb:cc:dd:ee:02': { connected_time: 10, wds: true } } };
		} }
	}
};

let collector = createCollector(model, {
	files: files,
	commandRunner: function(command, maximumBytes, maximumLines) {
		let lines = commands[command] ?? [];
		return { available: exists(commands, command), lines: slice(lines, 0, maximumLines),
			limited: length(lines) > maximumLines, bytes: min(length(join('\n', lines)), maximumBytes) };
	},
	ubusList: function() { return ubus; },
	ubusCall: function(objectName, method, params) {
		if (!exists(ubus, objectName) || !exists(ubus[objectName], method))
			return null;
		return ubus[objectName][method].call(params);
	}
});

let result = sample(collector, NOW);
assert(result.enabled && result.readOnly && result.autoBlocking === false,
	'detection is read-only and never blocks by default');
assert(length(result.capabilities) == 6, 'all six sensor capabilities are reported');
assert(result.capabilities.ttl.available && result.capabilities.syn.available,
	'kernel nftables aggregation sets are detected as supported sources');
assert(result.capabilities.wifi.available && result.capabilities.wifi.details.wirelessStatus,
	'hostapd and wireless ubus topology sources are detected');
assert(length(result.sources) >= 8, 'every enabled source produces a sampled record');
assert(result.limitations.length > 0 || length(result.observations) > 0,
	'result explains source state or observations');
for (let source in result.sources)
	if (source.available !== false)
		assert(source.limited === false || source.limited === true, 'source records bounded state');

let neighbor = 0, dhcp = 0, conntrack = 0, ttl = 0, syn = 0, wifi = 0;
for (let source in result.sources) {
	if (source.sensor == 'neighbor')
		neighbor += source.records;
	else if (source.sensor == 'dhcp')
		dhcp += source.records;
	else if (source.sensor == 'conntrack')
		conntrack += source.records;
	else if (source.sensor == 'ttl')
		ttl += source.records;
	else if (source.sensor == 'syn')
		syn += source.records;
	else if (source.sensor == 'wifi')
		wifi += source.records;
}
assert(neighbor >= 2, 'real ARP and NDP formats yield neighbor observations');
assert(dhcp >= 2, 'lease file and ubus leases yield DHCP observations');
assert(conntrack >= 1, 'conntrack snapshot yields aggregated flow observations');
assert(ttl >= 20, 'nftables TTL counters are aggregated without packet capture');
assert(syn >= 3, 'nftables SYN counters are aggregated with bounded features');
assert(wifi >= 2, 'hostapd clients yield STA and WDS topology observations');

let confirmed = null;
for (let classification in result.classifications)
	if (classification.device == '00:11:22:33:44:66')
		confirmed = classification;
assert(confirmed !== null && confirmed.status == 'Confirmed' && confirmed.confidence >= 80,
	'cross-sensor evidence produces an explainable classification');
assert(length(confirmed.reasons) >= 3 && length(confirmed.evidence) >= 3,
	'classification exposes reasons and evidence references');

let limitedCollector = createCollector(model, { files: {}, ubusList: function() { return null; },
	ubusCall: function() { return null; },
	commandRunner: function() { return { available: false, lines: [], limited: false, bytes: 0 }; } });
let limitedResult = sample(limitedCollector, NOW);
assert(!limitedResult.capabilities.ttl.available && !limitedResult.capabilities.syn.available,
	'unsupported kernel providers are reported instead of being fabricated');
assert(limitedResult.capabilities.dhcp.reason != '', 'capability reasons explain unsupported sources');

let disabledModel = { main: { detectorEnabled: false }, detector: { enabled: false } };
let disabledResult = sample(createCollector(disabledModel, {}), NOW);
assert(disabledResult.enabled == false && length(disabledResult.sources) == 0,
	'disabled detection does not read sources');

rejects(function() { createCollector(null, {}); }, 'collector requires a config model');

print('PASS ucode detection collector tests');
