'use strict';
'require baseclass';
'require rpc';

var getWarpStatus = rpc.declare({
 object: 'luci.warp',
 method: 'status_all',
 expect: { '': {} }
});

function bytes(value) {
 if (value == null || value === '') return '-';
 var n = Number(value), unit = ['B', 'KiB', 'MiB', 'GiB', 'TiB'], index = 0;
 if (!isFinite(n) || n < 0) return '-';
 while (n >= 1024 && index < unit.length - 1) { n /= 1024; index++; }
 return n.toFixed(index ? 1 : 0) + ' ' + unit[index];
}

function handshake(value) {
 var stamp = Number(value), now = Math.floor(Date.now() / 1000);
 if (!isFinite(stamp) || stamp <= 0 || stamp > now + 5) return null;
 return Math.max(0, now - stamp);
}

function statusLabel(item) {
 if (item.pending) return _('Connecting');
 if (!item.up) return item.error_code ? _('Error') + ': ' + item.error_code : _('Down');
 var age = handshake(item.latest_handshake);
 if (age == null || age > 180)
  return item.error_code === 'HANDSHAKE_TIMEOUT' ? _('Handshake timeout') : _('Interface up; handshake pending or stale');
 if (item.internet_ipv4 || item.internet_ipv6) return _('Handshake OK; Internet recently verified');
 return _('Handshake OK; Internet unverified');
}

function ageLabel(value) {
 var age = handshake(value);
 if (age == null) return _('Not yet');
 if (age < 60) return _('%s seconds ago').format(age);
 if (age < 3600) return _('%s minutes ago').format(Math.floor(age / 60));
 return _('%s hours ago').format(Math.floor(age / 3600));
}

function cell(label, content) {
 return E('td', { 'class': 'td', 'data-title': label }, content == null || content === '' ? '-' : String(content));
}

return baseclass.extend({
 title: _('Cloudflare WARP'),
 load: function() {
  return getWarpStatus().catch(function() { return { error: true, interfaces: [] }; });
 },
 render: function(data) {
  if (!data || data.error)
   return E('p', {}, _('Cloudflare WARP status is unavailable.'));
  var items = Array.isArray(data.interfaces) ? data.interfaces : [];
  if (!items.length) return E('p', {}, _('No Cloudflare WARP interfaces configured.'));
  var labels = [_('Interface'), _('Status'), _('Upstream'), _('IPv4 / IPv6'), _('Endpoint'), _('Handshake'), _('RX / TX')];
  var rows = [E('tr', { 'class': 'tr table-titles' }, labels.map(function(label) {
   return E('th', { 'class': 'th' }, label);
  }))];
  items.forEach(function(item) {
   var upstream = item.underlay_interface || '-';
   if (item.transport_device) upstream += ' (' + item.transport_device + ')';
   var addresses = [item.ipv4, item.ipv6].filter(function(value) { return !!value; }).join(' / ');
   rows.push(E('tr', { 'class': 'tr' }, [
    cell(labels[0], item.interface),
    cell(labels[1], statusLabel(item)),
    cell(labels[2], upstream),
    cell(labels[3], addresses),
    cell(labels[4], item.endpoint),
    cell(labels[5], ageLabel(item.latest_handshake)),
    cell(labels[6], bytes(item.rx_bytes) + ' / ' + bytes(item.tx_bytes))
   ]));
  });
  return E('div', {}, [
   E('table', { 'class': 'table' }, rows),
   E('p', {}, E('a', { 'href': L.url('admin/status/warp') }, _('Detailed Cloudflare WARP status')))
  ]);
 }
});
