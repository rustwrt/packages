'use strict';

import { isInteger } from './util.uc';

function requireTable(value, label) {
	if (type(value) != 'object')
		die(sprintf('%s must be an object', label));
	return value;
};

function requireArray(value, label) {
	if (type(value) != 'array')
		die(sprintf('%s must be an array', label));
	return value;
};

function requireString(value, label) {
	if (type(value) != 'string' || value === '')
		die(sprintf('%s must be a nonempty string', label));
	return value;
};

function readMask(value, maximum, label) {
	if (type(value) == 'string' && match(value, /^[0-9]+$/))
		value = +value;
	let mask = value;
	if (!isInteger(mask, 0, maximum))
		die(sprintf('%s is invalid', label));
	return mask;
};

function normalizeAddresses(rawInterface) {
	let addresses = [];
	const groups = [ [ 'ipv4-address', 4, 32 ], [ 'ipv6-address', 6, 128 ] ];
	for (let group in groups) {
		let key = group[0];
		for (let rawAddress in requireArray(rawInterface[key] ?? [], key)) {
			requireTable(rawAddress, 'address');
			push(addresses, {
				address: requireString(rawAddress.address, 'address.address'),
				mask: readMask(rawAddress.mask, group[2], 'address.mask'),
				family: group[1]
			});
		}
	}
	for (let assignment in requireArray(rawInterface['ipv6-prefix-assignment'] ?? [], 'ipv6-prefix-assignment')) {
		requireTable(assignment, 'prefix assignment');
		let localAddress = assignment['local-address'];
		if (localAddress !== null) {
			requireTable(localAddress, 'local-address');
			push(addresses, {
				address: requireString(localAddress.address, 'local-address.address'),
				mask: readMask(localAddress.mask, 128, 'local-address.mask'),
				family: 6
			});
		}
	}
	return addresses;
};

function normalizeRoutes(rawInterface) {
	let routes = [];
	for (let rawRoute in requireArray(rawInterface.route ?? [], 'route')) {
		requireTable(rawRoute, 'route entry');
		let target = requireString(rawRoute.target, 'route.target');
		let family = index(target, ':') >= 0 ? 6 : 4;
		let mask = readMask(rawRoute.mask, family == 6 ? 128 : 32, 'route.mask');
		let metric = rawRoute.metric ?? 0;
		if (type(metric) == 'string' && match(metric, /^[0-9]+$/))
			metric = +metric;
		if (!isInteger(metric, 0, 4294967295))
			die('route.metric is invalid');
		if (rawRoute.nexthop !== null)
			requireString(rawRoute.nexthop, 'route.nexthop');
		if (rawRoute.source !== null)
			requireString(rawRoute.source, 'route.source');
		if (rawRoute.table !== null && type(rawRoute.table) != 'string' && type(rawRoute.table) != 'int')
			die('route.table must be a string or number');
		push(routes, {
			target: target,
			family: family,
			mask: mask,
			gateway: rawRoute.nexthop,
			metric: metric,
			table: rawRoute.table,
			source: rawRoute.source,
			defaultRoute: mask == 0 && (target == '0.0.0.0' || target == '::' || target == '0:0:0:0:0:0:0:0')
		});
	}
	return routes;
};

function normalizeDependencies(rawInterface) {
	let dependencies = [], seen = {};
	function addDependency(name) {
		requireString(name, 'dependency');
		if (substr(name, 0, 1) == '@')
			name = substr(name, 1);
		requireString(name, 'dependency');
		if (!exists(seen, name)) {
			push(dependencies, name);
			seen[name] = true;
		}
	}
	for (let name in requireArray(rawInterface.dependencies ?? [], 'dependencies'))
		addDependency(name);
	for (let key in [ 'device', 'l3_device' ]) {
		let device = rawInterface[key];
		if (type(device) == 'string' && substr(device, 0, 1) == '@')
			addDependency(device);
	}
	return sort(dependencies);
};

function detectCycles(interfaces, byName) {
	let cycles = [], visited = {}, active = {}, stack = [];
	function visit(name) {
		if (exists(active, name)) {
			let cycle = [];
			for (let index = active[name]; index < length(stack); index++)
				push(cycle, stack[index]);
			push(cycle, name);
			push(cycles, cycle);
			return;
		}
		if (visited[name] || !exists(byName, name))
			return;
		active[name] = length(stack);
		push(stack, name);
		for (let dependency in byName[name].dependencies)
			visit(dependency);
		pop(stack);
		delete active[name];
		visited[name] = true;
	}
	for (let iface in interfaces)
		visit(iface.name);
	return cycles;
};

export function normalize(ubusDump) {
	requireTable(ubusDump, 'ubusDump');
	let rawInterfaces = requireArray(ubusDump.interface, 'ubusDump.interface');
	let interfaces = [], candidates = [], byName = {};
	for (let rawInterface in rawInterfaces) {
		requireTable(rawInterface, 'interface entry');
		let name = requireString(rawInterface.interface, 'interface.interface');
		if (exists(byName, name))
			die(sprintf('duplicate interface: %s', name));
		if (rawInterface.up !== null && rawInterface.up !== true && rawInterface.up !== false)
			die('interface.up must be boolean');
		let device = rawInterface.l3_device ?? rawInterface.device;
		if (device !== null)
			requireString(device, 'interface.device');
		let iface = {
			name: name,
			device: device,
			up: rawInterface.up === true,
			addresses: normalizeAddresses(rawInterface),
			routes: normalizeRoutes(rawInterface),
			dependencies: normalizeDependencies(rawInterface),
			defaultRouteCandidate: false
		};
		for (let route in iface.routes)
			if (iface.up && route.defaultRoute)
				iface.defaultRouteCandidate = true;
		push(interfaces, iface);
		byName[name] = iface;
	}
	sort(interfaces, function(l, r) { return l.name < r.name ? -1 : (l.name > r.name ? 1 : 0); });
	for (let iface in interfaces)
		if (iface.defaultRouteCandidate)
			push(candidates, iface);
	return { interfaces: interfaces, candidates: candidates, cycles: detectCycles(interfaces, byName) };
};
