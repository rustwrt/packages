'use strict';
const fs = require('fs');
const assert = require('assert');
String.prototype.format = function(...values) {
 let index = 0;
 return this.replace(/%s/g, () => String(values[index++]));
};
function E(tag, attrs, content) {
 return { tag, attrs: attrs || {}, children: Array.isArray(content) ? content : (content == null ? [] : [content]) };
}
const src = fs.readFileSync('luci-proto-warp/files/www/luci-static/resources/view/status/include/35_warp.js', 'utf8');
let response = {}, reject = false;
const rpc = { declare(contract) {
 assert.strictEqual(contract.object, 'luci.warp');
 assert.strictEqual(contract.method, 'status_all');
 return () => reject ? Promise.reject(new Error('sensitive error')) : Promise.resolve(response);
} };
const overview = new Function('baseclass', 'rpc', 'E', 'L', '_', src)(
 { extend: x => x }, rpc, E, { url: (...parts) => '/' + parts.join('/') }, x => x
);
async function main() {
 assert.strictEqual(overview.title, 'Cloudflare WARP');
 const now = Math.floor(Date.now() / 1000);
 response = { interfaces: [
  { interface: 'warpa', up: true, latest_handshake: now, internet_ipv4: true,
    underlay_interface: 'wan3', transport_device: 'eth2', ipv4: '172.16.0.2', ipv6: '2001:db8::1',
    endpoint: '192.0.2.1:2408', rx_bytes: '1024', tx_bytes: '0' },
  { interface: 'warpb', up: true, latest_handshake: 0, error_code: 'HANDSHAKE_TIMEOUT' },
  { interface: 'warpc', up: true, latest_handshake: now - 200 }
 ] };
 const content = overview.render(await overview.load());
 const rows = content.children[0].children;
 assert.strictEqual(rows.length, 4);
 assert.strictEqual(rows[1].children[0].children[0], 'warpa');
 assert.strictEqual(rows[1].children[1].children[0], 'Handshake OK; Internet recently verified');
 assert.strictEqual(rows[1].children[2].children[0], 'wan3 (eth2)');
 assert.strictEqual(rows[1].children[3].children[0], '172.16.0.2 / 2001:db8::1');
 assert.strictEqual(rows[1].children[6].children[0], '1.0 KiB / 0 B');
 assert.strictEqual(rows[2].children[1].children[0], 'Handshake timeout');
 assert.strictEqual(rows[3].children[1].children[0], 'Interface up; handshake pending or stale');
 assert.strictEqual(content.children[1].children[0].attrs.href, '/admin/status/warp');
 assert.strictEqual(overview.render({interfaces: []}).children[0], 'No Cloudflare WARP interfaces configured.');
 reject = true;
 assert.strictEqual(overview.render(await overview.load()).children[0], 'Cloudflare WARP status is unavailable.');
 console.log('PASS: Overview renders every WARP, truthful health, WAN, addresses, traffic and errors');
}
main().catch(err => { console.error(err); process.exitCode = 1; });
