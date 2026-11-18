'use strict';

import { cursor } from 'uci';
import { connect } from 'ubus';
import * as fs from 'fs';
import { isInteger } from './util.uc';
import { parse } from './config.uc';
import { normalize } from './discovery.uc';
import { sample as sampleDetection } from './detection.uc';

const BLOCK_REASON = 'Routing activation requires a live resource inventory, verified apply and rollback execution, and a monitored rollback path; planner transactions are not applied by this build.';
const STATUS_PATH = '/var/run/netbraid/status.json';

function snakeKey(key) {
	let result = '';
	for (let i = 0; i < length(key); i++) {
		let character = substr(key, i, 1);
		if (character >= 'A' && character <= 'Z')
			result = result + '_' + lc(character);
		else
			result = result + character;
	}
	return result;
};

function camelKey(key) {
	let result = '';
	let upper = false;
	for (let i = 0; i < length(key); i++) {
		let character = substr(key, i, 1);
		if (character == '_') {
			upper = true;
			continue;
		}
		result = result + (upper ? uc(character) : character);
		upper = false;
	}
	return result;
};

function transformKeys(value, incoming) {
	if (type(value) == 'array')
		return map(value, function(entry) { return transformKeys(entry, incoming); });
	if (type(value) != 'object')
		return value;
	let result = {};
	for (let key, entry in value) {
		let converted = incoming ? camelKey(key) : snakeKey(key);
		result[converted] = transformKeys(entry, incoming);
	}
	return result;
};

export function toWire(value) {
	return transformKeys(value, false);
};

export function loadConfig(confDir) {
	confDir = confDir ?? '/etc/config';
	if (type(confDir) != 'string' || substr(confDir, 0, 1) != '/')
		die('config directory must be an absolute path');
	let configCursor = cursor(confDir);
	if (!configCursor || !configCursor.load('netbraid'))
		die('unable to load netbraid UCI configuration');
	let sections = [];
	configCursor.foreach('netbraid', null, function(section) { push(sections, section); });
	if (!length(sections))
		die('netbraid UCI configuration is empty');
	return parse(sections);
};

export function validation(confDir) {
	try {
		let model = loadConfig(confDir);
		return { valid: true, errors: [], activationAllowed: false, reason: BLOCK_REASON, enabled: model.main.enabled };
	}
	catch (error) {
		return { valid: false, errors: [ '' + error ], activationAllowed: false, reason: BLOCK_REASON };
	}
};

export function discover() {
	let bus = connect(null, 1500);
	if (!bus)
		die('ubus connection unavailable');
	let dump = bus.call('network.interface', 'dump', {});
	bus.disconnect();
	if (type(dump) != 'object')
		die('network.interface dump unavailable');
	return normalize(dump);
};

export function portalStatus(model) {
	return {
		enabled: model.main.portalEnabled && model.portal.enabled,
		active: false, sessions: 0, enforcementAvailable: false,
		reason: 'Portal interception and authorization enforcement are unavailable; no redirects or access rules are installed.'
	};
};

export function readDaemon(statusPath) {
	let text = fs.readfile(statusPath ?? STATUS_PATH, 524288);
	if (text === null)
		return { running: false, reason: 'No daemon snapshot is available.' };
	try {
		let snapshot = transformKeys(json(text), true);
		if (type(snapshot) != 'object' || !isInteger(snapshot.updatedAt, 0, null))
			die('invalid snapshot');
		let age = time() - snapshot.updatedAt;
		let processName = isInteger(snapshot.pid, 1, null)
			? fs.readfile(sprintf('/proc/%d/comm', snapshot.pid)) : null;
		snapshot.running = age >= 0 && age <= 90 && trim(processName ?? '') == 'ucode';
		snapshot.stale = age < 0 || age > 90;
		return snapshot;
	}
	catch (error) {
		return { running: false, reason: 'Invalid daemon snapshot: ' + error };
	}
};

