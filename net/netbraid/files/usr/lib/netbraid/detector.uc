'use strict';

import { isInteger } from './util.uc';

export const SENSOR_NAMES = [ 'neighbor', 'dhcp', 'ttl', 'conntrack', 'syn', 'wifi' ];

export const SENSOR_LIMITS = {
	neighbor: { keys: 1024, sampleBytes: 131072, sampleLines: 2048, maxAge: 1800 },
	dhcp: { keys: 1024, sampleBytes: 131072, sampleLines: 2048, maxAge: 3600 },
	ttl: { keys: 256, sampleBytes: 65536, sampleLines: 1024, maxAge: 900 },
	conntrack: { keys: 512, sampleBytes: 262144, sampleLines: 2048, maxAge: 900 },
	syn: { keys: 256, sampleBytes: 65536, sampleLines: 512, maxAge: 900 },
	wifi: { keys: 512, sampleBytes: 131072, sampleLines: 1024, maxAge: 1800 }
};

export const MAX_OBSERVATIONS = 4096;
export const MAX_SYN_SIGNATURES_PER_DEVICE = 16;
export const CLASSIFICATION_MODES = [ 'auto', 'high_confidence', 'sensitive' ];
export const CLASSIFICATION_THRESHOLDS = {
	auto: { suspected: 60, confirmed: 80 },
	high_confidence: { suspected: 72, confirmed: 95 },
	sensitive: { suspected: 45, confirmed: 80 }
};

export const CAPABILITY_REASONS = {
	neighbor: 'Kernel ARP and NDP caches are read when present; a MAC alone is not proof of a device.',
	dhcp: 'dnsmasq lease files and ubus lease data are read when available; NAT hides downstream clients.',
	ttl: 'TTL and hop limit are sampled from bounded kernel/provider data; NAT and tunnels distort values.',
	conntrack: 'nf_conntrack counters are aggregated; flows are not devices.',
	syn: 'TCP SYN headers are accepted only from an efficient provider; no per-packet userspace ucode is used.',
	wifi: 'hostapd and WDS topology data are read only when the driver exposes them via ubus or control files.'
};

export const CAVEATS = [
	'Bridged clients may be invisible to IP-layer neighbor, DHCP and conntrack sensors.',
	'NAT, tunnels and WDS bridges distort TTL, hop-limit and address-based evidence.',
	'Connection counts and SYN samples are aggregates, not device counts.',
	'Detection is read-only and never blocks traffic by default.'
];

function requireEntry(value, label) {
	if (type(value) != 'object')
		die(sprintf('%s must be an object', label));
	return value;
};

function boundedLimit(name) {
	let limits = SENSOR_LIMITS[name];
	if (limits === null)
		die(sprintf('unknown sensor: %s', name));
	return limits;
};

export function createDetector(config) {
	return {
		config: config ?? { enabled: false, interval: 30 },
		sensors: {},
		observations: {},
		aliases: {},
		ipToMac: {},
		synSignatures: {},
		whitelist: {},
		events: [],
		capabilities: {},
		dropped: 0,
		limited: false,
		startedAt: null,
		updatedAt: null
	};
};

export function setWhitelist(state, entries) {
	requireEntry(state, 'detector state');
	if (type(entries) != 'array')
		die('whitelist must be an array');
	let result = {};
	for (let entry in entries) {
		let value = type(entry) == 'object' ? entry.key : entry;
		if (type(value) != 'string' || value === '')
			die('whitelist key is invalid');
		result[lc(value)] = true;
	}
	state.whitelist = result;
};

export function isWhitelisted(state, values) {
	requireEntry(state, 'detector state');
	for (let value in values) {
		if (type(value) != 'string' || value === '')
			continue;
		if (exists(state.whitelist, lc(value)))
			return true;
	}
	return false;
};

