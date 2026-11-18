'use strict';

import * as ruleset from '../../../net/netbraid/files/usr/lib/netbraid/ruleset.uc';
import { deepCopy, deepEqual } from '../../../net/netbraid/files/usr/lib/netbraid/util.uc';

let assertions = 0;
function assert(condition, message) {
	assertions++;
	if (!condition)
		die('FAIL: ' + message);
};

function rejects(callback, message) {
	let rejected = false;
	try { callback(); }
	catch (error) { rejected = true; }
	assert(rejected, message);
};

function source(content, format, name) {
	return { name: name ?? 'test', format: format ?? 'cidr', content: content, enabled: true };
};

function sourceJson(document) {
	return source(sprintf('%J', document), 'sing-box-json');
};

assert(ruleset.parseCidr('192.0.2.129/24').value == '192.0.2.0/24', 'IPv4 host bits normalized');
assert(ruleset.parseCidr('255.255.255.255/0').value == '0.0.0.0/0', 'IPv4 zero prefix');
assert(ruleset.parseCidr('2001:DB8:0:0:0:0:1:ffff/64').value == '2001:db8:0:0:0:0:0:0/64', 'IPv6 host bits normalized');
assert(ruleset.parseCidr('2001:db8::1/127').value == '2001:db8:0:0:0:0:0:0/127', 'IPv6 partial byte prefix');
assert(ruleset.parseCidr('::ffff:192.0.2.129/128').value == '0:0:0:0:0:ffff:c000:281/128', 'embedded IPv4 parsed as IPv6');
assert(ruleset.parseCidr('::/0').family == 6, 'IPv6 zero prefix');
assert(ruleset.parseCidr('1:2:3:4:5:6:7::/128').value == '1:2:3:4:5:6:7:0/128', 'one compressed group');
for (let value in [ '256.1.1.1/24', '1.2.3/24', '01.2.3.4/8', '1.2.3.4/-1', '1.2.3.4/33',
	'1.2.3.4/01', '1.2.3.4', '1.2.3.4/24/1', '1.2.3.4x/24', '1.2.3.4/24x',
	':::/64', '1::2::3/64', '1:2:3:4:5:6:7/64', '1:2:3:4:5:6:7:8:9/64',
	'1:2:3:4:5:6:7:8::/64', ':1:2:3:4:5:6:7/64', 'gggg::/64', '12345::/64',
	'fe80::1%eth0/64', '[::1]/128', '::1/129', '192.0.2.1::/64', '::192.0.2.1:1/64',
	'::ffff:192.0.2.999/128', '::ffff:192.00.2.1/128', '::/','/0' ])
	rejects(function() { ruleset.parseCidr(value); }, 'reject malformed CIDR ' + value);

let parsed = ruleset.parseSource(source('# list\n192.0.2.1/24\n192.0.2.255/24\n2001:db8::1/64\n2001:0db8:0:0:0:0:0:2/64\n'));
assert(length(parsed.rules) == 2 && parsed.provenance.inputRules == 4, 'dedup normalized IPv4 and IPv6');
assert(parsed.provenance.byteCount > 0 && parsed.provenance.checksumStatus == 'not-supplied', 'provenance counters');
parsed = ruleset.parseSource(source('Example.COM.\nsuffix:Example.com\ndomain:example.com\n# comment\n', 'domain-txt'));
assert(length(parsed.rules) == 2 && parsed.rules[0].kind == 'domain' && parsed.rules[1].kind == 'domain-suffix', 'domain exact and suffix remain distinct');
for (let value in [ '*.example.com', '.example.com', 'example..com', '-bad.com', 'bad-.com',
	'https://example.com', 'example.com/path', '0.0.0.0 example.com', '1.2.3.4', 'a_b.com', 'é.com', 'foo.com # inline' ])
	rejects(function() { ruleset.parseSource(source(value, 'domain-txt')); }, 'reject unsafe domain ' + value);
let longLabel = '';
for (let offset = 0; offset < 64; offset++)
	longLabel += 'a';
rejects(function() { ruleset.normalizeDomain(longLabel + '.com'); }, 'domain label length bounded');

let document = { version: 1, rules: [ { ip_cidr: [ '192.0.2.1/24', '::1/128' ] },
	{ domain: [ 'Example.com' ] }, { domain_suffix: [ 'example.com' ] } ] };
