'use strict';

import { isInteger, identifier, requireArray, requireTable, toSnakeCase } from './util.uc';
import { compile, renderClassification } from './planner.uc';

const PROTOCOLS = [ 'all', 'tcp', 'udp', 'icmp', 'icmpv6' ];
const FAMILIES = [ 'ip', 'ip6' ];
const ADDRESS_RE = /^[0-9a-fA-F:.]+(\/[0-9]+)?$/;
const NFT_TABLE = 'netbraid';
const DETECTION_SETS = {
	ttl4: 'nb_ttl4',
	ttl6: 'nb_ttl6',
	syn: 'nb_syn'
};

function validAddress(value) {
	return type(value) == 'string' && value !== '' && match(value, ADDRESS_RE) != null;
};

function validPortRange(value) {
	if (type(value) != 'string' || !match(value, /^[0-9]+(-[0-9]+)?$/))
		return false;
	let parts = split(value, '-');
	let first = int(parts[0]);
	let last = length(parts) == 2 ? int(parts[1]) : first;
	return first >= 1 && last <= 65535 && first <= last;
};

function quoteName(value) {
	if (!identifier(value, 32))
		die('nft identifier is invalid');
	return value;
};

function selector(rule) {
	let terms = [];
	if (validAddress(rule.source))
		push(terms, sprintf('%s saddr %s', rule.family == 'ip6' ? 'ip6' : 'ip', rule.source));
	if (validAddress(rule.destination))
		push(terms, sprintf('%s daddr %s', rule.family == 'ip6' ? 'ip6' : 'ip', rule.destination));
	if (rule.protocol != 'all') {
		push(terms, 'meta l4proto ' + rule.protocol);
		if (validPortRange(rule.sourcePort))
			push(terms, 'th sport ' + rule.sourcePort);
		if (validPortRange(rule.destinationPort))
			push(terms, 'th dport ' + rule.destinationPort);
	}
	if (identifier(rule.ingress, 15))
		push(terms, 'iifname "' + rule.ingress + '"');
	return length(terms) ? join(' ', terms) + ' ' : '';
};

export function detectionSetDefinitions() {
	return {
		ttl4: { name: DETECTION_SETS.ttl4, type: 'ipv4_addr . ip ttl', comment: 'bounded IPv4 TTL samples' },
		ttl6: { name: DETECTION_SETS.ttl6, type: 'ipv6_addr . ip6 hop-limit', comment: 'bounded IPv6 hop-limit samples' },
		syn: { name: DETECTION_SETS.syn, type: 'inet_service . tcp flags . integer . integer', comment: 'bounded TCP SYN feature counters' }
	};
};

function renderDetectionRules(enabled) {
	let rules = [];
	if (enabled.ttl !== false) {
		push(rules, 'add set inet ' + NFT_TABLE + ' ' + DETECTION_SETS.ttl4 +
			" { type ipv4_addr . ip ttl; size 65536; flags timeout; timeout 15m; counter; }");
		push(rules, 'add set inet ' + NFT_TABLE + ' ' + DETECTION_SETS.ttl6 +
			" { type ipv6_addr . ip6 hop-limit; size 65536; flags timeout; timeout 15m; counter; }");
		push(rules, 'add chain inet ' + NFT_TABLE + ' detect_pre');
		push(rules, 'add rule inet ' + NFT_TABLE + ' detect_pre type filter hook prerouting priority -149; policy accept;');
		push(rules, 'add rule inet ' + NFT_TABLE + ' detect_pre meta nfproto ipv4 update @' +
			DETECTION_SETS.ttl4 + ' { ip saddr . ip ttl } counter comment "netbraid bounded ttl sample"');
		push(rules, 'add rule inet ' + NFT_TABLE + ' detect_pre meta nfproto ipv6 update @' +
			DETECTION_SETS.ttl6 + ' { ip6 saddr . ip6 hop-limit } counter comment "netbraid bounded hop-limit sample"');
	}
	if (enabled.syn === true) {
		push(rules, 'add set inet ' + NFT_TABLE + ' ' + DETECTION_SETS.syn +
			" { type inet_service . integer . integer . integer; size 4096; flags timeout; timeout 15m; counter; }");
		push(rules, 'add chain inet ' + NFT_TABLE + ' detect_syn');
		push(rules, 'add rule inet ' + NFT_TABLE + ' detect_syn type filter hook prerouting priority -148; policy accept;');
		push(rules, 'add rule inet ' + NFT_TABLE + ' detect_syn tcp flags syn / fin,syn,rst,ack ' +
			'update @' + DETECTION_SETS.syn +
			' { tcp dport . tcp option maxseg size . tcp window . ip ttl } counter ' +
			'comment "netbraid bounded syn header sample"');
	}
	return rules;
};