export function recordEvent(state, event) {
	requireEntry(state, 'detector state');
	requireEntry(event, 'detection event');
	if (type(event.sensor) != 'string' || !exists(SENSOR_LIMITS, event.sensor))
		die('event sensor is invalid');
	if (!isInteger(event.at, 0, null))
		die('event.at must be a nonnegative integer');
	if (type(event.device) != 'string' || event.device === '')
		die('event.device is invalid');
	if (type(event.kind) != 'string' || event.kind === '')
		die('event.kind is invalid');
	if (isWhitelisted(state, [ event.mac, event.device, event.ip, event.key ]))
		return false;
	if (length(state.events) >= 256) {
		state.events = slice(state.events, -128);
		state.limited = true;
	}
	push(state.events, {
		sensor: event.sensor, device: event.device, mac: event.mac ?? null,
		ip: event.ip ?? null, kind: event.kind, at: event.at,
		confidence: event.confidence ?? 0, evidence: event.evidence ?? {},
		reasons: event.reasons ?? []
	});
	return true;
};

function sensorState(state, name) {
	requireEntry(state, 'detector state');
	let limits = boundedLimit(name);
	if (!exists(state.sensors, name))
		state.sensors[name] = { available: false, limited: false, dropped: 0, lastSample: null };
	if (length(state.sensors) > length(SENSOR_NAMES)) {
		state.limited = true;
		return null;
	}
	return state.sensors[name];
};

function touchSensor(state, name, now, available) {
	let sensor = sensorState(state, name);
	if (sensor === null)
		return null;
	if (available !== false)
		sensor.available = true;
	sensor.lastSample = now;
	return sensor;
};

function boundedEntry(state, name, key, now, limit, maxKeys) {
	let keyName = name + ':' + key;
	let limits = boundedLimit(name);
	maxKeys ??= limits.keys;
	limit ??= limits.maxAge;
	if (!isInteger(now, 0, null))
		die('evidence time must be a nonnegative integer');
	let entry = state.observations[keyName];
	if (entry !== null && now >= entry.firstSeen) {
		if (now > entry.lastSeen)
			entry.lastSeen = now;
		entry.count++;
		return entry;
	}
	let sensor = sensorState(state, name);
	if (sensor === null)
		return null;
	let sensorCount = 0;
	for (let observationKey in keys(state.observations))
		if (state.observations[observationKey].sensor == name)
			sensorCount++;
	if (sensorCount >= maxKeys || length(state.observations) >= MAX_OBSERVATIONS) {
		state.dropped++;
		sensor.dropped++;
		sensor.limited = true;
		state.limited = true;
		return null;
	}
	state.observations[keyName] = { key: keyName, sensor: name, count: 1,
		firstSeen: now, lastSeen: now, data: {} };
	return state.observations[keyName];
};

function validMac(value) {
	return type(value) == 'string' && match(value, /^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$/) !== null;
};

function linkMac(state, mac, device) {
	if (!validMac(mac) || type(device) != 'string' || device === '')
		return;
	let normalized = lc(mac);
	let candidates = state.aliases[normalized] ?? [];
	if (index(candidates, device) < 0)
		push(candidates, device);
	state.aliases[normalized] = candidates;
	state.observationInterfaces ??= {};
	state.observationInterfaces[normalized] ??= [];
	if (index(state.observationInterfaces[normalized], device) < 0)
		push(state.observationInterfaces[normalized], device);
};

function linkIp(state, ip, mac) {
	if (type(ip) != 'string' || ip === '' || !validMac(mac))
		return;
	state.ipToMac[lc(ip)] = lc(mac);
};

function sensorNames(observations) {
	let result = [];
	for (let name in keys(observations))
		push(result, name);
	return result;
};

function normalizedClassMode(value) {
	return index(CLASSIFICATION_MODES, value) >= 0 ? value : 'auto';
};

