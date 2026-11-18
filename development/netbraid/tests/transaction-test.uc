'use strict';

import * as config from '../../../net/netbraid/files/usr/lib/netbraid/config.uc';
import * as routing from '../../../net/netbraid/files/usr/lib/netbraid/routing.uc';
import * as transaction from '../../../net/netbraid/files/usr/lib/netbraid/transaction.uc';

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
	{ '.type': 'member', '.name': 'wan', interface: 'wan', weight: '1', priority: '1' },
	{ '.type': 'member', '.name': 'lte', interface: 'wwan0', weight: '1', priority: '2' },
	{ '.type': 'policy', '.name': 'balanced', mode: 'src-address', member: [ 'wan', 'lte' ] },
	{ '.type': 'rule', '.name': 'lan', policy: 'balanced', priority: '20', family: 'ip', source: '192.0.2.0/24', protocol: 'tcp', destination_port: '443' }
];
let model = config.parse(document);
model.detector.syn = true;
model.detector.ttl = true;
let plan = routing.buildPlan(model, { complete: true, markMasks: [], tableIds: [], priorities: [], warpMarks: [], nftTables: [] }, { wan: true, lte: true }, 100);
let occupied = transaction.inventory({ complete: true, markMasks: [ 0x00ff0000 ], tableIds: [ 10010 ], priorities: [ 20010 ], warpMarks: [ 65536 ], nftTables: [ 'user-table' ] });
rejects(function() { transaction.buildTransaction(plan, occupied); }, 'overlapping WARP mark prevents transaction');
let clean = transaction.inventory({ complete: true, markMasks: [ 65535 ], tableIds: [], priorities: [], warpMarks: [ 0x20000 ], nftTables: [ 'user-table' ] });
let built = transaction.buildTransaction(plan, clean);
assert(built.table == 'netbraid' && length(built.apply) >= 3 && length(built.rollback) >= 3,
	'apply and rollback transaction steps are generated');
let script = transaction.renderTransaction(built);
assert(index(script, 'APPLY nft -f -') >= 0 && index(script, 'table inet netbraid') >= 0,
	'transaction renders atomic nft script');
assert(index(script, 'ip -4 route add default dev wan table 10000 proto 66') >= 0,
	'transaction renders isolated route installation');
assert(index(script, 'ROLLBACK nft delete table inet netbraid') >= 0,
	'rollback removes the owned nft table');
assert(index(join('\n', plan.detectionRules), 'nb_ttl4') >= 0
	&& index(join('\n', plan.detectionRules), 'nb_syn') >= 0,
	'kernel-side detection sets are owned by the routing plan');
rejects(function() { transaction.validateInventory(transaction.inventory({ complete: false }), plan); },
	'incomplete inventory prevents transaction');
rejects(function() { transaction.validateInventory(transaction.inventory({ complete: true, tableIds: [ 10000 ] }), plan); },
	'occupied table prevents transaction');

print('PASS ucode routing transaction tests');
