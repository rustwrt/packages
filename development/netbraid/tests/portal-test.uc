'use strict';

import * as portal from '../../../net/netbraid/files/usr/lib/netbraid/portal.uc';

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

let disabled = portal.createPortal();
assert(disabled.config.enabled == false, 'portal defaults disabled');
assert(portal.authorize(disabled, 'aa:bb:cc:dd:ee:ff', 100) == null, 'disabled portal refuses authorization');
assert(disabled.lastError == 'portal_disabled', 'disabled refusal is explicit');

let state = portal.createPortal({ enabled: true, sessionTimeout: 120, title: '<script>alert(1)</script>', terms: 'A & B' });
assert(portal.allow(state, 'aa:bb:cc:dd:ee:ff'), 'allows valid hardware address');
let session = portal.authorize(state, 'aa:bb:cc:dd:ee:ff', 100);
assert(session.expiresAt == 220, 'creates bounded expiry');
assert(portal.status(state, 101).sessions == 1, 'reports active session');
assert(portal.expire(state, 220)['aa:bb:cc:dd:ee:ff'] == null, 'expires session at deadline');
assert(portal.revoke(state, 'aa:bb:cc:dd:ee:ff'), 'revokes session');
let landing = portal.renderLanding(state);
assert(index(landing, '&lt;script&gt;') >= 0 && index(landing, '<script>') < 0, 'escapes landing title');
assert(index(landing, 'A &amp; B') >= 0, 'escapes landing terms');
rejects(function() { portal.allow(state, 'invalid'); }, 'rejects malformed hardware address');
state.config.sessionTimeout = 59;
rejects(function() { portal.authorize(state, 'aa:bb:cc:dd:ee:01', 100); }, 'rejects session timeout below minimum');

let bounded = portal.createPortal({ enabled: true, sessionTimeout: 60 });
for (let index = 0; index < 256; index++) {
	let suffix = sprintf('%02x', index % 256);
	let mac = sprintf('02:00:00:00:00:%s', suffix);
	portal.authorize(bounded, mac, 1);
}
assert(portal.authorize(bounded, '02:00:00:01:00:00', 1) == null, 'caps active sessions');
assert(portal.status(bounded, 1).sessions == 256, 'keeps session count bounded');

print('PASS ucode portal tests');