function interfaceForObservation(state, observation) {
	let dataInterface = observation.data?.interface;
	if (type(dataInterface) == 'string' && dataInterface !== '')
		return dataInterface;
	let mac = observationMac(observation);
	if (mac !== null && exists(state.observationInterfaces ?? {}, mac)) {
		let devices = state.observationInterfaces[mac];
		if (length(devices) == 1)
			return devices[0];
	}
	return null;
};

function classifyEvidenceType(sensorCounts, matched) {
	let directNat = 0, bridgedRepeater = 0, wirelessMesh = 0, unknown = 0;
	let strongCount = 0, observations = 0;
	for (let observation in matched) {
		observations += observation.count;
		let data = observation.data ?? {};
		if (observation.sensor == 'wifi') {
			if (data.wds === true || data.role == 'wds') {
				bridgedRepeater++;
				strongCount++;
			}
			else if (type(data.meshId) == 'string' && data.meshId !== '') {
				wirelessMesh++;
				strongCount++;
			}
			else
				unknown++;
		}
		else if (observation.sensor == 'conntrack') {
			if (data.forwarded === true && data.gatewayMac === null)
				directNat++;
			else if (data.bridged === true)
				bridgedRepeater++;
			else
				unknown++;
		}
		else if (observation.sensor == 'syn') {
			if (data.ttl !== null && isInteger(data.ttl, 0, 255))
				unknown++;
			else
				unknown++;
		}
		else
			unknown++;
	}
	let sharedGateway = exists(sensorCounts, 'dhcp') && exists(sensorCounts, 'neighbor') ? 1 : 0;
	if (bridgedRepeater > 0 || wirelessMesh > 0)
		return { type: directNat > 0 ? 'mixed' : 'l2_bridge_repeater',
			bridgedRepeater: bridgedRepeater, wirelessMesh: wirelessMesh,
			directNat: directNat, sharedGateway: sharedGateway,
			strongCount: strongCount, observations: observations, unknown: unknown };
	if (directNat > 0)
		return { type: 'nat_router', bridgedRepeater: 0, wirelessMesh: 0,
			directNat: directNat, sharedGateway: sharedGateway,
			strongCount: directNat, observations: observations, unknown: unknown };
	return { type: 'undetermined', bridgedRepeater: 0, wirelessMesh: 0,
		directNat: 0, sharedGateway: sharedGateway, strongCount: 0,
		observations: observations, unknown: unknown };
};

function evidenceFreshness(matched, now, maxAge) {
	let newest = 0;
	for (let observation in matched)
		newest = max(newest, observation.lastSeen ?? 0);
	return now - newest <= maxAge;
};

export function recordNeighbor(state, device, ip, mac, family, source, now) {
	if (type(device) != 'string' || device === '' || type(ip) != 'string' || ip === ''
		|| !validMac(mac) || (family != 4 && family != 6)
		|| (source != 'arp' && source != 'ndp') || !isInteger(now, 0, null))
		die('invalid neighbor observation');
	touchSensor(state, 'neighbor', now, true);
	mac = lc(mac);
	let entry = boundedEntry(state, 'neighbor', device + ':' + family + ':' + mac, now);
	if (entry === null)
		return false;
	entry.data.mac = mac;
	entry.data.interface = device;
	entry.data.family = family;
	entry.data.source = source;
	let ips = entry.data.ips ?? [];
	if (index(ips, ip) < 0)
		push(ips, ip);
	entry.data.ips = ips;
	linkMac(state, mac, device);
	linkIp(state, ip, mac);
	recordEvent(state, { sensor: 'neighbor', device: device, mac: mac, ip: ip, at: now,
		kind: family == 4 ? 'arp_observation' : 'ndp_observation', confidence: 25,
		evidence: { source: source, family: family, interface: device, ip: ip },
		reasons: [ family == 4 ? 'arp_cache_entry' : 'ipv6_neighbor_entry' ] });
	return true;
};