parsed = ruleset.parseSource(sourceJson(document));
assert(length(parsed.rules) == 4 && parsed.rules[2].kind == 'domain', 'sing-box source supports strict OR clauses');
assert(exists(document.rules[0], 'ip_cidr'), 'third party input key unchanged');
for (let entry in [ {}, { domain: [] }, { domain: 'example.com' }, { domain: [ 1 ] },
	{ domain: [ 'example.com' ], domain_suffix: [ 'example.org' ] },
	{ ip_cidr: [ '192.0.2.0/24' ], domain: [ 'example.com' ] },
	{ domain: [ 'example.com' ], invert: true }, { domain_keyword: [ 'example' ] },
	{ type: 'logical', mode: 'or', rules: [ { domain: [ 'example.com' ] } ] },
	{ port: [ 443 ] }, { network: 'tcp' }, { source_ip_cidr: [ '192.0.2.0/24' ] } ])
	rejects(function() { ruleset.parseSource(sourceJson({ version: 1, rules: [ entry ] })); }, 'unsupported sing-box clauses fail closed');
for (let content in [ '{', 'null', '[]', '{"version":2,"rules":[]}', '{"version":1,"rules":[],"extra":true}', '{"version":1,"rules":{}}' ])
	rejects(function() { ruleset.parseSource(source(content, 'sing-box-json')); }, 'invalid source JSON rejected');
let capabilities = ruleset.capabilityReport();
for (let format in [ 'srs', 'mmdb', 'mihomo-yaml' ]) {
	assert(capabilities[format].supported === false, 'no fake adapter ' + format);
	rejects(function() { ruleset.parseSource(source('binary', format)); }, 'unimplemented adapter rejected');
}
assert(capabilities.srs.requiresVerifiedConverter && capabilities.mmdb.requiresVerifiedConverter, 'compiled capabilities require verified converter');
rejects(function() { ruleset.parseSource(source('a', 'unknown')); }, 'unknown adapter rejected');

