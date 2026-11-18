'use strict';

import { isFiniteNumber, isInteger } from './util.uc';

function requireTime(now) {
	if (!isFiniteNumber(now) || now < 0)
		die('time must be a finite nonnegative number');
};

function withDefault(value, fallback) {
	if (value === null)
		return fallback;
	return value;
};

function requireInteger(value, minimum, label) {
	if (!isInteger(value, minimum, null))
		die(sprintf('%s must be an integer >= %s', label, minimum));
	return value;
};

export function validate(config) {
	if (type(config) != 'object')
		die('config must be a table');
	if (type(config.targets) != 'array' || length(config.targets) == 0)
		die('targets must be a nonempty array');
	let targets = [], seen = {};
	for (let index = 0; index < length(config.targets); index++) {
		let target = config.targets[index];
		if (type(target) != 'string' || target === '')
			die('target must be a nonempty string');
		if (exists(seen, target))
			die(sprintf('duplicate target: %s', target));
		seen[target] = true;
		push(targets, target);
	}
	let minimumTargets = requireInteger(withDefault(config.minimumTargets, length(targets)), 1, 'minimumTargets');
	if (minimumTargets > length(targets))
		die('minimumTargets exceeds target count');
	let recoveryDelay = withDefault(config.recoveryDelay, 0);
	requireTime(recoveryDelay);
	if (config.enabled !== null && config.enabled !== true && config.enabled !== false)
		die('enabled must be boolean');
	return {
		targets: targets,
		minimumTargets: minimumTargets,
		failureThreshold: requireInteger(withDefault(config.failureThreshold, 3), 1, 'failureThreshold'),
		recoveryThreshold: requireInteger(withDefault(config.recoveryThreshold, 2), 1, 'recoveryThreshold'),
		recoveryDelay: recoveryDelay,
		enabled: config.enabled !== false
	};
};

export function newState(config, now) {
	requireTime(now);
	let validatedConfig = validate(config);
	return {
		config: validatedConfig,
		status: validatedConfig.enabled ? 'Offline' : 'Disabled',
		enabled: validatedConfig.enabled,
		failureCount: 0,
		recoveryCount: 0,
		workingTargets: 0,
		updatedAt: now,
		changedAt: now
	};
};

function countWorkingTargets(config, probeResults) {
	if (type(probeResults) != 'array')
		die('probeResults must be an array');
	let configuredTargets = {}, seen = {}, workingTargets = 0;
	for (let target in config.targets)
		configuredTargets[target] = true;
	for (let result in probeResults) {
		if (type(result) != 'object')
			die('probe result must be a table');
		if (type(result.target) != 'string' || !exists(configuredTargets, result.target))
			die('probe target is not configured');
		if (exists(seen, result.target))
			die('duplicate probe target: ' + result.target);
		if (result.success !== true && result.success !== false)
			die('probe success must be boolean');
		seen[result.target] = true;
		if (result.success)
			workingTargets++;
	}
	return workingTargets;
};

export function step(state, probeResults, now, enabled) {
	if (type(state) != 'object')
		die('state must be a table');
	requireTime(now);
	if (now < state.updatedAt)
		die('time must not move backwards');
	if (enabled !== null && enabled !== true && enabled !== false)
		die('enabled must be boolean');
	let nextState = newState(state.config, now);
	nextState.enabled = withDefault(enabled, state.enabled);
	nextState.changedAt = state.changedAt;
	if (!nextState.enabled) {
		nextState.status = 'Disabled';
	}
	else {
		if (!(now > state.updatedAt || state.status == 'Disabled'))
			die('probe rounds require increasing time');
		let config = nextState.config;
		let workingTargets = countWorkingTargets(config, probeResults ?? []);
		let wasAvailable = state.status == 'Online' || state.status == 'Degraded';
		nextState.workingTargets = workingTargets;
		if (workingTargets >= config.minimumTargets) {
			nextState.failureCount = 0;
			if (wasAvailable) {
				nextState.status = workingTargets == length(config.targets) ? 'Online' : 'Degraded';
			}
			else {
				nextState.recoveryCount = min(state.status == 'Recovering' ? state.recoveryCount + 1 : 1, config.recoveryThreshold);
				nextState.recoveryStartedAt = state.status == 'Recovering' ? state.recoveryStartedAt : now;
				if (nextState.recoveryCount >= config.recoveryThreshold && now - nextState.recoveryStartedAt >= config.recoveryDelay) {
					nextState.status = workingTargets == length(config.targets) ? 'Online' : 'Degraded';
					nextState.recoveryStartedAt = null;
				}
				else {
					nextState.status = 'Recovering';
				}
			}
		}
		else {
			nextState.failureCount = min(state.failureCount + 1, config.failureThreshold);
			nextState.status = wasAvailable && nextState.failureCount < config.failureThreshold ? 'Degraded' : 'Offline';
		}
	}
	if (nextState.status !== state.status)
		nextState.changedAt = now;
	return nextState;
};