export function recordDhcpLease(state, device, mac, ip, options, now) {
	if (type(device) != 'string' || device === '' || !validMac(mac) || type(ip) != 'string' || ip === ''
		|| type(options) != 'object' || !isInteger(now, 0, null))
		die('invalid DHCP lease observation');
	touchSensor(state, 'dhcp', now, true);
	mac = lc(mac);
	let entry = boundedEntry(state, 'dhcp', device + ':' + mac, now);
	if (entry === null)
		return false;
	entry.data.mac = mac;
	entry.data.interface = device;
	entry.data.ip = ip;
	entry.data.expiresAt = options.expiresAt ?? null;
	entry.data.clientId = options.clientId ?? null;
	entry.data.hostname = options.hostname ?? null;
	entry.data.vendorClass = options.vendorClass ?? null;
	entry.data.requestedOptions = options.requestedOptions ?? [];
	entry.data.requestedMask = options.requestedMask ?? null;
	entry.data.optionSources = options.optionSources ?? [ 'lease_fields' ];
	linkMac(state, mac, device);
	linkIp(state, ip, mac);
	recordEvent(state, { sensor: 'dhcp', device: device, mac: mac, ip: ip, at: now,
		kind: 'dhcp_lease', confidence: 20,
		evidence: { clientId: options.clientId ?? null, vendorClass: options.vendorClass ?? null,
			hostname: options.hostname ?? null, requestedOptions: options.requestedOptions ?? [],
			requestedMask: options.requestedMask ?? null },
		reasons: [ 'dhcp_lease_present', 'lease_client_id_is_not_vendor_fingerprint' ] });
	return true;
};

export function recordTtl(state, device, family, hopLimit, now, mac) {
	if (type(device) != 'string' || device === '' || (family != 4 && family != 6)
		|| !isInteger(hopLimit, 0, 255) || !isInteger(now, 0, null))
		die('invalid ttl observation');
	touchSensor(state, 'ttl', now, true);
	if (mac !== null && !validMac(mac))
		die('invalid TTL source MAC');
	let entry = boundedEntry(state, 'ttl', device + ':' + family + (mac !== null ? ':' + lc(mac) : ''), now);
	if (entry === null)
		return false;
	entry.data.interface = device;
	entry.data.family = family;
	entry.data.mac = mac !== null ? lc(mac) : null;
	entry.data[hopLimit] = (entry.data[hopLimit] ?? 0) + 1;
	return true;
};

export function recordConntrack(state, device, direction, protocol, count, now) {
	if (type(device) != 'string' || device === '' || type(direction) != 'string'
		|| direction === '' || type(protocol) != 'string' || protocol === ''
		|| !isInteger(count, 0, 2147483647) || !isInteger(now, 0, null))
		die('invalid conntrack observation');
	touchSensor(state, 'conntrack', now, true);
	let entry = boundedEntry(state, 'conntrack', device + ':' + direction + ':' + protocol, now);
	if (entry === null)
		return false;
	entry.data.interface = device;
	entry.data.direction = direction;
	entry.data.protocol = protocol;
	entry.data.total = (entry.data.total ?? 0) + count;
	return true;
};

