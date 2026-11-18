'use strict';

import { isInteger, identifier } from './util.uc';

export const modes = [
	'src-address', 'dst-address', 'both-addresses',
	'src-port', 'dst-port', 'both-ports',
	'src-address-and-port', 'dst-address-and-port', 'both-addresses-and-ports'
];

const modeSet = {};
for (let name in modes)
	modeSet[name] = true;

function toBoolean(value, fallback) {
	if (value === null)
		return fallback;
	if (value === true || value === false)
		return value;
	let text = '' + value;
	if (text == '1' || text == 'true' || text == 'on' || text == 'yes')
		return true;
	if (text == '0' || text == 'false' || text == 'off' || text == 'no')
		return false;
	return null;
};

function toInteger(value, fallback) {
	if (value === null)
		return fallback;
	if (type(value) == 'string') {
		if (!match(value, /^-?[0-9]+$/))
			die('config integer must contain only decimal digits');
		value = +value;
	}
	if (!isInteger(value, null, null))
		die('config value must be an integer');
	return value;
};

function toList(value) {
	if (value === null)
		return [];
	if (type(value) == 'array')
		return value;
	return [ value ];
};

export function validate(model) {
	if (type(model) != 'object')
		die('config model must be an object');
	if (model.main.enabled !== true && model.main.enabled !== false)
		die('main.enabled must be a boolean');
	if (!isInteger(model.main.markShift, 16, 24))
		die('main.markShift must be between 16 and 24');
	if (!isInteger(model.main.tableBase, 10000, 50000))
		die('main.tableBase outside supported range');
	if (!isInteger(model.main.priorityBase, 20000, 30000))
		die('main.priorityBase outside supported range');
	for (let key in [ 'healthEnabled', 'detectorEnabled', 'portalEnabled' ])
		if (model.main[key] !== true && model.main[key] !== false)
			die(sprintf('main.%s must be a boolean', key));
	model.detector ??= {
		enabled: false, interval: 30, retention: 900, mode: 'auto', whitelist: [],
		ttlEnabled: true, dhcpEnabled: true, conntrackEnabled: true,
		neighborEnabled: true, synEnabled: false, wifiEnabled: true
	};
	if (index([ 'auto', 'high_confidence', 'sensitive' ], model.detector.mode) < 0)
		die('detector.mode is invalid');
	if (!isInteger(model.detector.interval, 5, 60) || !isInteger(model.detector.retention, 60, 86400))
		die('detector interval or retention is out of range');
	for (let key in [ 'enabled', 'ttlEnabled', 'dhcpEnabled', 'conntrackEnabled', 'neighborEnabled', 'synEnabled', 'wifiEnabled' ])
		if (model.detector[key] !== true && model.detector[key] !== false)
			die(sprintf('detector.%s must be a boolean', key));

	for (let name in model.health) {
		let health = model.health[name];
		if (!identifier(name, 32))
			die('health.name is invalid');
		if (type(health.targets) != 'array')
			die('health.targets must be an array');
		if (!isInteger(health.interval, 1, 3600) || !isInteger(health.timeout, 1, 60))
			die('health interval/timeout out of range');
		if (!isInteger(health.failureThreshold, 1, 100) || !isInteger(health.recoveryThreshold, 1, 100))
			die('health thresholds out of range');
		if (!isInteger(health.recoveryDelay, 0, 86400))
			die('health.recoveryDelay out of range');
		if (health.minimumTargets !== null &&
		    !isInteger(health.minimumTargets, 1, length(health.targets)))
			die('health.minimumTargets out of range');
	}

	const seenMembers = {};
	for (let member in model.members) {
		if (!identifier(member.name, 32))
			die('invalid member name');
		if (exists(seenMembers, member.name))
			die(sprintf('duplicate member: %s', member.name));
		seenMembers[member.name] = true;
		if (type(member.interface) != 'string' || member.interface === '')
			die('member.interface must be a nonempty string');
		if (!isInteger(member.weight, 1, 256) || !isInteger(member.priority, 1, 65535))
			die('member weight/priority out of range');
		if (member.health !== null && !exists(model.health, member.health))
			die(sprintf('member references unknown health section: %s', member.health));
	}

	for (let policy in model.policies) {
		if (!identifier(policy.name, 32))
			die('invalid policy name');
		if (!exists(modeSet, policy.mode))
			die(sprintf('unsupported policy mode: %s', policy.mode));
		if (type(policy.members) != 'array')
			die('policy.members must be an array');
		for (let memberName in policy.members)
			if (!exists(seenMembers, memberName))
				die(sprintf('policy references unknown member: %s', memberName));
	}
	let seenPolicies = {}, seenRules = {};
	for (let policy in model.policies)
		seenPolicies[policy.name] = true;
	for (let rule in model.rules ?? []) {
		if (!identifier(rule.name, 32) || exists(seenRules, rule.name))
			die('invalid or duplicate rule name');
		seenRules[rule.name] = true;
		if (!exists(seenPolicies, rule.policy))
			die(sprintf('rule references unknown policy: %s', rule.policy));
		if (!isInteger(rule.priority, 1, 65535))
			die('rule priority out of range');
	}
	return model;
};

