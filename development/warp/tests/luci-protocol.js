'use strict';
const fs = require('fs');
const assert = require('assert');

const source = fs.readFileSync('luci-proto-warp/files/www/luci-static/resources/protocol/warp.js', 'utf8');
const form = { Value: 'Value', Flag: 'Flag', ListValue: 'ListValue', DynamicList: 'DynamicList' };
const sections = [
 { '.name': 'wan', proto: 'dhcp' },
 { '.name': 'loopback', proto: 'static' },
 { '.name': 'warp-old', proto: 'warp' },
 { '.name': 'wan2', proto: 'pppoe' }
];
const uci = {
 get: (config, section, key) => key === 'proto' ? (sections.find(item => item['.name'] === section) || {}).proto : ({ account: 'saved', account_mode: '' }[key] || ''),
 sections: () => sections
};
const network = { registerProtocol: (name, options) => { assert.strictEqual(name, 'warp'); return options; } };
let accountResponse = {}, accountReject = false, notifications = 0;
const accountCalls = [], writes = [];
uci.set = (...args) => writes.push(args);
const proto = new Function('form', 'network', 'uci', '_', 'rpc', 'ui', 'E', source)(form, network, uci, value => value,
 { declare: contract => (...args) => { accountCalls.push([contract.method, ...args]); return accountReject ? Promise.reject(new Error('sensitive backend detail')) : Promise.resolve(accountResponse); } },
 { addNotification: (unused, node) => { notifications++; assert(!node.textContent.includes('sensitive')); } },
 (tag, attrs, text) => ({ textContent: text }));
const fields = {};
const section = {
 taboption: (tab, kind, name) => {
  assert(['general', 'advanced'].includes(tab));
  const field = { tab, kind, name, values: [], dependencies: [], inputValue: name === 'ipv6' ? '0' : '', active: true,
   depends: function(key, value) { this.dependency = [key, value]; this.dependencies.push([key, value]); },
   value: function(key, label) { this.values.push([key, label]); },
   formvalue: function() { return this.inputValue; },
   cfgvalue: function() { return ''; },
   write: function(sectionId, value) { writes.push(['network', sectionId, name, value]); },
   remove: function(sectionId) { writes.push(['network', sectionId, name, null]); },
   getUIElement: function() { return { setValue: value => { this.inputValue = value; } }; },
   isActive: function() { return this.active; }
  };
  fields[name] = field;
  return field;
 }
};

proto.renderFormOptions(section);
// LuCI 24.10 replaces the protocol's defaultroute after renderFormOptions.
// Reproduce that ordering, including its stock enabled default.
assert(!fields.defaultroute && !fields.metric && !fields.dns, 'Protocol must not override stock network options');
section.taboption('advanced', form.DynamicList, 'dns', 'Use custom DNS servers');
const replacedRoute = section.taboption('advanced', form.Flag, 'defaultroute', 'Use default gateway');
replacedRoute.default = '1';
assert.strictEqual(replacedRoute.tab, 'advanced');
assert.strictEqual(replacedRoute.default, '1');
assert.strictEqual(section.taboption('advanced', form.Value, 'metric').tab, 'advanced');
assert.strictEqual(section.taboption('advanced', form.Flag, 'other_flag').tab, 'advanced');
assert(!fields.account_mode && !fields.account && !fields._account_id && !fields._device_id && !fields._access_token && !fields._generate_account);
assert(!fields.reg_key);
assert(!fields._registration_public_key && !fields._registration_private_key && !fields._generate_keypair && !fields._generate_public_key);
assert.strictEqual(fields.tunlink.tab, 'general');
assert.strictEqual(fields.defaultroute.tab, 'advanced');
for (const name of ['install_id','type','model','locale','serial_number','os_version'])
 assert(!fields['reg_' + name], name + ' must be automatic');
for (const name of ['tos','key_type','tunnel_type'])
 assert(!fields['reg_' + name], name + ' must be automatic');
