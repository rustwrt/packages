'use strict';

import * as detector from '../../../net/netbraid/files/usr/lib/netbraid/detector.uc';

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

let state = detector.createDetector({ enabled: false, interval: 30, mode: 'sensitive' });
assert(state.config.enabled == false, 'detector defaults disabled');
assert(detector.SENSOR_LIMITS.neighbor.sampleBytes <= 131072, 'neighbor capture is bounded');
assert(detector.SENSOR_LIMITS.conntrack.sampleLines <= 2048, 'conntrack capture is bounded');
detector.setWhitelist(state, [ 'aa:bb:cc:dd:ee:ff', 'trusted.example' ]);
assert(detector.isWhitelisted(state, [ 'AA:BB:CC:DD:EE:FF' ]), 'whitelist normalizes MAC case');

assert(detector.observeNeighborSnapshot(state, 'br-lan', [
	'IP address       HW type     Flags       HW address            Mask     Device',
	'192.168.1.10     0x1         0x2         aa:bb:cc:dd:11:22     *        br-lan',
	'fe80::1          0x1         0x0         00:11:22:33:44:55     *        br-lan',
	'192.168.1.21     0x1         0x2         aa:bb:cc:dd:ee:ff     *        br-lan'
], NOW) == 3, 'neighbor snapshot parses ARP and NDP sources');
assert(state.observations['neighbor:br-lan:4:aa:bb:cc:dd:11:22'].data.mac == 'aa:bb:cc:dd:11:22',
	'ARP evidence records normalized MAC');
assert(state.observations['neighbor:br-lan:6:00:11:22:33:44:55'].data.family == 6,
	'NDP evidence records IPv6 family');

assert(detector.observeDhcpLeases(state, 'br-lan', [
	'1700000000 00:11:22:33:44:66 192.168.1.20 01:00:11:22:33:44:66 client-a',
	'1700000001 aa:bb:cc:dd:ee:ff 192.168.1.21 01:aa:bb:cc:dd:ee:ff client-b'
], NOW + 1) == 2, 'DHCP snapshot parses lease identity and options');
assert(state.observations['dhcp:br-lan:00:11:22:33:44:66'].data.clientId == '01:00:11:22:33:44:66',
	'DHCP evidence preserves client options');

assert(detector.observeConntrackSnapshot(state, 'br-lan', [
	'ipv4     2 tcp      6 100 ESTABLISHED src=192.168.1.10 dst=1.1.1.1 sport=1000 dport=443 packets=10 bytes=1000 src=1.1.1.1 dst=192.168.1.10 sport=443 dport=1000 packets=10 bytes=1000 [ASSURED] mark=0 use=2 dir=original',
	'ipv4     2 udp     17 20 UNREPLIED src=192.168.1.10 dst=8.8.8.8 sport=1001 dport=53 [UNREPLIED] mark=0 use=1 dir=reply'
], NOW + 2) == 2, 'conntrack snapshot aggregates flows by direction and protocol');
assert(state.observations['conntrack:br-lan:original:tcp'].data.total == 1,
	'conntrack aggregation records direction and protocol');

assert(detector.recordTtl(state, 'br-lan', 4, 64, NOW + 3), 'records IPv4 TTL histogram');
assert(detector.recordTtl(state, 'br-lan', 6, 64, NOW + 4), 'records IPv6 hop-limit histogram');
assert(state.observations['ttl:br-lan:6'].data[64] == 1, 'bounds IPv6 distribution to observed hop-limit');

assert(detector.recordSynFingerprint(state, 'br-lan', '00:11:22:33:44:66', {
	mss: 1460, windowScale: 7, window: 64240, options: 'mss,sok,ts,nop,ws',
	sackPermitted: true, ttl: 64
}, NOW + 5), 'records bounded TCP SYN fingerprint');
assert(state.observations['syn:br-lan:00:11:22:33:44:66:1460|7|64240|mss,sok,ts,nop,ws|true|64']
	.data.windowScale == 7, 'SYN fingerprint records window scale');

assert(detector.recordWifiAssociation(state, 'wlan0', '00:11:22:33:44:66', 'sta',
	{ ssid: 'guest', bssid: 'aa:bb:cc:dd:ee:01', interface: 'wlan0', wds: false, bridge: 'br-lan' },
	NOW + 6), 'records Wi-Fi association topology');
