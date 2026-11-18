'use strict';

import * as config from '../../../net/netbraid/files/usr/lib/netbraid/config.uc';
import * as routing from '../../../net/netbraid/files/usr/lib/netbraid/routing.uc';

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

let document = [
	{ '.type': 'main', '.name': 'main', enabled: '1', mark_shift: '16', table_base: '10000', priority_base: '20000' },
	{ '.type': 'member', '.name': 'wan', interface: 'wan', weight: '2', priority: '1' },
	{ '.type': 'member', '.name': 'lte', interface: 'wwan', weight: '1', priority: '1' },
	{ '.type': 'policy', '.name': 'balanced', mode: 'both-addresses-and-ports', member: [ 'wan', 'lte' ] },
	{ '.type': 'rule', '.name': 'lan', policy: 'balanced', priority: '10', family: 'ip', source: '192.0.2.0/24', protocol: 'tcp', destination_port: '443' }
];
let model = config.parse(document);
let occupied = { complete: true, markMasks: [], tableIds: [], priorities: [] };
model.detector.syn = true;
let plan = routing.buildPlan(model, occupied, { wan: true, lte: true }, 100);
assert(length(plan.policies) == 1, 'builds one policy plan from configured rule');
assert(length(plan.policies[0].buckets) == 2, 'weighted buckets are scoped to policy plan');
assert(plan.policies[0].buckets[0].firstBucket == 0 && plan.policies[0].buckets[0].lastBucket == 1, 'weighted PCC preserves 2:1 share');
assert(plan.policies[0].buckets[1].firstBucket == 2 && plan.policies[0].buckets[1].lastBucket == 2, 'second bucket follows first without overlap');
assert(index(plan.policies[0].selector, 'ip saddr 192.0.2.0/24') >= 0, 'rule selector includes source subnet');
assert(index(plan.policies[0].classification[0], 'th dport') >= 0, 'classification uses port hash for TCP');
assert(length(plan.routes) == 2, 'plan contains one route per active member');
assert(plan.routes[0].tableId == 10000 && plan.routes[1].tableId == 10001, 'stable table IDs are allocated from configured base');
let commands = routing.renderCommands(plan);
assert(length(commands) == 4, 'renders two ip rules and two nft classification rules');
assert(index(join('\n', commands), 'fwmark 0x00010000/0x00ff0000') >= 0, 'rendered ip rule uses isolated fwmark mask');
assert(index(join('\n', commands), 'ct mark set') >= 0, 'rendered nft rule persists connection mark');
assert(index(join('\n', plan.detectionRules), 'nb_ttl4') >= 0, 'TTL sample set is rendered for kernel-side collection');
assert(index(join('\n', plan.detectionRules), 'nb_syn') >= 0, 'SYN sample set is rendered for kernel-side collection');

let degraded = routing.buildPlan(model, occupied, { wan: false, lte: true }, 101);
assert(length(degraded.policies[0].buckets) == 1 && degraded.policies[0].buckets[0].name == 'lte', 'offline members are excluded from new-flow buckets');
assert(degraded.policies[0].buckets[0].tableId == 10001, 'offline member does not renumber surviving member');

rejects(function() { routing.buildPlan(model, occupied, {}, 102); }, 'plan without healthy members is rejected');
rejects(function() { routing.buildPlan(model, { complete: true, tableIds: [ 10001 ] }, { wan: true, lte: true }, 103); }, 'plan rejects occupied routing table');
rejects(function() { routing.buildPlan(model, { complete: true, priorities: [ 20001 ] }, { wan: true, lte: true }, 104); }, 'plan rejects occupied rule priority');
rejects(function() { routing.buildPlan(model, { complete: true, markMasks: [ 0x00ff0000 ] }, { wan: true, lte: true }, 105); }, 'plan rejects overlapping fwmark mask');
rejects(function() { routing.parseRules([ { '.type': 'rule', '.name': 'bad', policy: 'balanced', source: 'evil;drop' } ]); }, 'parseRules rejects unsafe source syntax');
rejects(function() { routing.parseRules([ { '.type': 'rule', '.name': 'bad', policy: 'balanced', destination_port: '70000' } ]); }, 'parseRules rejects invalid port');

let disabled = config.parse(document);
disabled.main.enabled = false;
rejects(function() { routing.buildPlan(disabled, occupied, { wan: true }, 106); }, 'disabled configuration cannot produce routing plan');

print('PASS ucode routing plan tests');