export function recordSynFingerprint(state, device, mac, features, now) {
	if (type(device) != 'string' || device === '' || !validMac(mac)
		|| type(features) != 'object' || !isInteger(now, 0, null))
		die('invalid TCP SYN fingerprint');
	touchSensor(state, 'syn', now, true);
	mac = lc(mac);
	let fields = [ features.mss, features.windowScale, features.window, features.options,
		features.sackPermitted, features.ttl ];
	let signature = join('|', map(fields, function(field) { return '' + field; }));
	let signatures = state.synSignatures[mac] ?? {};
	if (!exists(signatures, signature) && length(signatures) >= MAX_SYN_SIGNATURES_PER_DEVICE) {
		state.dropped++;
		state.limited = true;
		return false;
	}
	signatures[signature] = now;
	state.synSignatures[mac] = signatures;
	let signatureKey = mac + ':' + signature;
	let entry = boundedEntry(state, 'syn', device + ':' + signatureKey, now);
	if (entry === null)
		return false;
	entry.data.interface = device;
	entry.data.mac = mac;
	entry.data.mss = features.mss ?? null;
	entry.data.windowScale = features.windowScale ?? null;
	entry.data.window = features.window ?? null;
	entry.data.options = features.options ?? null;
	entry.data.sackPermitted = features.sackPermitted === true;
	entry.data.ttl = features.ttl ?? null;
	recordEvent(state, { sensor: 'syn', device: device, mac: mac, at: now,
		kind: 'tcp_syn_fingerprint', confidence: 20,
		evidence: { mss: entry.data.mss, windowScale: entry.data.windowScale,
			window: entry.data.window, options: entry.data.options,
			sackPermitted: entry.data.sackPermitted, ttl: entry.data.ttl },
		reasons: [ 'kernel_side_syn_counter_only', 'payload_is_not_collected' ] });
	return true;
};

export function recordWifiAssociation(state, device, mac, role, topology, now) {
	if (type(device) != 'string' || device === '' || !validMac(mac)
		|| index([ 'sta', 'wds', 'ap', 'unknown' ], role) < 0
		|| type(topology) != 'object' || !isInteger(now, 0, null))
		die('invalid WiFi association observation');
	touchSensor(state, 'wifi', now, true);
	mac = lc(mac);
	let entry = boundedEntry(state, 'wifi', device + ':' + mac, now);
	if (entry === null)
		return false;
	entry.data.mac = mac;
	entry.data.role = role;
	entry.data.ssid = topology.ssid ?? null;
	entry.data.bssid = topology.bssid ?? null;
	entry.data.interface = device;
	entry.data.wds = role == 'wds' || topology.wds === true;
	entry.data.meshId = topology.meshId ?? topology.mesh_id ?? null;
	entry.data.bridge = topology.bridge ?? null;
	linkMac(state, mac, device);
	recordEvent(state, { sensor: 'wifi', device: device, mac: mac, at: now,
		kind: 'wifi_association', confidence: role == 'wds' ? 15 : 5,
		evidence: { role: role, ssid: topology.ssid ?? null, bssid: topology.bssid ?? null,
			interface: device, wds: entry.data.wds, bridge: topology.bridge ?? null },
		reasons: [ 'driver_association_topology',
			role == 'wds' ? 'wds_link_is_not_a_client_device' : 'association_alone_does_not_prove_nat' ] });
	return true;
};

export function observeNeighborSnapshot(state, defaultDevice, lines, now) {
	if (type(lines) != 'array')
		die('neighbor snapshot must be an array');
	requireEntry(state, 'detector state');
	let count = 0;
	for (let line in lines) {
		let parts = split(trim(line), /\s+/);
		if (length(parts) < 4 || parts[0] == 'IP' || parts[0] == 'Address')
			continue;
		let family = index(parts[0], ':') >= 0 ? 6 : 4;
		let ip = parts[0];
		if (family == 6) {
			let percent = index(ip, '%');
			if (percent > 0)
				ip = substr(ip, 0, percent);
		}
		let macMatch = match(join(' ', parts), /([0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5})/);
		if (macMatch === null)
			continue;
		let device = defaultDevice;
		let dev = match(line, /\bdev ([A-Za-z0-9_.-]+)/);
		if (dev !== null)
			device = dev[1];
		else if (family == 4 && length(parts) >= 6)
			device = parts[length(parts) - 1];
		if (recordNeighbor(state, device, ip, macMatch[1], family,
			family == 4 ? 'arp' : 'ndp', now))
			count++;
	}
	return count;
};