export function validateRule(rule) {
	requireTable(rule, 'rule');
	if (!identifier(rule.name, 32))
		die('rule.name is invalid');
	if (rule.enabled === false)
		return null;
	if (!identifier(rule.policy, 32))
		die('rule.policy is invalid');
	if (!isInteger(rule.priority, 1, 65535))
		die('rule.priority out of range');
	if (index(FAMILIES, rule.family) < 0)
		die('rule.family must be ip or ip6');
	if (index(PROTOCOLS, rule.protocol) < 0)
		die('unsupported rule protocol');
	if (rule.source !== null && !validAddress(rule.source))
		die('rule.source must be an address or subnet');
	if (rule.destination !== null && !validAddress(rule.destination))
		die('rule.destination must be an address or subnet');
	if (rule.sourcePort !== null && !validPortRange(rule.sourcePort))
		die('rule.sourcePort is invalid');
	if (rule.destinationPort !== null && !validPortRange(rule.destinationPort))
		die('rule.destinationPort is invalid');
	if (rule.ingress !== null && !identifier(rule.ingress, 15))
		die('rule.ingress is invalid');
	return rule;
};

export function parseRules(document) {
	requireArray(document, 'rule document');
	let rules = [];
	let seen = {};
	for (let entry in document) {
		requireTable(entry, 'rule section');
		if (entry['.type'] != null && entry['.type'] != 'rule')
			continue;
		let name = entry['.name'] ?? entry.name;
		if (!identifier(name, 32) || exists(seen, name))
			die('rule name must be unique and valid');
		seen[name] = true;
		let rule = {
			name: name,
			enabled: entry.enabled === null ? true : entry.enabled,
			policy: entry.policy,
			priority: entry.priority ?? 100,
			family: entry.family ?? 'ip',
			protocol: entry.protocol ?? 'all',
			source: entry.source ?? null,
			destination: entry.destination ?? null,
			sourcePort: entry.source_port ?? null,
			destinationPort: entry.destination_port ?? null,
			ingress: entry.ingress ?? null
		};
		validateRule(rule);
		push(rules, rule);
	}
	sort(rules, function(left, right) {
		if (left.priority != right.priority)
			return left.priority - right.priority;
		return left.name < right.name ? -1 : (left.name > right.name ? 1 : 0);
	});
	return rules;
};

function buildRoutes(policyPlans, assignments) {
	let routes = [];
	let seen = {};
	for (let plan in policyPlans) {
		for (let bucket in plan.buckets) {
			let member = assignments[bucket.name];
			let key = sprintf('%s:%d', member.interface, bucket.tableId);
			if (exists(seen, key))
				continue;
			seen[key] = true;
			push(routes, {
				family: plan.family,
				tableId: bucket.tableId,
				priority: bucket.priority,
				mark: bucket.mark,
				interface: member.interface,
				fwmark: sprintf('0x%08x/0x%08x', bucket.mark, plan.markMask)
			});
		}
	}
	sort(routes, function(left, right) {
		if (left.priority != right.priority)
			return left.priority - right.priority;
		return left.tableId - right.tableId;
	});
	return routes;
};

export function buildPlan(model, occupied, onlineMembers, now) {
	requireTable(model, 'config model');
	if (model.main.enabled !== true)
		die('NetBraid is disabled');
	if (!isInteger(now, 0, null))
		die('now must be a nonnegative integer');
	let policies = {};
	for (let policy in model.policies)
		policies[policy.name] = policy;
	let rules = parseRules(model.rules ?? []);
	let assignments = {}, memberList = [];
	let nextId = 1;
	for (let member in model.members) {
		if (member.enabled === false)
			continue;
		let assignment = {
			name: member.name,
			id: nextId++,
			weight: member.weight,
			priority: member.priority,
			interface: member.interface,
			family: member.family,
			online: onlineMembers[member.name] === true
		};
		assignments[member.name] = assignment;
		push(memberList, assignment);
	}
	let policyPlans = [];
	for (let rule in rules) {
		if (!exists(policies, rule.policy))
			die(sprintf('rule %s references unknown policy %s', rule.name, rule.policy));
		let policy = policies[rule.policy];
		let members = [];
		for (let name in policy.members) {
			if (!exists(assignments, name))
				die(sprintf('policy %s references disabled member %s', policy.name, name));
			push(members, assignments[name]);
		}
		let compiled = compile(policy, memberList, model.main, occupied);
		push(policyPlans, {
			rule: rule.name,
			policy: policy.name,
			family: rule.family,
			selector: selector(rule),
			classification: renderClassification(compiled, rule.family == 'ip' ? 'ip' : 'ip6',
				rule.protocol == 'tcp' || rule.protocol == 'udp'),
			markMask: compiled.markMask,
			buckets: compiled.buckets
		});
	}
	return {
		generatedAt: now,
		markMask: length(policyPlans) ? policyPlans[0].markMask : 0,
		policies: policyPlans,
		routes: buildRoutes(policyPlans, assignments),
		detectionRules: renderDetectionRules(model.detector ?? {})
	};
};

export function renderCommands(plan, detectorConfig) {
	requireTable(plan, 'routing plan');
	let commands = [];
	for (let route in plan.routes) {
		let ip = route.family == 'ip6' ? 'ip -6' : 'ip -4';
		push(commands, sprintf('%s rule add priority %d fwmark %s lookup %d',
			ip, route.priority, route.fwmark, route.tableId));
	}
	for (let policy in plan.policies)
		for (let rule in policy.classification)
			push(commands, 'nft add rule ' + NFT_TABLE + ' classify ' + policy.selector + rule);
	return commands;
};