for (const name of ['mtu', 'keepalive', 'dns']) {
 assert.deepStrictEqual(fields[name].values, [], name + ' has no selector suggestions');
 assert.strictEqual(fields[name].kind, name === 'dns' ? 'DynamicList' : 'Value', name + ' is an input');
}
assert.deepStrictEqual(fields.endpoint.values, []);
assert(!fields._registration_fcm && !fields._clear_registration_fcm && !fields.fcm_token);
assert(!fields.reg_warp_enabled);
assert(!fields.firewall_zone);
assert.strictEqual(fields.tunlink.validate('warp0', 'wan2'), true);
assert.notStrictEqual(fields.tunlink.validate('warp0', 'warp-old'), true);
assert.notStrictEqual(fields.tunlink.validate('warp0', 'loopback'), true);
assert.strictEqual(fields.endpoint.validate('warp0', '192.0.2.1:2408'), true);
assert.notStrictEqual(fields.endpoint.validate('warp0', '999.0.0.1:2408'), true);
assert.notStrictEqual(fields.endpoint.validate('warp0', '192.0.2.1:99999'), true);
assert.strictEqual(fields.defaultroute.default, '1');
assert(!fields.ipv6 && !fields.enable_ipv6, 'No WARP-specific IPv6 UI');
assert(!('access_token' in fields) && !('private_key' in fields));
assert.deepStrictEqual(fields.tunlink.values.map(item => item[0]), ['default', 'wan', 'wan2']);
for (const value of ['warp0', 'missing', 'wan;reboot']) assert.notStrictEqual(fields.tunlink.validate('warp0', value), true);
assert.notStrictEqual(fields.mtu.validate('warp0', '1200'), true);
assert.strictEqual(fields.mtu.validate('warp0', ''), true);
const originalGet = uci.get;
uci.get = (config, section, key) => key === 'ipv6' ? '0' : originalGet(config, section, key);
assert.strictEqual(fields.mtu.validate('warp0', '1200'), true);
uci.get = originalGet;

String.prototype.format = function(...values) { let index = 0; return this.replace(/%s/g, () => values[index++]); };
function element(tag, attributes = {}, content = []) {
 const node = { tag, attributes, children: [], hidden: !!attributes.hidden, textContent: '',
  appendChild(child) { this.children.push(child); child.parent = this; return child; },
  replaceChildren(...children) { this.children = []; children.forEach(child => this.appendChild(child)); },
  remove() { this.parent.children.splice(this.parent.children.indexOf(this), 1); },
  setAttribute(name, value) { this.attributes[name] = value; }
 };
 if (Array.isArray(content)) content.forEach(child => node.appendChild(child));
 else node.textContent = String(content);
 return node;
}
const statusSource = fs.readFileSync('luci-proto-warp/files/www/luci-static/resources/view/status/warp.js', 'utf8');
let response, reject = false, polls = [], calls = 0;
const rpc = { declare(contract) {
 assert.strictEqual(contract.object, 'luci.warp');
 assert.strictEqual(contract.method, 'status_all');
 return () => { calls++; return reject ? Promise.reject(new Error('private error must not appear')) : Promise.resolve(response); };
} };
const statusView = new Function('view', 'rpc', 'poll', 'E', '_', statusSource)({ extend: value => value }, rpc, { add: (callback, interval) => { assert.strictEqual(interval, 5); polls.push(callback); } }, element, value => value);
async function testStatus() {
 assert.strictEqual(accountCalls.length, 0);
 response = { interfaces: [
  { interface: 'warp0', state: 'up', rx_bytes: '1024', tx_bytes: '0', latest_handshake: 0 },
  { interface: 'warp1', state: 'up', latest_handshake: Math.floor(Date.now() / 1000) }
 ] };
 const container = statusView.render(await statusView.load());
 const [heading, content] = container.children;
 assert.strictEqual(heading.textContent, 'Cloudflare WARP Status');
 assert.strictEqual(calls, 1);
 assert.strictEqual(content.children.length, 2);
 assert.strictEqual(content.children[0].children[0].children[2].textContent, 'Interface up; handshake pending or stale');
 assert.strictEqual(content.children[1].children[0].children[2].textContent, 'Handshake received; Internet unverified');
 response.interfaces[0].latest_handshake = Math.floor(Date.now() / 1000);
 await polls[0]();
 assert.strictEqual(content.children[0].children[0].children[2].textContent, 'Handshake received; Internet unverified');
 reject = true;
 await polls[0]();
 assert.strictEqual(content.children.length, 2);
 reject = false;
 response = { interfaces: [] };
 await polls[0]();
 assert.strictEqual(content.children[0].textContent, 'No WARP interfaces available');
 assert.strictEqual(statusView.handleSaveApply, null);
 assert.strictEqual(statusView.handleReset, null);
 console.log('PASS: WARP form and status handshake, polling and empty state');
}
testStatus().catch(error => { console.error(error); process.exitCode = 1; });
