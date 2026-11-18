'use strict';

import { pow } from 'math';
import { isInteger, identifier } from './util.uc';

const modes = {
	'src-address': [ 'saddr' ],
	'dst-address': [ 'daddr' ],
	'both-addresses': [ 'saddr', 'daddr' ],
	'src-port': [ 'sport' ],
	'dst-port': [ 'dport' ],
	'both-ports': [ 'sport', 'dport' ],
	'src-address-and-port': [ 'saddr', 'sport' ],
	'dst-address-and-port': [ 'daddr', 'dport' ],
	'both-addresses-and-ports': [ 'saddr', 'daddr', 'sport', 'dport' ]
};

function masksOverlap(left, right) {
	for (let i = 0; i < 32; i++) {
		if (left % 2 == 1 && right % 2 == 1)
			return true;
		left = int(left / 2);
		right = int(right / 2);
	}
	return false;
};

export function validateResources(resources, occupied) {
	if (type(resources) != 'object')
		die('resources required');
	if (!isInteger(resources.markShift, 16, 24))
		die('mark shift must be between 16 and 24');
	if (!isInteger(resources.tableBase, 10000, 50000))
		die('table base outside supported range');
	if (!isInteger(resources.priorityBase, 20000, 30000))
		die('priority base outside supported range');
	if (type(occupied) != 'object' || occupied.complete !== true)
		die('complete resource inventory required');
	let markMask = 255 * int(pow(2, resources.markShift));
	for (let mask in occupied.markMasks ?? []) {
		if (!isInteger(mask, 0, 4294967295))
			die('invalid occupied mark mask');
		if (masksOverlap(markMask, mask))
			die('fwmark mask collision');
	}
	for (let tableId in occupied.tableIds ?? [])
		if (tableId >= resources.tableBase && tableId <= resources.tableBase + 254)
			die('routing table collision');
	for (let priority in occupied.priorities ?? [])
		if (priority >= resources.priorityBase && priority <= resources.priorityBase + 254)
			die('rule priority collision');
	return markMask;
};

export function compile(policy, members, resources, occupied) {
	if (type(policy) != 'object' || !exists(modes, policy.mode))
		die('unsupported PCC mode');
	let markMask = validateResources(resources, occupied);
	let seenNames = {}, seenIds = {}, allMembers = [], selected = [], bestPriority = null;
	if (type(members) != 'array' || length(members) < 1 || length(members) > 255)
		die('one to 255 members required');
	for (let index, member in members) {
		if (!identifier(member.name, 15))
			die('invalid member name');
		if (exists(seenNames, member.name))
			die('duplicate member name');
		if (!isInteger(member.id, 1, 255) || exists(seenIds, member.id))
			die('invalid or duplicate stable member id');
		if (!isInteger(member.weight, 1, 256))
			die('weight must be between 1 and 256');
		if (!isInteger(member.priority, 1, 65535))
			die('invalid member priority');
		if (member.online !== true && member.online !== false)
			die('member health must be explicit');
		seenNames[member.name] = true;
		seenIds[member.id] = true;
		push(allMembers, member);
		if (member.online) {
			push(selected, member);
			if (bestPriority === null || member.priority < bestPriority)
				bestPriority = member.priority;
		}
	}
	let bestMembers = [];
	for (let index, member in selected)
		if (member.priority == bestPriority)
			push(bestMembers, member);
	sort(bestMembers, function(l, r) { return l.id - r.id; });
	selected = bestMembers;
	if (!length(selected))
		die('no healthy members; no classification generated');
	let plan = { mode: policy.mode, markMask: markMask, totalWeight: 0, members: allMembers, buckets: [] };
	for (let index, member in selected) {
		let firstBucket = plan.totalWeight;
		plan.totalWeight += member.weight;
		push(plan.buckets, {
			name: member.name,
			firstBucket: firstBucket,
			lastBucket: plan.totalWeight - 1,
			mark: member.id * int(pow(2, resources.markShift)),
			tableId: resources.tableBase + member.id - 1,
			priority: resources.priorityBase + member.id - 1
		});
	}
	return plan;
};

export function hashExpression(mode, family, hasPorts) {
	if (!exists(modes, mode))
		die('unsupported PCC mode');
	if (family != 'ip' && family != 'ip6')
		die('invalid address family');
	let fields = [];
	for (let index, field in modes[mode]) {
		if (field == 'sport' || field == 'dport') {
			if (hasPorts)
				push(fields, 'th ' + field);
		}
		else {
			push(fields, family + ' ' + field);
		}
	}
	if (length(fields) == 0)
		fields = [ family + ' saddr', family + ' daddr' ];
	return join(' . ', fields);
};

export function renderClassification(plan, family, hasPorts) {
	if (plan.totalWeight <= 0)
		die('no healthy members; no classification generated');
	let expression = hashExpression(plan.mode, family, hasPorts);
	let rules = [];
	let guard = hasPorts ? 'meta l4proto { tcp, udp } ' : 'meta l4proto != { tcp, udp } ';
	let inverseMask = 4294967295 - plan.markMask;
	for (let index, bucket in plan.buckets)
		push(rules, sprintf(
			'meta nfproto %s %sct state new ct mark & 0x%08x == 0 meta mark == 0 jhash %s mod %d seed 0x52425244 %d-%d ct mark set (ct mark & 0x%08x) | 0x%08x',
			family == 'ip' ? 'ipv4' : 'ipv6', guard, plan.markMask, expression,
			plan.totalWeight, bucket.firstBucket, bucket.lastBucket, inverseMask, bucket.mark));
	return rules;
};
