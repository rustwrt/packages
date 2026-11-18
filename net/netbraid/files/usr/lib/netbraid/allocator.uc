'use strict';

import { pow } from 'math';
import { requireArray, requireTable, requireInteger, identifier } from './util.uc';
import { validateResources } from './planner.uc';

export function masksOverlap(left, right) {
	for (let i = 0; i < 32; i++) {
		if (left % 2 == 1 && right % 2 == 1)
			return true;
		left = int(left / 2);
		right = int(right / 2);
	}
	return false;
};

export function assignIds(members) {
	requireArray(members, 'members');
	let ordered = [], names = {};
	for (let member in members) {
		requireTable(member, 'member');
		if (!identifier(member.name, 15) || exists(names, member.name))
			die('member name must be valid and unique');
		names[member.name] = true;
		push(ordered, { ...member });
	}
	sort(ordered, function(left, right) { return left.name < right.name ? -1 : (left.name > right.name ? 1 : 0); });
	if (length(ordered) > 254)
		die('at most 254 members are supported');
	for (let index = 0; index < length(ordered); index++)
		ordered[index].id = index;
	return ordered;
};

export function markMask(main) {
	return 255 * int(pow(2, main.markShift));
};

export function build(main, members, occupied) {
	requireTable(occupied, 'occupied inventory');
	let reservedMask = validateResources(main, occupied);
	let tableIds = {}, priorities = {};
	for (let value in occupied.tableIds ?? [])
		tableIds[value] = true;
	for (let value in occupied.priorities ?? [])
		priorities[value] = true;
	let assignments = [];
	for (let member in assignIds(members)) {
		requireInteger(member.weight, 1, 256, 'member weight');
		requireInteger(member.priority, 1, 65535, 'member priority');
		let tableId = main.tableBase + member.id - 1;
		let priority = main.priorityBase + member.id - 1;
		let memberMark = member.id * int(pow(2, main.markShift));
		if (exists(tableIds, tableId))
			die('routing table collision for member ' + member.name);
		if (exists(priorities, priority))
			die('rule priority collision for member ' + member.name);
		push(assignments, {
			name: member.name,
			id: member.id,
			mark: memberMark,
			tableId: tableId,
			priority: priority,
			weight: member.weight,
			memberPriority: member.priority
		});
	}
	return { markMask: reservedMask, markShift: main.markShift, assignments: assignments };
};