export function parse(document) {
	if (type(document) != 'array')
		die('config document must be an array');

	const result = {
		main: {
			enabled: false,
			markShift: 16,
			tableBase: 10000,
			priorityBase: 20000,
			healthEnabled: true,
			detectorEnabled: false,
			portalEnabled: false,
			routerOriginated: false,
			logLevel: 'notice'
		},
		health: {},
		members: [],
		policies: [],
		rules: [],
		detector: {
			enabled: false, interval: 30, retention: 900, mode: 'auto', whitelist: [],
			ttlEnabled: true, dhcpEnabled: true, conntrackEnabled: true,
			neighborEnabled: true, synEnabled: false, wifiEnabled: true
		},
		portal: { enabled: false }
	};

	const seenNames = {};
	for (let index = 0; index < length(document); index++) {
		let section = document[index];
		if (type(section) != 'object')
			die(sprintf('config section %s must be an object', index));
		let sectionType = section['.type'];
		let sectionName = section['.name'];
		if (type(sectionType) != 'string' || sectionType === '' ||
		    type(sectionName) != 'string' || sectionName === '')
			die(sprintf('config section %s requires .type and .name', index));

		if (sectionType == 'netbraid' || sectionType == 'main') {
			if (sectionName != 'main')
				die('netbraid section must be named main');
			result.main.enabled = toBoolean(section.enabled, false);
			result.main.markShift = toInteger(section.mark_shift, 16);
			result.main.tableBase = toInteger(section.table_base, 10000);
			result.main.priorityBase = toInteger(section.priority_base, 20000);
			result.main.healthEnabled = toBoolean(section.health_enabled, true);
			result.main.detectorEnabled = toBoolean(section.detector_enabled, false);
			result.main.portalEnabled = toBoolean(section.portal_enabled, false);
			result.main.routerOriginated = toBoolean(section.router_originated, false);
			result.main.logLevel = section.log_level ?? 'notice';
		}
		else if (sectionType == 'health') {
			if (exists(result.health, sectionName))
				die(sprintf('duplicate health section: %s', sectionName));
			result.health[sectionName] = {
				name: sectionName,
				targets: toList(section.target),
				minimumTargets: toInteger(section.minimum_targets, null),
				interval: toInteger(section.interval, 5),
				timeout: toInteger(section.timeout, 2),
				failureThreshold: toInteger(section.failure_threshold, 3),
				recoveryThreshold: toInteger(section.recovery_threshold, 2),
				recoveryDelay: toInteger(section.recovery_delay, 0),
				protocols: toList(section.protocol),
				enabled: toBoolean(section.enabled, true)
			};
		}
		else if (sectionType == 'member') {
			let key = 'member:' + sectionName;
			if (exists(seenNames, key))
				die(sprintf('duplicate member: %s', sectionName));
			seenNames[key] = true;
			push(result.members, {
				name: sectionName,
				interface: section.interface,
				device: section.device,
				weight: toInteger(section.weight, 1),
				priority: toInteger(section.priority, 1),
				health: section.health,
				family: section.family ?? 'auto',
				enabled: toBoolean(section.enabled, true)
			});
		}
		else if (sectionType == 'policy') {
			let key = 'policy:' + sectionName;
			if (exists(seenNames, key))
				die(sprintf('duplicate policy: %s', sectionName));
			seenNames[key] = true;
			push(result.policies, {
				name: sectionName,
				mode: section.mode,
				members: toList(section.member),
				family: section.family ?? 'auto',
				routerOriginated: toBoolean(section.router_originated, false),
				enabled: toBoolean(section.enabled, true)
			});
		}
		else if (sectionType == 'rule') {
			let key = 'rule:' + sectionName;
			if (exists(seenNames, key))
				die(sprintf('duplicate rule: %s', sectionName));
			seenNames[key] = true;
			push(result.rules, {
				name: sectionName,
				enabled: toBoolean(section.enabled, true),
				policy: section.policy,
				priority: toInteger(section.priority, 100),
				family: section.family ?? 'ip',
				protocol: section.protocol ?? 'all',
				source: section.source ?? null,
				destination: section.destination ?? null,
				sourcePort: section.source_port ?? null,
				destinationPort: section.destination_port ?? null,
				ingress: section.ingress ?? null
			});
		}
		else if (sectionType == 'detector') {
			result.detector = {
				enabled: toBoolean(section.enabled, false),
				interval: toInteger(section.interval, 30),
				retention: toInteger(section.retention, 900),
				mode: section.mode ?? 'auto',
				whitelist: toList(section.whitelist),
				ttlEnabled: toBoolean(section.ttl, true),
				dhcpEnabled: toBoolean(section.dhcp, true),
				conntrackEnabled: toBoolean(section.conntrack, true),
				neighborEnabled: toBoolean(section.neighbor, true),
				synEnabled: toBoolean(section.syn, false),
				wifiEnabled: toBoolean(section.wifi, true)
			};
		}
		else if (sectionType == 'portal') {
			result.portal = {
				enabled: toBoolean(section.enabled, false),
				interface: section.interface,
				sessionTimeout: toInteger(section.session_timeout, 3600),
				guestNetwork: section.guest_network ?? 'guest',
				title: section.title,
				terms: section.terms
			};
		}
		else {
			die(sprintf('unknown section type: %s', sectionType));
		}
	}
	return validate(result);
};

export function enabledMembers(model) {
	let members = [];
	for (let member in model.members)
		if (member.enabled !== false)
			push(members, member);
	return members;
};
