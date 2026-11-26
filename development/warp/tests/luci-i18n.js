#!/usr/bin/env node
// Verify the actual SDK PO compiler and LuCI translation lookup.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const vm = require('node:vm');
const { execFileSync } = require('node:child_process');
const sdk = process.argv[2];
assert(sdk, 'usage: node tests/luci-i18n.js /path/to/sdk');
const base = path.join(sdk, 'feeds/luci/modules/luci-base');
const src = fs.readFileSync(path.join(base, 'htdocs/luci-static/resources/cbi.js'), 'utf8');
const po = path.resolve(__dirname, '../../../luci/luci-i18n-warp-vi/po/vi/warp.po');
const text = fs.readFileSync(po, 'utf8');
const entries = Array.from(text.matchAll(/^msgctxt "luci-proto-warp"\nmsgid ("[^"\n]+")\nmsgstr ("[^"\n]*")$/gm));
assert.equal(entries.length, Array.from(text.matchAll(/^msgid "[^"\n]+"/gm)).length);
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'warp-i18n-'));
try {
    const lmo = path.join(tmp, 'warp.vi.lmo');
    execFileSync(path.join(base, 'src/po2lmo'), [po, lmo]);
    const b = fs.readFileSync(lmo);
    const trans = {};
    for (let off = b.readUInt32BE(b.length - 4); off < b.length - 4; off += 16) {
        const key = b.readUInt32BE(off).toString(16).padStart(8, '0');
        const start = b.readUInt32BE(off + 8);
        trans[key] = b.subarray(start, start + b.readUInt32BE(off + 12)).toString('utf8');
    }
    const ctx = vm.createContext({ window: { TR: trans }, TR: trans });
    vm.runInContext(src.slice(0, src.indexOf('function N_(')), ctx);
    for (const [, id, value] of entries) {
        const label = JSON.parse(id), translated = JSON.parse(value);
        assert.equal(ctx._(label), label, 'Unexpected global translation: ' + label);
        assert.equal(ctx._(label, 'luci-proto-warp'), translated, label);
    }
    assert.equal(ctx._('Status'), 'Status');
    assert.notEqual(ctx._('Status', 'luci-proto-warp'), 'Status');
    console.log('PASS: ' + entries.length + ' scoped translations; LuCI global Status remains unchanged');
} finally {
    fs.rmSync(tmp, { recursive: true, force: true });
}
