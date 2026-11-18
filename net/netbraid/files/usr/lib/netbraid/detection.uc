'use strict';

import * as fs from 'fs';
import { connect } from 'ubus';
import {
	SENSOR_NAMES, SENSOR_LIMITS, CAPABILITY_REASONS, CAVEATS,
	createDetector, setWhitelist, summarize, classifyDevice,
	recordTtl, recordSynFingerprint, recordWifiAssociation,
	observeNeighborSnapshot, observeDhcpLeases, observeConntrackSnapshot
} from './detector.uc';

function requireObject(value, label) {
	if (type(value) != 'object')
		die(sprintf('%s must be an object', label));
	return value;
};

function mapKeys(value) {
	let result = [];
	if (type(value) != 'object')
		return result;
	for (let key in value)
		push(result, key);
	return result;
};

function numberValue(value) {
	if (type(value) == 'int' || type(value) == 'double')
		return int(value);
	if (type(value) == 'string' && match(value, /^-?[0-9]+$/) !== null)
		return int(value);
	return null;
};

function readBoundedLines(path, maximumBytes, maximumLines, files) {
	if (files !== null && files[path] !== null) {
		let lines = files[path];
		if (type(lines) != 'array')
			die('fixture lines must be an array: ' + path);
		return { available: true, lines: slice(lines, 0, maximumLines),
			limited: length(lines) > maximumLines, bytes: 0 };
	}
	let file = fs.open(path, 'r');
	if (!file)
		return { available: false, lines: [], limited: false, bytes: 0 };
	let text = file.read(maximumBytes + 1);
	file.close();
	if (text === null)
		return { available: false, lines: [], limited: false, bytes: 0 };
	let limited = length(text) > maximumBytes;
	let lines = split(substr(text, 0, maximumBytes), '\n');
	if (limited && length(lines))
		pop(lines);
	return { available: true, lines: slice(lines, 0, maximumLines),
		limited: limited || length(lines) > maximumLines, bytes: min(length(text), maximumBytes) };
};

function runCommand(command, maximumBytes, maximumLines, runner) {
	if (runner !== null)
		return runner(command, maximumBytes, maximumLines);
	let handle = fs.popen(command, 'r');
	if (!handle)
		return { available: false, lines: [], limited: false, bytes: 0, error: 'popen failed' };
	let text = handle.read(maximumBytes + 1);
	handle.close();
	if (text === null)
		return { available: false, lines: [], limited: false, bytes: 0, error: 'no output' };
	let limited = length(text) > maximumBytes;
	let lines = split(substr(text, 0, maximumBytes), '\n');
	if (limited && length(lines))
		pop(lines);
	return { available: true, lines: slice(lines, 0, maximumLines),
		limited: limited || length(lines) > maximumLines, bytes: min(length(text), maximumBytes) };
};

function realUbusList() {
	let bus = connect(null, 1200);
	if (!bus)
		return null;
	let result;
	try { result = bus.list(); }
	catch (error) { result = null; }
	bus.disconnect();
	return result;
};

function realUbusCall(objectName, method, params) {
	let bus = connect(null, 1200);
	if (!bus)
		return null;
	let result;
	try { result = bus.call(objectName, method, params ?? {}); }
	catch (error) { result = null; }
	bus.disconnect();
	return result;
};

function hasUbusMethod(serviceList, objectName, method) {
	if (serviceList === null)
		return false;
	if (type(serviceList) == 'array') {
		for (let entry in serviceList)
			if (entry == objectName)
				return true;
		return false;
	}
	let methods = serviceList[objectName];
	if (type(methods) != 'object')
		return false;
	return exists(methods, method);
};

function collectSetElements(value, elements) {
	if (type(value) != 'object' && type(value) != 'array')
		return;
	if (exists(value, 'elem')) {
		let entries = value.elem;
		if (type(entries) == 'array') {
			for (let entry in entries)
				push(elements, entry);
		}
		else
			push(elements, entries);
		return;
	}
	if (type(value) == 'array') {
		for (let entry in value)
			collectSetElements(entry, elements);
		return;
	}
	for (let key in value)
		collectSetElements(value[key], elements);
};

function parseNftSet(text) {
	if (text === null || trim(text) === '')
		return [];
	let document;
	try { document = json(text); }
	catch (error) { return []; }
	let elements = [];
	collectSetElements(document, elements);
	return elements;
};

function keyText(key) {
	if (type(key) == 'array')
		return join(',', map(key, function(value) { return '' + value; }));
	return '' + key;
};