export function observeDhcpLeases(state, device, lines, now) {
	if (type(lines) != 'array')
		die('DHCP snapshot must be an array');
	let count = 0;
	for (let line in lines) {
		let parts = split(trim(line), /\s+/);
		if (length(parts) < 5 || !validMac(parts[1]))
			continue;
		let options = { expiresAt: int(parts[0]),
			clientId: parts[3] == '*' ? null : parts[3],
			hostname: parts[4] == '*' ? null : parts[4],
			vendorClass: null, requestedOptions: [], optionSources: [ 'dnsmasq_lease' ] };
		if (recordDhcpLease(state, device, parts[1], parts[2], options, now))
			count++;
	}
	return count;
};

export function observeConntrackSnapshot(state, device, lines, now) {
	if (type(lines) != 'array')
		die('conntrack snapshot must be an array');
	let counters = {};
	for (let line in lines) {
		let text = trim(line);
		if (text === '')
			continue;
		let fields = split(text, /\s+/);
		if (length(fields) < 3)
			continue;
		let protocol = lc(fields[2]);
		let direction = index(text, 'dir=reply') >= 0 ? 'reply' : 'original';
		let key = device + ':' + direction + ':' + protocol;
		counters[key] = (counters[key] ?? 0) + 1;
	}
	let count = 0;
	for (let key in keys(counters)) {
		let parts = split(key, ':');
		if (length(parts) != 3)
			continue;
		if (recordConntrack(state, parts[0], parts[1], parts[2], counters[key], now))
			count++;
	}
	return count;
};

function observationMac(observation) {
	let mac = observation.data?.mac;
	if (!validMac(mac))
		mac = match(observation.key, /([0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2})/);
	return type(mac) == 'array' ? lc(mac[1]) : (validMac(mac) ? lc(mac) : null);
};

function observationDevice(observation) {
	if (observation.sensor == 'neighbor')
		return observation.data.family == 6 ? 'ipv6-neighbor' : 'arp-neighbor';
	if (observation.sensor == 'dhcp')
		return 'dhcp-lease';
	if (observation.sensor == 'ttl')
		return observation.data.family == 6 ? 'ipv6-ttl' : 'ipv4-ttl';
	if (observation.sensor == 'syn')
		return 'tcp-syn';
	if (observation.sensor == 'conntrack')
		return 'conntrack';
	return 'wifi-topology';
};

