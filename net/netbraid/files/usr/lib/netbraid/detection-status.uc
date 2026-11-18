'use strict';

import { cursor } from 'uci';
import { query, toWire } from './runtime.uc';

export function detectionConfig(confDir) {
	confDir = confDir ?? '/etc/config';
	if (type(confDir) != 'string' || substr(confDir, 0, 1) != '/')
		die('config directory must be an absolute path');
	let configCursor = cursor(confDir);
	if (!configCursor || !configCursor.load('netbraid'))
		die('unable to load netbraid UCI configuration');
	let sections = [];
	configCursor.foreach('netbraid', null, function(section) { push(sections, section); });
	let result = { enabled: false, interval: 30, retention: 900, whitelist: [] };
	for (let section in sections) {
		if (section['.type'] != 'detector')
			continue;
		result.enabled = section.enabled === '1' || section.enabled === true;
		result.interval = section.interval ?? 30;
		result.retention = section.retention ?? 900;
		result.mode = section.mode ?? 'auto';
		result.ttl = section.ttl !== '0' && section.ttl !== false;
		result.dhcp = section.dhcp !== '0' && section.dhcp !== false;
		result.conntrack = section.conntrack !== '0' && section.conntrack !== false;
		result.neighbor = section.neighbor !== '0' && section.neighbor !== false;
		result.syn = section.syn === '1' || section.syn === true;
		result.wifi = section.wifi !== '0' && section.wifi !== false;
		let list = section.whitelist ?? [];
		if (type(list) != 'array')
			list = [ list ];
		result.whitelist = list;
	}
	return result;
};

export function detectionStatus(confDir) {
	try {
		let config = detectionConfig(confDir);
		let result = query('detection', confDir);
		result.config = config;
		result.live = config.enabled;
		return result;
	}
	catch (error) {
		return { enabled: false, live: false, readOnly: true, autoBlocking: false,
			classificationAvailable: false, sources: [], limitations: [ '' + error ] };
	}
};