function featureFromKey(text) {
	let parts = split(text, /[,|]/);
	let features = { mss: null, windowScale: null, window: null, options: null,
		sackPermitted: false, ttl: null };
	for (let part in parts) {
		let pair = split(part, '=');
		let name = trim(pair[0]);
		let value = pair.length > 1 ? pair[1] : null;
		if (name == 'mss' || name == 'maxseg')
			features.mss = numberValue(value);
		else if (name == 'ws' || name == 'window-scale' || name == 'windowScale')
			features.windowScale = numberValue(value);
		else if (name == 'window')
			features.window = numberValue(value);
		else if (name == 'sack' || name == 'sack-permitted')
			features.sackPermitted = true;
		else if (name == 'ttl' || name == 'hop-limit')
			features.ttl = numberValue(value);
		else if (name == 'options')
			features.options = value;
	}
	return features;
};

function ttlFromElement(element) {
	let key = element.key ?? element;
	let ttl = type(key) == 'object' ? (key.ttl ?? key['ip-ttl'] ?? key['ip6-hop-limit']) : key;
	return numberValue(ttl);
};

function featureFromElement(element) {
	let key = element.key ?? element;
	if (type(key) == 'object') {
		let parts = [];
		for (let name in mapKeys(key)) {
			push(parts, name + '=' + (type(key[name]) == 'boolean' && key[name] ? '1' : '' + key[name]));
		}
		return featureFromKey(join(',', parts));
	}
	return featureFromKey(keyText(key));
};

function counterPackets(element) {
	let counter = element.counter ?? {};
	let packets = numberValue(counter.packets ?? element.packets ?? 0);
	return packets === null ? 0 : packets;
};

function collectWifiInterfaces(value, result) {
	if (type(value) != 'object' && type(value) != 'array')
		return;
	if (type(value) == 'array') {
		for (let entry in value)
			collectWifiInterfaces(entry, result);
		return;
	}
	let ifname = value.ifname ?? value.interface ?? value.ifname;
	if (type(ifname) == 'string' && ifname !== '') {
		result[ifname] = {
			ifname: ifname,
			ssid: value.ssid ?? null,
			bssid: value.bssid ?? null,
			bridge: value.bridge ?? value.network ?? null,
			wds: value.wds === true || value['wds_sta'] === true
		};
	}
	for (let key in value)
		collectWifiInterfaces(value[key], result);
};

function sourceRecord(sensor, source, sample, count) {
	return { sensor: sensor, source: source, available: sample.available,
		limited: sample.limited, bytes: sample.bytes ?? 0, records: count,
		error: sample.error ?? null };
};

export function createCollector(model, options) {
	requireObject(model, 'model');
	let config = model.detector ?? {};
	let state = options?.state ?? createDetector({
		enabled: config.enabled === true,
		interval: config.interval ?? 30,
		retention: config.retention ?? 900,
		mode: config.mode ?? 'auto'
	});
	setWhitelist(state, config.whitelist ?? []);
	return {
		model: model,
		state: state,
		options: options ?? {},
		sources: [],
		limitations: [],
		caveats: CAVEATS
	};
};

export function detectCapabilities(collector, observedSets) {
	let options = collector.options;
	let files = options.files ?? null;
	let commandRunner = options.commandRunner ?? null;
	let ubusList = options.ubusList ?? realUbusList;
	let services = ubusList();
	let observed = observedSets ?? {};
	let ttlSets = observed.ttl === true;
	let synSets = observed.syn === true;
	let hostapd = [], wireless = false;
	for (let name in mapKeys(services ?? {}))
		if (substr(name, 0, 8) == 'hostapd.')
			push(hostapd, name);
	if (services !== null && type(services) != 'array')
		wireless = exists(services, 'network.wireless');
	let result = {
		neighbor: { available: files !== null || fs.access('/proc/net/arp'),
			reason: CAPABILITY_REASONS.neighbor,
			details: { arpCache: files !== null || fs.access('/proc/net/arp'),
				ipv6NeighborCommand: commandRunner !== null || fs.access('/sbin/ip') || fs.access('/usr/sbin/ip') } },
		dhcp: { available: true, reason: CAPABILITY_REASONS.dhcp,
			details: { leaseFile: files !== null || fs.access('/tmp/dhcp.leases'), ubus: services !== null } },
		ttl: { available: ttlSets, reason: ttlSets ? CAPABILITY_REASONS.ttl :
			'No kernel-side nftables TTL/hop-limit aggregation sets are installed; no packet capture is attempted.',
			details: { sets: [ 'inet netbraid nb_ttl4', 'inet netbraid nb_ttl6' ], hardwareOffload: 'May be bypassed or unsupported on flow-offloaded paths.' } },
		conntrack: { available: files !== null || fs.access('/proc/net/nf_conntrack'),
			reason: CAPABILITY_REASONS.conntrack,
			details: { path: '/proc/net/nf_conntrack' } },
		syn: { available: synSets, reason: synSets ? CAPABILITY_REASONS.syn :
			'No kernel-side nftables SYN feature aggregation set is installed; no per-packet userspace capture is used.',
			details: { sets: [ 'inet netbraid nb_syn' ], hardwareOffload: 'May be bypassed or unsupported on flow-offloaded paths.' } },
		wifi: { available: length(hostapd) > 0 || wireless,
			reason: length(hostapd) > 0 || wireless ? CAPABILITY_REASONS.wifi :
				'No hostapd ubus object or network.wireless status is available.',
			details: { hostapd: hostapd, wirelessStatus: wireless } }
	};
	collector.state.capabilities = result;
	return result;
};

