'use strict';

import { isInteger, identifier, deepCopy, snakeCaseKeys } from './util.uc';

function requireObject(value, label) {
	if (type(value) != 'object')
		die(label + ' must be an object');
	return value;
};

function onlyKeys(value, allowed, label) {
	requireObject(value, label);
	for (let key in value)
		if (index(allowed, key) < 0)
			die(label + ': unsupported key ' + key);
};

function limits(options) {
	options ??= {};
	onlyKeys(options, [ 'maxBytes', 'maxRules', 'maxSources', 'mode' ], 'options');
	let result = {
		maxBytes: options.maxBytes ?? 1048576,
		maxRules: options.maxRules ?? 10000,
		maxSources: options.maxSources ?? 32,
		mode: options.mode ?? 'Hybrid'
	};
	if (!isInteger(result.maxBytes, 1, 16777216) || !isInteger(result.maxRules, 1, 100000)
		|| !isInteger(result.maxSources, 1, 256))
		die('invalid resource limits');
	if (index([ 'Hybrid', 'SRS-only', 'GeoIP2-only' ], result.mode) < 0)
		die('invalid mode');
	return result;
};

function decimal(value, maximum) {
	if (type(value) != 'string' || !length(value))
		die('invalid decimal');
	let result = 0;
	for (let offset = 0; offset < length(value); offset++) {
		let digit = ord(value, offset) - 48;
		if (digit < 0 || digit > 9)
			die('invalid decimal');
		result = result * 10 + digit;
		if (result > maximum)
			die('decimal out of range');
	}
	return result;
};

function ipv4(value) {
	let parts = split(value, '.');
	if (length(parts) != 4)
		die('IPv4 requires four octets');
	let bytes = [];
	for (let part in parts) {
		if (length(part) > 1 && substr(part, 0, 1) == '0')
			die('ambiguous IPv4 octet');
		push(bytes, decimal(part, 255));
	}
	return bytes;
};

function ipv6Part(value, allowIpv4) {
	let words = [];
	if (value == '')
		return words;
	let parts = split(value, ':');
	for (let offset = 0; offset < length(parts); offset++) {
		let part = parts[offset];
		if (index(part, '.') >= 0) {
			if (!allowIpv4 || offset != length(parts) - 1)
				die('embedded IPv4 must end IPv6');
			let bytes = ipv4(part);
			push(words, bytes[0] * 256 + bytes[1], bytes[2] * 256 + bytes[3]);
			continue;
		}
		if (!length(part) || length(part) > 4)
			die('invalid IPv6 group');
		let word = 0;
		for (let digitOffset = 0; digitOffset < length(part); digitOffset++) {
			let digit = index('0123456789abcdef', lc(substr(part, digitOffset, 1)));
			if (digit < 0)
				die('invalid IPv6 hexadecimal digit');
			word = word * 16 + digit;
		}
		push(words, word);
	}
	return words;
};

export function parseCidr(value) {
	if (type(value) != 'string' || length(value) > 64)
		die('invalid CIDR');
	let parts = split(value, '/');
	if (length(parts) != 2)
		die('CIDR requires a prefix');
	let address = parts[0], bytes = [], family = index(address, ':') >= 0 ? 6 : 4;
	let prefixLength = decimal(parts[1], family == 4 ? 32 : 128);
	if (length(parts[1]) > 1 && substr(parts[1], 0, 1) == '0')
		die('ambiguous prefix');
	if (family == 4)
		bytes = ipv4(address);
	else {
		let halves = split(address, '::');
		if (length(halves) > 2)
			die('multiple IPv6 compressions');
		let left = ipv6Part(halves[0], length(halves) == 1);
		let right = length(halves) == 2 ? ipv6Part(halves[1], true) : [];
		let count = length(left) + length(right);
		if ((length(halves) == 1 && count != 8) || (length(halves) == 2 && count >= 8))
			die('invalid IPv6 group count');
		if (length(halves) == 2)
			for (let offset = count; offset < 8; offset++)
				push(left, 0);
		for (let word in right)
			push(left, word);
		for (let word in left)
			push(bytes, int(word / 256), word % 256);
	}
	for (let offset = 0; offset < length(bytes); offset++) {
		let remaining = prefixLength - offset * 8;
		if (remaining <= 0)
			bytes[offset] = 0;
		else if (remaining < 8)
			bytes[offset] = bytes[offset] & ((255 << (8 - remaining)) & 255);
	}
	let groups = [];
	if (family == 4)
		for (let byte in bytes)
			push(groups, sprintf('%d', byte));
	else
		for (let offset = 0; offset < 16; offset += 2)
			push(groups, sprintf('%x', bytes[offset] * 256 + bytes[offset + 1]));
	return { kind: 'cidr', family: family, value: join(family == 4 ? '.' : ':', groups) + '/' + prefixLength };
};

