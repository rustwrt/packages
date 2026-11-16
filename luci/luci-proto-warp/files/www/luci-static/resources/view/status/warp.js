'use strict';
'require view';
'require rpc';
'require poll';

var get = rpc.declare({ object: 'luci.warp', method: 'status_all', expect: { '': {} } });

function fmt(v) {
    if (v == null || v === '') return '-';
    var n = Number(v), units = ['B', 'KiB', 'MiB', 'GiB'], idx = 0;
    if (!isFinite(n)) return '-';
    while (Math.abs(n) >= 1024 && idx < 3) { n /= 1024; idx++; }
    return n.toFixed(idx ? 1 : 0) + ' ' + units[idx];
}
function ago(t) {
    if (!t) return '-';
    var seconds = Math.max(0, Math.floor(Date.now() / 1000 - Number(t)));
    if (seconds < 60) return seconds + 's ago';
    if (seconds < 3600) return Math.floor(seconds / 60) + 'm ago';
    if (seconds < 86400) return Math.floor(seconds / 3600) + 'h ago';
    return Math.floor(seconds / 86400) + 'd ago';
}
function field(label, value) {
    return E('div', { style: 'min-width:0;padding:8px 0;display:grid;grid-template-columns:minmax(110px,42%) minmax(0,1fr);gap:12px;align-items:start' }, [
        E('strong', {}, label),
        E('span', { style: 'overflow-wrap:anywhere' }, value == null || value === '' ? '-' : String(value))
    ]);
}
function group(title, entries) {
    return E('section', { style: 'padding:16px 20px;border-top:1px solid #e5e7eb' }, [
        E('h3', { style: 'margin:0 0 8px;font-size:1.05em' }, title),
        E('div', { style: 'display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,300px),1fr));column-gap:24px' }, entries)
    ]);
}
function card(i) {
    var connected = i.state === 'up' && Number(i.latest_handshake) > 0 && (Date.now() / 1000 - Number(i.latest_handshake)) < 180;
    var health = i.state !== 'up' ? (i.state || '-') : (connected ? ((i.internet_ipv4 || i.internet_ipv6) ? _('Internet verified recently') : _('Handshake received; Internet unverified')) : (i.error_code === 'HANDSHAKE_TIMEOUT' ? _('Handshake timeout') : _('Interface up; handshake pending or stale')));
    return E('section', { style: 'border:1px solid #d1d5db;border-radius:8px;overflow:hidden;margin-bottom:20px' }, [
        E('div', { style: 'background:#f3f4f5;padding:14px 20px;display:flex;align-items:center;gap:10px' }, [
            E('span', { style: 'width:11px;height:11px;border-radius:50%;background:' + (connected ? '#27c327' : '#999') }),
            E('strong', { style: 'font-size:1.2em' }, i.interface || i.name || 'warp'),
            E('span', { style: 'margin-left:auto' }, health)
        ]),
        group(_('Connection'), [
            field(_('Interface'), i.interface || i.name),
            field(_('Endpoint'), i.endpoint),
            field(_('Selected upstream'), i.underlay_interface),
            field(_('Upstream device'), i.underlay_device),
            field(_('Actual transport device'), i.transport_device),
            field(_('Latest Handshake'), ago(i.latest_handshake)),
            field(_('Connection uptime'), i.started_at ? ago(i.started_at).replace(' ago', '') : '-')
        ]),
        group(_('IP Addresses'), [
            field(_('Tunnel IPv4'), i.ipv4),
            field(_('Tunnel IPv6'), i.ipv6),
            field(_('Public IPv4'), i.public_ipv4),
            field(_('Public IPv6'), i.public_ipv6)
        ]),
        group(_('Traffic'), [
            field(_('Data Received'), fmt(i.rx_bytes)),
            field(_('Data Transmitted'), fmt(i.tx_bytes))
        ])
    ]);
}
return view.extend({
    load: function() { return get(); },
    render: function(data) {
        var content = E('div');
        var root = E('div', {}, [E('h2', {}, _('Cloudflare WARP Status')), content]);
        function update(d) {
            var interfaces = d && Array.isArray(d.interfaces) ? d.interfaces : [];
            content.replaceChildren();
            if (!interfaces.length) content.appendChild(E('p', {}, _('No WARP interfaces available')));
            interfaces.forEach(function(i) { content.appendChild(card(i)); });
        }
        update(data);
        poll.add(function() { return get().then(update).catch(function() {}); }, 5);
        return root;
    },
    handleSaveApply: null,
    handleSave: null,
    handleReset: null
});