export function collect(confDir, previous, detectionOptions) {
	let now = time();
	let processStatus = fs.readfile('/proc/self/stat');
	let processId = processStatus ? int(split(processStatus, ' ')[0]) : 0;
	let snapshot = { pid: processId, startedAt: previous?.startedAt ?? now, updatedAt: now, running: true, routingApplied: false, activationBlocked: true };
	try {
		let model = loadConfig(confDir);
		snapshot.configValid = true;
		snapshot.enabled = model.main.enabled;
		snapshot.detection = sampleDetection({ model: model, options: detectionOptions ?? {},
			state: previous?.detectionState ?? null });
		snapshot.portal = portalStatus(model);
		try { snapshot.discovery = discover(); }
		catch (error) { snapshot.discovery = { interfaces: [], candidates: [], cycles: [], error: '' + error }; }
		snapshot.health = { available: false, reason: 'Internet health probes are unavailable until they can be pinned to validated routing resources.' };
	}
	catch (error) {
		snapshot.configValid = false;
		snapshot.error = '' + error;
	}
	return snapshot;
};

export function writeSnapshot(snapshot, statusPath) {
	statusPath = statusPath ?? STATUS_PATH;
	let parts = split(statusPath, '/');
	let directory = '';
	for (let i = 1; i < length(parts) - 1; i++)
		directory = directory + '/' + parts[i];
	if (directory != '' && !fs.stat(directory) && !fs.mkdir(directory))
		die('status directory is unavailable: ' + directory);
	let temporaryPath = statusPath + '.tmp';
	let file = fs.open(temporaryPath, 'w', 0600);
	if (!file)
		die('unable to open temporary daemon snapshot');
	let text = sprintf('%J\n', toWire(snapshot));
	let written = file.write(text);
	file.close();
	if (written != length(text) || !fs.rename(temporaryPath, statusPath)) {
		fs.unlink(temporaryPath);
		die('unable to publish daemon snapshot');
	}
};

export function query(method, confDir, statusPath) {
	if (method == 'validate')
		return validation(confDir);
	if (method == 'interfaces' || method == 'discover') {
		try { return discover(); }
		catch (error) { return { interfaces: [], candidates: [], cycles: [], error: '' + error }; }
	}
	let daemon = readDaemon(statusPath);
	let check = validation(confDir);
	if (method == 'status')
		return { enabled: check.enabled ?? false, running: daemon.running, configValid: check.valid, routingApplied: false, activationBlocked: true, reason: BLOCK_REASON, daemon: daemon };
	if (method == 'diagnostics')
		return {
			config: check, daemon: daemon, discovery: query('interfaces', confDir, statusPath),
			limitations: [ BLOCK_REASON, 'No routing, firewall, conntrack or portal changes are performed.', 'Interface up/default route is not a successful Internet health probe.' ]
		};
	if (!check.valid)
		return { error: 'Invalid configuration', errors: check.errors };
	let model = loadConfig(confDir);
	if (method == 'detection')
		return sampleDetection({ model: model, options: {}, state: null });
	if (method == 'portal')
		return portalStatus(model);
	if (method == 'plan')
		return { available: false, reason: BLOCK_REASON };
	die('unsupported method: ' + method);
};

export function cli(args) {
	let confDir = '/etc/config', method = null;
	for (let i = 0; i < length(args); i++) {
		if (args[i] == '--config-dir') {
			confDir = args[++i];
			if (type(confDir) != 'string' || substr(confDir, 0, 1) != '/')
				die('--config-dir requires an absolute directory');
		}
		else if (method === null)
			method = args[i];
		else
			die('unexpected argument: ' + args[i]);
	}
	if (method === null || method == 'help' || method == '--help') {
		print('Usage: netbraid [--config-dir /etc/config] validate|discover|interfaces|status|diagnostics|detection|portal\n');
		return 0;
	}
	if (method == 'apply' || method == 'activate') {
		printf('%J\n', toWire({ error: 'ACTIVATION_BLOCKED', routingApplied: false, reason: BLOCK_REASON }));
		return 2;
	}
	let result = query(method, confDir);
	printf('%J\n', toWire(result));
	return result.error || result.valid === false ? 1 : 0;
};