export function normalizeDomain(value) {
	if (type(value) != 'string' || !length(value) || length(value) > 254)
		die('invalid domain');
	value = lc(value);
	if (substr(value, -1) == '.')
		value = substr(value, 0, length(value) - 1);
	if (!length(value) || length(value) > 253)
		die('invalid domain length');
	let labels = split(value, '.');
	for (let label in labels)
		if (!length(label) || length(label) > 63 || !match(label, /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/))
			die('invalid ASCII domain label');
	if (match(value, /^[0-9.]+$/) || index(value, ':') >= 0)
		die('IP literals are not domains');
	return value;
};

export function capabilityReport() {
	return {
		'cidr': { supported: true },
		'domain-txt': { supported: true, semantics: 'exact; explicit domain: or suffix: prefixes' },
		'sing-box-json': { supported: true, versions: [ 1 ], semantics: 'single-field ip_cidr, domain or domain_suffix rules' },
		'srs': { supported: false, requiresVerifiedConverter: true },
		'mmdb': { supported: false, requiresVerifiedConverter: true },
		'mihomo-yaml': { supported: false }
	};
};

function sourceInfo(source) {
	onlyKeys(source, [ 'name', 'format', 'enabled', 'priority', 'content', 'origin', 'license', 'revision', 'checksum' ], 'source');
	if (!identifier(source.name, 64))
		die('invalid source name');
	if (source.enabled !== null && source.enabled !== true && source.enabled !== false)
		die('enabled must be boolean');
	if (type(source.format) != 'string' || !exists(capabilityReport(), source.format))
		die('unknown source format');
	let priority = source.priority ?? 100;
	if (!isInteger(priority, 0, 2147483647))
		die('invalid source priority');
	let result = { name: source.name, format: source.format, priority: priority };
	for (let key in [ 'origin', 'license', 'revision' ]) {
		if (source[key] !== null && (type(source[key]) != 'string' || length(source[key]) > 1024))
			die('invalid provenance ' + key);
		result[key] = source[key];
	}
	return result;
};

export function parseSource(source, options, dependencies) {
	let bounds = limits(options), info = sourceInfo(source);
	dependencies ??= {};
	if (!capabilityReport()[info.format].supported)
		die('unsupported adapter: ' + info.format + '; compiled formats require a verified converter');
	if (type(source.content) != 'string' || length(source.content) > bounds.maxBytes)
		die('source byte limit exceeded or content missing');
	let checksumStatus = 'not-supplied';
	if (source.checksum !== null) {
		onlyKeys(source.checksum, [ 'algorithm', 'value' ], 'checksum');
		if (source.checksum.algorithm != 'sha256' || type(source.checksum.value) != 'string'
			|| !match(source.checksum.value, /^[0-9a-fA-F]{64}$/))
			die('invalid SHA-256 checksum');
		if (type(dependencies.verifyChecksum) != 'function'
			|| dependencies.verifyChecksum(source.content, deepCopy(source.checksum)) !== true)
			die('checksum verification failed');
		checksumStatus = 'verified';
	}
	let rules = [], seen = {}, inputRules = 0;
	function addRule(rule) {
		inputRules++;
		if (inputRules > bounds.maxRules)
			die('source rule limit exceeded');
		let key = rule.kind + ':' + rule.value;
		if (!exists(seen, key)) {
			seen[key] = true;
			push(rules, rule);
		}
	};
	function domainRule(value, kind) {
		return { kind: kind, value: normalizeDomain(value) };
	};
	if (info.format == 'sing-box-json') {
		let document = json(source.content);
		onlyKeys(document, [ 'version', 'rules' ], 'sing-box source');
		if (document.version !== 1 || type(document.rules) != 'array' || length(document.rules) > bounds.maxRules)
			die('unsupported sing-box version or invalid rules');
		for (let entry in document.rules) {
			onlyKeys(entry, [ 'ip_cidr', 'domain', 'domain_suffix' ], 'sing-box rule');
			let fields = 0;
			for (let key in entry) {
				fields++;
				if (fields > 1 || type(entry[key]) != 'array' || !length(entry[key]))
					die('mixed or empty sing-box clauses are unsupported');
				for (let value in entry[key])
					addRule(key == 'ip_cidr' ? parseCidr(value) : domainRule(value, key == 'domain' ? 'domain' : 'domain-suffix'));
			}
			if (fields != 1)
				die('empty sing-box rule');
		}
	}
	else {
		let lines = split(source.content, sprintf('%c', 10));
		for (let rawLine in lines) {
			if (length(rawLine) > 1024)
				die('line length limit exceeded');
			let line = trim(rawLine);
			if (!length(line) || substr(line, 0, 1) == '#')
				continue;
			if (info.format == 'cidr')
				addRule(parseCidr(line));
			else if (substr(line, 0, 7) == 'suffix:')
				addRule(domainRule(substr(line, 7), 'domain-suffix'));
			else
				addRule(domainRule(substr(line, 0, 7) == 'domain:' ? substr(line, 7) : line, 'domain'));
		}
	}
	if (!length(rules))
		die('source contains no rules');
	info.byteCount = length(source.content);
	info.inputRules = inputRules;
	info.ruleCount = length(rules);
	info.checksumStatus = checksumStatus;
	info.checksum = deepCopy(source.checksum);
	return { rules: rules, provenance: info };
};