export function classifyDevice(state, device, now, options) {
	requireEntry(state, 'detector state');
	if (type(device) != 'string' || device === '' || !isInteger(now, 0, null))
		die('invalid classify request');
	let mode = normalizedClassMode(options?.mode ?? state.config?.mode ?? 'auto');
	let interfaceName = options?.interface ?? null;
	let maxAge = options?.maxAge ?? state.config?.retention ?? 900;
	if (!isInteger(maxAge, 1, null))
		die('invalid classification retention');
	let target = lc(device);
	if (!validMac(target)) {
		if (state.ipToMac[target] !== null)
			target = state.ipToMac[target];
		else {
			for (let mac in keys(state.aliases))
				if (index(state.aliases[mac], device) >= 0)
					target = mac;
		}
	}
	let matched = [], sensorCounts = {}, filteredOut = false;
	for (let keyName in keys(state.observations)) {
		let observation = state.observations[keyName];
		if (observationMac(observation) != target && observationDevice(observation) != device)
			continue;
		let observationInterface = interfaceForObservation(state, observation);
		if (interfaceName !== null && observationInterface !== null
			&& observationInterface != interfaceName) {
			filteredOut = true;
			continue;
		}
		if (now >= observation.lastSeen && now - observation.lastSeen <= maxAge) {
			push(matched, observation);
			if (!exists(sensorCounts, observation.sensor))
				sensorCounts[observation.sensor] = 0;
			sensorCounts[observation.sensor] += observation.count;
		}
	}
	let topology = classifyEvidenceType(sensorCounts, matched);
	let thresholds = CLASSIFICATION_THRESHOLDS[mode];
	let score = 0;
	let reasons = [], evidence = [], ipSet = [];
	if (exists(sensorCounts, 'neighbor') && exists(sensorCounts, 'dhcp')) {
		score += 14;
		push(reasons, 'same_mac_in_neighbor_and_dhcp');
	}
	if (topology.sharedGateway > 0 && topology.strongCount > 0) {
		score += 12;
		push(reasons, 'shared_gateway_correlation');
	}
	if (topology.bridgedRepeater > 0) {
		score += 60;
		push(reasons, 'direct_l2_bridge_or_wds_topology');
	}
	if (topology.wirelessMesh > 0) {
		score += 42;
		push(reasons, 'explicit_mesh_topology');
	}
	if (topology.directNat > 0) {
		score += 45;
		push(reasons, 'forwarded_flows_without_client_source_mac');
	}
	if (exists(sensorCounts, 'syn') && exists(sensorCounts, 'ttl')) {
		score += 10;
		push(reasons, 'syn_and_ttl_observed_same_source_mac');
	}
	if (exists(sensorCounts, 'ttl')) {
		let hops = [];
		for (let observation in matched)
			if (observation.sensor == 'ttl')
				for (let hop in keys(observation.data))
					if (isInteger(int(hop), 0, 255) && index(hops, int(hop)) < 0)
						push(hops, int(hop));
		if (length(hops) > 1 && exists(sensorCounts, 'dhcp') && exists(sensorCounts, 'ttl')) {
			score += 12;
			push(reasons, 'multiple_initial_ttl_candidates_same_mac');
		}
	}
	if (exists(sensorCounts, 'conntrack')) {
		push(reasons, 'flow_counts_are_not_device_counts');
	}
	if (exists(sensorCounts, 'dhcp')) {
		push(reasons, 'dhcp_fields_are_weak_identity_hints');
	}
	if (length(sensorCounts) >= 3) {
		score += 10;
		push(reasons, 'multiple_independent_sensors');
	}
	if (filteredOut)
		push(reasons, 'evidence_from_other_interfaces_excluded');
	if (!length(matched))
		push(reasons, 'no_recent_correlated_evidence');
	if (topology.type == 'undetermined' && length(matched) > 0)
		push(reasons, 'insufficient_topology_evidence');
	if (topology.type != 'undetermined' && length(sensorCounts) >= 3) {
		score += 10;
		push(reasons, 'independent_sensors_corroborate_topology');
	}
	let identityKeys = [ target, device ];
	for (let observation in matched) {
		if (observation.data?.ip !== null)
			push(identityKeys, observation.data.ip);
		for (let ip in observation.data?.ips ?? [])
			push(identityKeys, ip);
	}
	let whitelisted = isWhitelisted(state, identityKeys);
	if (whitelisted)
		unshift(reasons, 'whitelisted');
	let status = 'Normal';
	let confidence = 0;
	if (whitelisted) {
		status = 'Normal';
		confidence = 0;
	}
	else if (topology.type != 'undetermined' && topology.strongCount > 0
		&& score >= thresholds.confirmed) {
		status = 'Confirmed';
		confidence = score;
	}
	else if (topology.type != 'undetermined' && topology.strongCount > 0
		&& score >= thresholds.suspected) {
		status = 'Suspected';
		confidence = score;
	}
	else if (topology.type == 'undetermined' && score >= thresholds.suspected
		&& length(sensorCounts) >= 2) {
		status = 'Suspected';
		confidence = min(score, thresholds.confirmed - 1);
	}
	for (let observation in matched) {
		push(evidence, { sensor: observation.sensor, key: observation.key,
			count: observation.count, timestamp: observation.lastSeen,
			interface: interfaceForObservation(state, observation) });
	}
	let mac = validMac(target) ? target : null;
	if (state.ipToMac) {
		for (let ip in keys(state.ipToMac))
			if (state.ipToMac[ip] == target)
				push(ipSet, ip);
	}
	return { device: target, inputDevice: device, status: status,
		type: topology.type, classificationMode: mode,
		thresholds: thresholds, confidence: min(confidence, 100), score: score,
		reasons: reasons, evidence: evidence, sensorCounts: sensorCounts,
		mac: mac, ips: ipSet, lastSeen: matched.length ? max(map(matched, function(o) { return o.lastSeen ?? 0; })) : null,
		interface: interfaceName, topology: topology, at: now,
		limited: state.limited, dropped: state.dropped, whitelisted: whitelisted };
};

