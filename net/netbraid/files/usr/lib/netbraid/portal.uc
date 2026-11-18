'use strict';

import { keys } from './util.uc';

export function createPortal(config) {
	return {
		config: config ?? { enabled: false, sessionTimeout: 3600 },
		sessions: {},
		allowlist: {},
		active: false,
		lastError: null
	};
};

function validMac(mac) {
	return type(mac) == 'string' && match(mac, /^[A-Fa-f0-9]{2}(:[A-Fa-f0-9]{2}){5}$/) != null;
};

function escapeHtml(value) {
	if (type(value) != 'string')
		die('landing content must be a string');
	return replace(replace(replace(replace(replace(value, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), "'", '&#39;');
};

export function allow(state, mac) {
	if (!validMac(mac))
		die('mac must be a valid hardware address');
	state.allowlist[mac] = true;
	return true;
};

export function authorize(state, mac, now) {
	if (!validMac(mac))
		die('mac must be a valid hardware address');
	if (!state.config.enabled) {
		state.lastError = 'portal_disabled';
		return null;
	}
	let sessionTimeout = state.config.sessionTimeout ?? 3600;
	if (type(now) != 'int' || now < 0 || type(sessionTimeout) != 'int'
		|| sessionTimeout < 60 || sessionTimeout > 86400)
		die('invalid portal session time');
	if (!exists(state.sessions, mac) && length(keys(state.sessions)) >= 256) {
		state.lastError = 'session_limit';
		return null;
	}
	state.sessions[mac] = {
		startedAt: now,
		expiresAt: now + sessionTimeout
	};
	return state.sessions[mac];
};

export function revoke(state, mac) {
	delete state.sessions[mac];
	return true;
};

export function expire(state, now) {
	if (type(now) != 'int' || now < 0)
		die('invalid portal expiry time');
	for (let mac in keys(state.sessions))
		if (state.sessions[mac].expiresAt <= now)
			delete state.sessions[mac];
	return state.sessions;
};

export function renderLanding(state) {
	let title = escapeHtml(state.config.title ?? 'NetBraid Guest Access');
	let terms = escapeHtml(state.config.terms ?? 'Use of this network is subject to local policy.');
	return sprintf('<!doctype html><html><head><meta charset="utf-8"><title>%s</title></head><body><h1>%s</h1><p>%s</p></body></html>', title, title, terms);
};

export function status(state, now) {
	expire(state, now);
	return {
		enabled: state.config.enabled === true,
		active: state.active,
		sessions: length(keys(state.sessions)),
		allowlisted: length(keys(state.allowlist)),
		lastError: state.lastError
	};
};