export function toWire(value) {
	return snakeCaseKeys(value);
};

export function createManager(options, dependencies) {
	let bounds = limits(options);
	dependencies ??= {};
	requireObject(dependencies, 'dependencies');
	let active = null;
	let store = dependencies.store ?? {
		read: function() { return deepCopy(active); },
		compareAndSwap: function(expected, candidate) {
			if (sprintf('%J', expected) != sprintf('%J', active))
				return false;
			active = deepCopy(candidate);
			return true;
		}
	};
	if (type(store.read) != 'function' || type(store.compareAndSwap) != 'function')
		die('store requires read and atomic compareAndSwap');
	let pending = null, sequence = 0;
	return {
		stage: function(sources) {
			pending = null;
			if (type(sources) != 'array' || length(sources) > bounds.maxSources)
				die('source limit exceeded or invalid sources');
			let previous = deepCopy(store.read());
			let enabled = [], names = {};
			for (let source in sources) {
				let info = sourceInfo(source);
				if (exists(names, info.name))
					die('duplicate source name');
				names[info.name] = true;
				if (source.enabled === true)
					push(enabled, source);
			}
			sort(enabled, function(left, right) {
				let delta = (left.priority ?? 100) - (right.priority ?? 100);
				return delta || (left.name < right.name ? -1 : left.name > right.name ? 1 : 0);
			});
			let candidate = { mode: bounds.mode, rules: [], sources: [], byteCount: 0, inputRules: 0 }, seen = {};
			for (let source in enabled) {
				if ((bounds.mode == 'SRS-only' && index([ 'srs', 'sing-box-json' ], source.format) < 0)
					|| (bounds.mode == 'GeoIP2-only' && source.format != 'mmdb'))
					die('enabled source conflicts with mode');
				if (type(source.content) != 'string' || length(source.content) > bounds.maxBytes - candidate.byteCount)
					die('aggregate byte limit exceeded');
				let parsed = parseSource(source, bounds, dependencies);
				candidate.byteCount += parsed.provenance.byteCount;
				candidate.inputRules += parsed.provenance.inputRules;
				if (candidate.inputRules > bounds.maxRules)
					die('aggregate rule limit exceeded');
				push(candidate.sources, parsed.provenance);
				for (let rule in parsed.rules) {
					let key = rule.kind + ':' + rule.value;
					if (exists(seen, key)) {
						push(candidate.rules[seen[key]].sourceNames, source.name);
						continue;
					}
					seen[key] = length(candidate.rules);
					rule.sourceName = source.name;
					rule.sourceNames = [ source.name ];
					rule.priority = source.priority ?? 100;
					push(candidate.rules, rule);
				}
			}
			sequence++;
			pending = { token: sequence, previous: previous, candidate: candidate };
			return { token: sequence, candidate: deepCopy(candidate) };
		},
		activate: function(token) {
			if (!pending || token !== pending.token)
				die('unknown or stale stage token');
			let staged = pending;
			pending = null;
			if (store.compareAndSwap(deepCopy(staged.previous), deepCopy(staged.candidate)) !== true)
				die('atomic activation failed or active generation changed');
			return deepCopy(staged.candidate);
		},
		current: function() { return deepCopy(store.read()); }
	};
};