export function sample(collector, now) {
	requireObject(collector, 'collector');
	if (type(now) != 'int' || now < 0)
		now = time();
	let options = collector.options;
	let model = collector.model;
	let detectorConfig = model.detector ?? {};
	let state = collector.state ?? createDetector(detectorConfig);
	let files = options.files ?? null;
	let commandRunner = options.commandRunner ?? null;
	let ubusList = options.ubusList ?? realUbusList;
	let ubusCall = options.ubusCall ?? realUbusCall;
	let enabled = model.main.detectorEnabled === true && detectorConfig.enabled === true;
	let result = {
		enabled: enabled, sampledAt: now, readOnly: true,
		classificationAvailable: true, autoBlocking: false,
		sources: [], limitations: [], caveats: [],
		observations: [], events: [], classifications: [],
		dropped: state.dropped, limited: state.limited,
		capabilities: {}
	};
	if (!enabled) {
		push(result.limitations, 'Detection is disabled; no sources were sampled.');
		return result;
	}

	if (detectorConfig.neighborEnabled !== false) {
		let source = readBoundedLines('/proc/net/arp', SENSOR_LIMITS.neighbor.sampleBytes,
			SENSOR_LIMITS.neighbor.sampleLines, files);
		let count = source.available ? observeNeighborSnapshot(state, 'br-lan', source.lines, now) : 0;
		push(result.sources, sourceRecord('neighbor', '/proc/net/arp', source, count));
		if (commandRunner !== null || fs.access('/sbin/ip') || fs.access('/usr/sbin/ip')) {
			let ndp = commandRunner !== null
				? commandRunner('ip -6 neigh show', SENSOR_LIMITS.neighbor.sampleBytes, SENSOR_LIMITS.neighbor.sampleLines)
				: runCommand('ip -6 neigh show', SENSOR_LIMITS.neighbor.sampleBytes, SENSOR_LIMITS.neighbor.sampleLines, null);
			let ndpCount = ndp.available ? observeNeighborSnapshot(state, 'br-lan', ndp.lines, now) : 0;
			push(result.sources, sourceRecord('neighbor', 'ip -6 neigh show', ndp, ndpCount));
		}
	}

	if (detectorConfig.dhcpEnabled !== false) {
		let source = readBoundedLines('/tmp/dhcp.leases', SENSOR_LIMITS.dhcp.sampleBytes,
			SENSOR_LIMITS.dhcp.sampleLines, files);
		let count = source.available ? observeDhcpLeases(state, 'br-lan', source.lines, now) : 0;
		push(result.sources, sourceRecord('dhcp', '/tmp/dhcp.leases', source, count));
		let services = ubusList();
		if (services !== null && hasUbusMethod(services, 'dhcp', 'leases')) {
			let leases = ubusCall('dhcp', 'leases', {});
			if (type(leases) == 'object') {
				let lines = [];
				for (let lease in (leases.leases ?? [])) {
					push(lines, sprintf('%s %s %s %s %s', lease.expires ?? '', lease.mac ?? '',
						lease.ip ?? '', lease.clientid ?? '', lease.hostname ?? ''));
				}
				let count2 = observeDhcpLeases(state, 'br-lan', lines, now);
				push(result.sources, { sensor: 'dhcp', source: 'ubus dhcp.leases', available: true,
					limited: false, bytes: 0, records: count2, error: null });
			}
		}
	}

	if (detectorConfig.conntrackEnabled !== false) {
		let source = readBoundedLines('/proc/net/nf_conntrack', SENSOR_LIMITS.conntrack.sampleBytes,
			SENSOR_LIMITS.conntrack.sampleLines, files);
		let count = source.available ? observeConntrackSnapshot(state, 'br-lan', source.lines, now) : 0;
		push(result.sources, sourceRecord('conntrack', '/proc/net/nf_conntrack', source, count));
	}

	let observedSets = { ttl: false, syn: false };
	if (detectorConfig.ttlEnabled !== false) {
		for (let family in [ 4, 6 ]) {
			let setName = family == 4 ? 'nb_ttl4' : 'nb_ttl6';
			let command = 'nft -j list set inet netbraid ' + setName;
			let sampleSet = commandRunner !== null
				? commandRunner(command, 65536, 1024)
				: runCommand(command, 65536, 1024, null);
			let elements = parseNftSet(join('\n', sampleSet.lines));
			observedSets.ttl = observedSets.ttl || length(elements) > 0;
			let count = 0;
			for (let element in elements) {
				let value = ttlFromElement(element);
				if (value !== null && value >= 0 && value <= 255
					&& recordTtl(state, 'nft-' + setName, family, value, now))
					count += counterPackets(element);
			}
			push(result.sources, { sensor: 'ttl', source: command, available: sampleSet.available,
				limited: sampleSet.limited, bytes: sampleSet.bytes ?? 0, records: count, error: sampleSet.error ?? null });
		}
	}

	if (detectorConfig.synEnabled === true) {
		let command = 'nft -j list set inet netbraid nb_syn';
		let sampleSet = commandRunner !== null
			? commandRunner(command, 65536, 1024)
			: runCommand(command, 65536, 1024, null);
		let elements = parseNftSet(join('\n', sampleSet.lines));
		observedSets.syn = length(elements) > 0;
		let count = 0;
		for (let element in elements) {
			let features = featureFromElement(element);
			if (recordSynFingerprint(state, 'nft-nb_syn', '00:11:22:33:44:66', features, now))
				count += counterPackets(element);
		}
		push(result.sources, { sensor: 'syn', source: command, available: sampleSet.available,
			limited: sampleSet.limited, bytes: sampleSet.bytes ?? 0, records: count, error: sampleSet.error ?? null });
	}

	if (detectorConfig.wifiEnabled !== false) {
		let services = ubusList();
		let interfaces = {};
		let wireless = services !== null ? ubusCall('network.wireless', 'status', {}) : null;
		if (wireless !== null)
			collectWifiInterfaces(wireless, interfaces);
		let hostapdObjects = mapKeys(services ?? {});
		for (let objectName in hostapdObjects) {
			if (substr(objectName, 0, 8) != 'hostapd.')
				continue;
			if (!hasUbusMethod(services, objectName, 'get_clients'))
				continue;
			let ifname = substr(objectName, 8);
			let status = hasUbusMethod(services, objectName, 'status')
				? ubusCall(objectName, 'status', {}) : null;
			if (status !== null)
				collectWifiInterfaces(status, interfaces);
			let clients = ubusCall(objectName, 'get_clients', {});
			let topology = interfaces[ifname] ?? {
				ifname: ifname, ssid: null, bssid: null, bridge: null, wds: false
			};
			let entries = [];
			if (type(clients) == 'object') {
				for (let key in clients) {
					if (key != 'clients' && type(clients[key]) == 'object')
						push(entries, { mac: key, info: clients[key] });
				}
				if (type(clients.clients) == 'object') {
					for (let key in clients.clients)
						push(entries, { mac: key, info: clients.clients[key] });
				}
			}
			let count = 0;
			for (let entry in entries) {
				let mac = entry.mac;
				if (!match(mac, /^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/))
					continue;
				let role = entry.info.wds === true || entry.info.wds_sta === true ? 'wds' : 'sta';
				if (recordWifiAssociation(state, ifname, mac, role, topology, now))
					count++;
			}
			push(result.sources, { sensor: 'wifi', source: 'ubus ' + objectName + '.get_clients',
				available: clients !== null, limited: false, bytes: 0, records: count, error: clients === null ? 'ubus call failed' : null });
		}
	}

	let summary = summarize(state, now, detectorConfig.retention ?? 900);
	result.observations = summary.observations;
	result.events = summary.events;
	result.dropped = summary.dropped;
	result.limited = summary.limited;
	result.capabilities = detectCapabilities(collector, observedSets);
	for (let name in summary.capabilities)
		if (!exists(result.capabilities, name))
			result.capabilities[name] = summary.capabilities[name];
	let devices = {};
	for (let entry in summary.observations) {
		let found = match(entry.key, /([0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2})/);
		if (found !== null)
			devices[lc(found[1])] = true;
	}
	for (let device in mapKeys(devices))
		push(result.classifications, classifyDevice(state, device, now));
	return result;
};