let checked = source('192.0.2.0/24');
checked.checksum = { algorithm: 'sha256', value: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' };
rejects(function() { ruleset.parseSource(checked); }, 'checksum without verifier rejected');
rejects(function() { ruleset.parseSource(checked, {}, { verifyChecksum: function() { return false; } }); }, 'checksum mismatch rejected');
rejects(function() { ruleset.parseSource(checked, {}, { verifyChecksum: function() { return 1; } }); }, 'checksum truthy response rejected');
let verifierCalls = 0;
parsed = ruleset.parseSource(checked, {}, { verifyChecksum: function(content, checksum) {
	verifierCalls++;
	assert(content == checked.content && checksum.algorithm == 'sha256' && checksum.value == checked.checksum.value, 'verifier receives original bytes and digest');
	checksum.value = 'mutated';
	return true;
} });
assert(verifierCalls == 1 && parsed.provenance.checksumStatus == 'verified' && checked.checksum.value != 'mutated', 'verified checksum metadata and isolation');
let invalidChecksum = deepCopy(checked);
invalidChecksum.checksum.value = 'bad';
rejects(function() { ruleset.parseSource(invalidChecksum); }, 'malformed checksum rejected');
invalidChecksum.checksum = { algorithm: 'md5', value: checked.checksum.value };
rejects(function() { ruleset.parseSource(invalidChecksum); }, 'unsupported checksum algorithm rejected');

rejects(function() { ruleset.parseSource(source('192.0.2.0/24'), { maxBytes: 11 }); }, 'source bytes bounded before parse');
assert(length(ruleset.parseSource(source('192.0.2.0/24'), { maxBytes: 12, maxRules: 1 }).rules) == 1, 'exact byte and rule boundary accepted');
rejects(function() { ruleset.parseSource(source('::/0\n::/0'), { maxRules: 1 }); }, 'duplicates consume input rule budget');
rejects(function() { ruleset.parseSource(sourceJson(document), { maxRules: 3 }); }, 'JSON entries bounded');
rejects(function() { ruleset.parseSource(sourceJson({ version: 1, rules: [ { domain: [ 'a', 'b' ] } ] }), { maxRules: 1 }); }, 'JSON array values bounded');
rejects(function() { ruleset.parseSource(source('# empty\n')); }, 'empty source rejected');
rejects(function() { ruleset.createManager({ maxBytes: 0 }); }, 'invalid bounds rejected');
rejects(function() { ruleset.createManager({ maxRules: 100001 }); }, 'hard rule ceiling');
rejects(function() { ruleset.createManager({ mode: 'invalid' }); }, 'unknown mode rejected');
let longLine = '';
for (let offset = 0; offset < 1025; offset++)
	longLine += '#';
rejects(function() { ruleset.parseSource(source(longLine)); }, 'comment lines bounded');

let manager = ruleset.createManager();
assert(manager.current() === null, 'initial manager inactive');
let disabled = source('invalid');
delete disabled.enabled;
let staged = manager.stage([ disabled ]);
assert(staged.candidate.mode == 'Hybrid' && !length(staged.candidate.rules), 'default Hybrid and opt-in activation');
assert(manager.current() === null, 'staging does not activate');
manager.activate(staged.token);
assert(length(manager.current().rules) == 0, 'explicit empty activation supported');
let first = source('192.0.2.1/24', 'cidr', 'zeta');
first.priority = 20;
let second = source('192.0.2.9/24\n::1/128', 'cidr', 'beta');
second.priority = 10;
second.origin = 'manual upload';
second.license = 'operator supplied';
second.revision = 'r1';
let third = source('192.0.2.0/24', 'cidr', 'alpha');
third.priority = 10;
staged = manager.stage([ first, second, third ]);
let candidate = staged.candidate;
assert(candidate.sources[0].name == 'alpha' && candidate.sources[1].name == 'beta' && candidate.sources[2].name == 'zeta', 'priority then name ordering');
assert(candidate.rules[0].sourceName == 'alpha' && join(',', candidate.rules[0].sourceNames) == 'alpha,beta,zeta', 'dedup retains deterministic owner and contributors');
assert(candidate.sources[1].origin == 'manual upload' && candidate.sources[1].revision == 'r1', 'source provenance preserved');
let reordered = ruleset.createManager().stage([ third, first, second ]).candidate;
assert(deepEqual(candidate, reordered), 'source input ordering does not change candidate');
candidate.rules[0].value = 'mutated';
let activated = manager.activate(staged.token);
assert(activated.rules[0].value == '192.0.2.0/24', 'staged snapshot cannot be modified by caller');
activated.rules[0].value = 'mutated';
let current = manager.current();
assert(current.rules[0].value == '192.0.2.0/24', 'active snapshot cannot be modified by caller');
let wire = ruleset.toWire(current);
assert(wire.byte_count > 0 && wire.rules[0].source_name == 'alpha' && !exists(wire, 'byteCount'), 'snake case only at serialization boundary');
rejects(function() { manager.activate(staged.token); }, 'activation token one shot');
let old = manager.stage([ third ]);
let latest = manager.stage([ second ]);
rejects(function() { manager.activate(old.token); }, 'replaced stage token rejected');
manager.activate(latest.token);
let before = manager.current();
old = manager.stage([ third ]);
rejects(function() { manager.stage([ source('bad') ]); }, 'failed validation rejected');
rejects(function() { manager.activate(old.token); }, 'failed staging invalidates prior stage');
assert(deepEqual(before, manager.current()), 'parse failure preserves active generation');
rejects(function() { manager.stage([ third, third ]); }, 'duplicate source names rejected');
rejects(function() { ruleset.createManager({ maxSources: 1 }).stage([ first, second ]); }, 'source count bounded');
rejects(function() { ruleset.createManager({ maxBytes: 20 }).stage([ first, third ]); }, 'aggregate bytes bounded');
rejects(function() { ruleset.createManager({ maxRules: 1 }).stage([ first, third ]); }, 'aggregate duplicate rules bounded');
rejects(function() { ruleset.createManager({ mode: 'SRS-only' }).stage([ first ]); }, 'mode mismatch rejected');
assert(ruleset.createManager({ mode: 'SRS-only' }).stage([ sourceJson(document) ]).candidate.mode == 'SRS-only', 'SRS-only accepts source equivalent');
rejects(function() { ruleset.createManager({ mode: 'GeoIP2-only' }).stage([ first ]); }, 'GeoIP2-only rejects unrelated sources');

let stored = { mode: 'Hybrid', rules: [], sources: [], byteCount: 0, inputRules: 0 }, failCommit = false, commitCalls = 0;
let store = {
	read: function() { return deepCopy(stored); },
	compareAndSwap: function(expected, value) {
		commitCalls++;
		if (failCommit || !deepEqual(expected, stored))
			return false;
		stored = deepCopy(value);
		return true;
	}
};
let persistent = ruleset.createManager({}, { store: store });
staged = persistent.stage([ third ]);
let previous = deepCopy(stored);
failCommit = true;
rejects(function() { persistent.activate(staged.token); }, 'injected atomic commit failure');
assert(deepEqual(previous, stored) && commitCalls == 1, 'commit failure rolls back by preserving previous pointer');
rejects(function() { persistent.activate(staged.token); }, 'failed commit consumes token');
failCommit = false;
staged = persistent.stage([ third ]);
stored = { changed: true };
rejects(function() { persistent.activate(staged.token); }, 'concurrent store modification rejects stale activation');
assert(stored.changed === true, 'stale activation preserves concurrent generation');
staged = persistent.stage([ third ]);
persistent.activate(staged.token);
assert(stored.rules[0].sourceName == 'alpha', 'injected atomic store activation succeeds');
rejects(function() { ruleset.createManager({}, { store: {} }); }, 'incomplete store contract rejected');

print(sprintf('PASS ruleset tests (%d assertions)\n', assertions));
