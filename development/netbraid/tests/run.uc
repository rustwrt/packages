'use strict';

import * as util from '../../../net/netbraid/files/usr/lib/netbraid/util.uc';
import * as config from '../../../net/netbraid/files/usr/lib/netbraid/config.uc';
import * as discovery from '../../../net/netbraid/files/usr/lib/netbraid/discovery.uc';
import * as health from '../../../net/netbraid/files/usr/lib/netbraid/health.uc';
import * as planner from '../../../net/netbraid/files/usr/lib/netbraid/planner.uc';
import * as allocator from '../../../net/netbraid/files/usr/lib/netbraid/allocator.uc';

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

let equalLeft = [ 1, { name: 'wan' }, [ true, 'x' ] ];
let equalRight = [ 1, { name: 'wan' }, [ true, 'x' ] ];
assert(util.deepEqual(equalLeft, equalRight), 'deepEqual matches nested arrays');
equalRight[2][1] = 'y';
assert(!util.deepEqual(equalLeft, equalRight), 'deepEqual detects nested array mismatch');
assert(!util.deepEqual([ 1 ], [ 1, 2 ]), 'deepEqual detects array length mismatch');
assert(util.deepEqual({ a: 1 }, { a: 1 }), 'deepEqual matches objects');
assert(util.isInteger(2.5, 0, 5) == false, 'integer validation rejects fractions');
assert(util.isFiniteNumber(1e309) == false, 'finite validation rejects infinity');

let document = [
	{ '.type': 'main', '.name': 'main', enabled: '1' },
	{ '.type': 'member', '.name': 'wan', interface: 'wan', weight: '2' },
	{ '.type': 'policy', '.name': 'balanced', mode: 'both-addresses-and-ports', member: 'wan' }
];
let model = config.parse(document);
assert(model.policies[0].mode == 'both-addresses-and-ports', 'config accepts valid policy mode');
assert(config.validate({
	main: { enabled: true, markShift: 16, tableBase: 10000, priorityBase: 20000, healthEnabled: true, detectorEnabled: false, portalEnabled: false },
	health: {}, members: model.members, policies: model.policies
}) != null, 'config validator accepts valid mode');
assert(model.members[0].weight == 2, 'config parses integer member weight');
rejects(function() { config.parse([ document[0], document[1], { '.type': 'policy', '.name': 'bad', mode: 'not-a-mode', member: 'wan' } ]); }, 'config rejects unknown policy mode');
rejects(function() { config.parse([ document[0], { '.type': 'member', '.name': 'wan', interface: 'wan', weight: '2.8' } ]); }, 'config rejects truncated numeric input');

let cyclic = discovery.normalize({ interface: [
	{ interface: 'a', device: '@b' },
	{ interface: 'b', dependencies: [ 'c' ] },
	{ interface: 'c', dependencies: [ 'a' ] },
	{ interface: 'self', dependencies: [ 'self' ] }
] });
assert(length(cyclic.cycles) == 2, 'discovery reports both dependency cycles');
assert(join(',', cyclic.cycles[0]) == 'a,b,c,a', 'discovery reports cycle path starting at index zero');
assert(join(',', cyclic.cycles[1]) == 'self,self', 'discovery reports self-cycle');
rejects(function() { discovery.normalize({ interface: [ { interface: 'wan', route: [ { target: '::', mask: 128.9 } ] } ] }); }, 'discovery rejects fractional route masks');
rejects(function() { discovery.normalize({ interface: [ { interface: 'wan', route: [ { target: '::', metric: 3.5 } ] } ] }); }, 'discovery rejects fractional metrics');

let healthConfig = { targets: [ 'one' ], recoveryThreshold: 1 };
let healthState = health.newState(healthConfig, 0);
healthState = health.step(healthState, [ { target: 'one', success: true } ], 1);
assert(healthState.status == 'Online', 'health transitions to online after recovery');
rejects(function() { health.newState(healthConfig, 1e309); }, 'health rejects infinite timestamps');

let resources = { markShift: 16, tableBase: 10000, priorityBase: 20000 };
let occupied = { complete: true, markMasks: [ 65535 ], tableIds: [], priorities: [] };
let allocatorOccupied = { complete: true, markMasks: [ 65535 ], tableIds: [], priorities: [] };
let plan = planner.compile({ mode: 'src-address' }, [
	{ name: 'wan', id: 7, weight: 2, priority: 1, online: true }
], resources, occupied);
assert(plan.buckets[0].mark == 458752, 'planner preserves stable member ID in mark');
assert(plan.buckets[0].tableId == 10006, 'planner maps stable member ID to routing table');
rejects(function() { planner.compile({ mode: 'src-address' }, [
	{ name: 'wan', id: 7, weight: 1, priority: 1, online: true },
	{ name: 'lan', id: 7, weight: 1, priority: 1, online: true }
], resources, occupied); }, 'planner rejects duplicate stable IDs');
let reducedPlan = planner.compile({ mode: 'src-address' }, [
	{ name: 'first', id: 1, weight: 1, priority: 1, online: false },
	{ name: 'second', id: 2, weight: 1, priority: 1, online: true }
], resources, occupied);
assert(reducedPlan.buckets[0].mark == 131072, 'planner preserves member IDs when other members go offline');
rejects(function() { planner.validateResources(resources, { complete: false }); }, 'planner rejects incomplete resource inventory');
rejects(function() { planner.validateResources(resources, { complete: true, markMasks: [ 4294967295 ] }); }, 'planner rejects overlapping fwmark mask');
rejects(function() { planner.validateResources(resources, { complete: true, tableIds: [ 10005 ] }); }, 'planner rejects routing table collision');
rejects(function() { planner.validateResources(resources, { complete: true, priorities: [ 20005 ] }); }, 'planner rejects rule priority collision');

assert(allocator.masksOverlap(0x10000, 0x10000), 'allocator detects overlapping masks');
assert(!allocator.masksOverlap(0x10000, 0x20000), 'allocator detects disjoint masks');
let allocation = allocator.build(resources, [
	{ name: 'wan', weight: 1, priority: 1 },
	{ name: 'lan', weight: 1, priority: 1 }
], allocatorOccupied);
assert(allocation.assignments[0].name == 'lan' && allocation.assignments[0].id == 0, 'allocator deterministically sorts and assigns zero-based IDs');
assert(allocation.assignments[1].name == 'wan' && allocation.assignments[1].id == 1, 'allocator assigns stable IDs independent of input order');
rejects(function() { allocator.assignIds([ { name: 'wan' }, { name: 'wan' } ]); }, 'allocator rejects duplicate member names');

let ruleDocument = [
	document[0],
	{ '.type': 'member', '.name': 'wan', interface: 'wan', weight: '2' },
	{ '.type': 'policy', '.name': 'balanced', mode: 'src-address', member: 'wan' },
	{ '.type': 'rule', '.name': 'guest', policy: 'balanced', priority: '20', family: 'ip', source: '192.0.2.0/24' }
];
let ruleModel = config.parse(ruleDocument);
assert(length(ruleModel.rules) == 1 && ruleModel.rules[0].priority == 20, 'config parses and validates rule sections');
rejects(function() { config.parse([ ruleDocument[0], ruleDocument[1], ruleDocument[2],
	{ '.type': 'rule', '.name': 'bad', policy: 'missing', priority: '20' } ]); }, 'config rejects rule with unknown policy');

print('PASS ucode core regression tests');
