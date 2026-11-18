'use strict';

import { isInteger, requireTable, identifier } from './util.uc';

const ROUTE_TABLE_MIN = 10000;
const ROUTE_TABLE_MAX = 65535;
const RULE_PRIORITY_MIN = 1;
const RULE_PRIORITY_MAX = 32767;
const ROUTE_PROTOCOL = 66;
const NFT_TABLE = 'netbraid';
const NFT_PRIORITY = 20000;

function requireObject(value, label) {
	if (type(value) != 'object')
		die(sprintf('%s must be an object', label));
	return value;
};

function requireList(value, label) {
	if (type(value) != 'array')
		die(sprintf('%s must be an array', label));
	return value;
};

export function inventory(input) {
	requireObject(input, 'routing inventory');
	let result = { complete: input.complete === true, markMasks: [], tableIds: [], priorities: [],
		warpMarks: [], tables: {}, rules: [], nftTables: [] };
	for (let value in (input.markMasks ?? []))
		push(result.markMasks, value);
	for (let value in (input.tableIds ?? []))
		push(result.tableIds, value);
	for (let value in (input.priorities ?? []))
		push(result.priorities, value);
	for (let value in (input.warpMarks ?? []))
		push(result.warpMarks, value);
	for (let value in (input.nftTables ?? []))
		push(result.nftTables, value);
	for (let key in (input.tables ?? {}))
		result.tables[key] = input.tables[key];
	result.rules = input.rules ?? [];
	return result;
};

export function validateInventory(occupied, plan) {
	requireObject(occupied, 'occupied resources');
	requireObject(plan, 'routing plan');
	if (occupied.complete !== true)
		die('occupied resource inventory is incomplete');
	let mask = int(plan.markMask);
	if (!isInteger(mask, 1, 4294967295))
		die('routing plan mark mask is invalid');
	for (let value in occupied.markMasks)
		if ((int(value) & mask) != 0)
			die('fwmark mask conflicts with an occupied mark');
	for (let route in plan.routes) {
		if (!isInteger(route.tableId, ROUTE_TABLE_MIN, ROUTE_TABLE_MAX))
			die('route table ID is outside the isolated range');
		if (index(occupied.tableIds, route.tableId) >= 0)
			die('route table ID is occupied');
		if (!isInteger(route.priority, RULE_PRIORITY_MIN, RULE_PRIORITY_MAX))
			die('rule priority is outside the isolated range');
		if (index(occupied.priorities, route.priority) >= 0)
			die('rule priority is occupied');
	}
	if (index(occupied.nftTables, NFT_TABLE) >= 0)
		die('nftables table name is occupied');
	for (let mark in occupied.warpMarks)
		if ((int(mark) & mask) == mask)
			die('WARP mark overlaps the NetBraid fwmark mask');
	return true;
};

function nftScript(plan) {
	let lines = [ 'table inet ' + NFT_TABLE + ' {' ];
	push(lines, '  chain classify {');
	push(lines, '    type filter hook prerouting priority ' + NFT_PRIORITY + '; policy accept;');
	for (let policy in plan.policies) {
		for (let rule in policy.classification)
			push(lines, '    ' + policy.selector + rule);
	}
	push(lines, '  }');
	push(lines, '}');
	return join('\n', lines) + '\n';
};

function rollbackScript(plan) {
	let lines = [];
	for (let route in plan.routes) {
		let ip = route.family == 'ip6' ? 'ip -6' : 'ip -4';
		push(lines, sprintf('%s rule del priority %d fwmark %s lookup %d',
			ip, route.priority, route.fwmark, route.tableId));
	}
	push(lines, 'nft delete table inet ' + NFT_TABLE);
	return lines;
};

function addRouteCommands(plan) {
	let commands = [];
	for (let route in plan.routes) {
		let ip = route.family == 'ip6' ? 'ip -6' : 'ip -4';
		push(commands, sprintf('%s route add default dev %s table %d proto %d',
			ip, route.interface, route.tableId, ROUTE_PROTOCOL));
		push(commands, sprintf('%s rule add priority %d fwmark %s lookup %d',
			ip, route.priority, route.fwmark, route.tableId));
	}
	return commands;
};

function removeRouteCommands(plan) {
	let commands = [];
	for (let route in plan.routes) {
		let ip = route.family == 'ip6' ? 'ip -6' : 'ip -4';
		push(commands, sprintf('%s rule del priority %d fwmark %s lookup %d',
			ip, route.priority, route.fwmark, route.tableId));
		push(commands, sprintf('%s route del default dev %s table %d proto %d',
			ip, route.interface, route.tableId, ROUTE_PROTOCOL));
	}
	return commands;
};

export function buildTransaction(plan, occupied) {
	requireObject(plan, 'routing plan');
	if (!identifier(NFT_TABLE, 32))
		die('nft table name is invalid');
	validateInventory(occupied, plan);
	let apply = [];
	push(apply, { command: 'nft', args: [ '-f', '-' ], input: nftScript(plan) });
	for (let command in addRouteCommands(plan))
		push(apply, { command: 'sh', args: [ '-c', command ], input: null });
	let rollback = [];
	for (let command in removeRouteCommands(plan))
		push(rollback, { command: 'sh', args: [ '-c', command ], input: null });
	push(rollback, { command: 'nft', args: [ 'delete', 'table', 'inet', NFT_TABLE ], input: null });
	return { table: NFT_TABLE, markMask: plan.markMask, apply: apply, rollback: rollback,
		generatedAt: plan.generatedAt ?? 0 };
};

export function renderTransaction(transaction) {
	requireObject(transaction, 'transaction');
	let lines = [];
	for (let step in transaction.apply)
		push(lines, sprintf('APPLY %s %s%s', step.command, join(' ', step.args),
			step.input !== null ? '\n' + step.input : ''));
	for (let step in transaction.rollback)
		push(lines, sprintf('ROLLBACK %s %s', step.command, join(' ', step.args)));
	return join('\n', lines);
};