assert(state.observations['wifi:wlan0:00:11:22:33:44:66'].data.bssid == 'aa:bb:cc:dd:ee:01',
	'WiFi evidence records BSSID topology');
assert(detector.recordWifiAssociation(state, 'wlan0', '00:11:22:33:44:66', 'wds',
	{ ssid: 'backhaul', bssid: 'aa:bb:cc:dd:ee:01', interface: 'wlan0', wds: true, bridge: 'br-lan' },
	NOW + 6), 'records explicit repeater WDS evidence');
assert(detector.recordWifiAssociation(state, 'wlan1', 'aa:bb:cc:dd:ee:02', 'wds',
	{ ssid: 'backhaul', bssid: 'aa:bb:cc:dd:ee:01', interface: 'wlan1', wds: true, bridge: 'br-lan' },
	NOW + 6), 'records WDS bridge topology');
assert(detector.classify(state, '00:11:22:33:44:66', NOW + 6, { mode: 'high_confidence' }).status != 'Confirmed',
	'ordinary STA and multi-sensor observations do not confirm a repeater');
assert(detector.classify(state, '00:11:22:33:44:66', NOW + 7, { mode: 'auto' }).status == 'Confirmed',
	'explicit WDS evidence reaches Auto confirmation threshold');
assert(state.observations['wifi:wlan1:aa:bb:cc:dd:ee:02'].data.wds == true,
	'WDS links are distinguished from client associations');

let normal = detector.classify(state, 'trusted.example', NOW + 7);
assert(normal.status == 'Normal' && length(normal.reasons) && normal.reasons[0] == 'whitelisted',
	'whitelisted device is never classified as suspicious');
let classification = detector.classify(state, '00:11:22:33:44:66', NOW + 7);
assert(classification.confidence >= 80 && classification.status == 'Confirmed',
	'multi-sensor topology evidence reaches Confirmed');
assert(length(classification.evidence) >= 3 && length(classification.reasons) >= 3,
	'classification exposes evidence and reasons');
assert(classification.sensorCounts.dhcp >= 1 && classification.sensorCounts.syn >= 1
	&& classification.sensorCounts.wifi >= 1, 'classification reports independent sensor counts');

let summary = detector.summarize(state, NOW + 7, 30);
assert(length(summary.observations) > 0 && length(summary.events) > 0,
	'summary includes bounded observations and events');
assert(summary.capabilities.neighbor.name == 'neighbor' && summary.sensors.neighbor.available,
	'summary reports capability and per-sensor availability');
assert(summary.capabilities.syn.details.lastSample == NOW + 5, 'capability report includes sample time');
assert(length(detector.CAVEATS) >= 4, 'bridge and NAT caveats are exported for the UI');
assert(length(detector.summarize(state, NOW + 1000, 10).observations) == 0,
	'summary expires stale evidence');
assert(!exists(state.observations, 'ttl:br-lan:4'), 'expired evidence is removed');
assert(!exists(detector, 'unsupported'), 'false unsupported placeholders are removed');

rejects(function() { detector.recordTtl(state, 'br-lan', 4, 256, 1); }, 'rejects invalid hop limit');
rejects(function() { detector.recordNeighbor(state, '', 'aa:bb:cc:dd:11:22', 4, 'arp', 1); }, 'rejects empty device');
rejects(function() { detector.recordSynFingerprint(state, '', '00:11:22:33:44:66', {}, 1); }, 'rejects invalid SYN fingerprint');
rejects(function() { detector.recordWifiAssociation(state, 'wlan0', 'x', 'sta', {}, 1); }, 'rejects invalid WiFi observation');

let limitedState = detector.createDetector();
let overflow = 0;
for (let index = 0; index < detector.SENSOR_LIMITS.conntrack.keys + 1; index++)
	if (!detector.recordConntrack(limitedState, 'device-' + index, 'new', 'tcp', 1, 1))
		overflow++;
assert(overflow == 1 && limitedState.dropped == 1 && limitedState.limited,
	'bounded state caps distinct observations and reports drops');
assert(detector.SENSOR_LIMITS.syn.keys <= 256 && detector.SENSOR_LIMITS.syn.sampleBytes <= 65536,
	'TCP SYN capture remains bounded');
assert(detector.classify(limitedState, 'device-1', 1).confidence < 40,
	'aggregate-only evidence never claims Suspected');

print('PASS ucode detector tests');