export function classify(state, device, now, options) {
	return classifyDevice(state, device, now, options);
};

export function classifyDevices(state, now, options) {
	requireEntry(state, 'detector state');
	if (!isInteger(now, 0, null))
		die('invalid classification time');
	let macSet = {};
	for (let mac in keys(state.aliases))
		macSet[mac] = true;
	for (let keyName in keys(state.observations)) {
		let mac = observationMac(state.observations[keyName]);
		if (mac !== null)
			macSet[mac] = true;
	}
	if (state.ipToMac)
		for (let mac in keys(state.ipToMac))
			macSet[state.ipToMac[mac]] = true;
	let results = [];
	for (let mac in keys(macSet))
		push(results, classifyDevice(state, mac, now, options));
	return results;
};

export function capability(name, available, reason, details) {
	return { name: name, available: available === true, reason: reason ?? null,
		details: details ?? {} };
};

export function reportCapabilities(capabilities, state) {
	let result = {};
	for (let name in SENSOR_NAMES) {
		let sensor = state !== null && exists(state?.sensors, name) ? state.sensors[name] : null;
		let available = sensor !== null && sensor.available === true;
		result[name] = capability(name, available,
			available ? 'At least one bounded observation was recorded.' :
				'Sensor is disabled or no supported source was detected.',
			{ lastSample: sensor !== null ? sensor.lastSample : null,
				limited: sensor !== null ? sensor.limited : false });
	}
	for (let name in capabilities ?? {})
		result[name] = capabilities[name];
	return result;
};

export function summarize(state, now, maxAge) {
	requireEntry(state, 'detector state');
	maxAge ??= 900;
	if (!isInteger(now, 0, null) || !isInteger(maxAge, 0, null))
		die('invalid summary time or age');
	let result = [];
	let observationKeys = sort(keys(state.observations));
	for (let keyName in observationKeys) {
		let entry = state.observations[keyName];
		if (now >= entry.firstSeen && now - entry.lastSeen <= maxAge) {
			push(result, { key: keyName, sensor: entry.sensor, count: entry.count,
				firstSeen: entry.firstSeen, lastSeen: entry.lastSeen });
		}
		else
			delete state.observations[keyName];
	}
	state.aliases = {};
	state.ipToMac = {};
	state.observationInterfaces = {};
	state.synSignatures = {};
	for (let keyName in keys(state.observations)) {
		let entry = state.observations[keyName];
		let mac = observationMac(entry);
		if (mac === null)
			continue;
		linkMac(state, mac, entry.data.interface);
		if (entry.data.ip !== null)
			linkIp(state, entry.data.ip, mac);
		for (let ip in entry.data.ips ?? [])
			linkIp(state, ip, mac);
		if (entry.sensor == 'syn') {
			state.synSignatures[mac] ??= {};
			state.synSignatures[mac][entry.key] = entry.lastSeen;
		}
	}
	let events = [];
	for (let index = 0; index < length(state.events); index++) {
		let event = state.events[index];
		if (now - event.at <= maxAge)
			push(events, event);
	}
	state.events = events;
	state.startedAt ??= now;
	state.updatedAt = now;
	state.summary = { observations: result, events: events, dropped: state.dropped,
		limited: state.limited, capabilities: reportCapabilities(state.capabilities, state),
		sensors: state.sensors, startedAt: state.startedAt, updatedAt: now };
	return state.summary;
};
