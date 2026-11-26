'use strict';
'require form';
'require network';
'require uci';

return network.registerProtocol('warp', {
 getI18n: function() { return 'Cloudflare WARP'; },
 getIfname: function() { return this._ubus('l3_device') || this.sid; },
 getPackageName: function() { return 'warp'; },
 isFloating: function() { return true; },
 isVirtual: function() { return true; },
 getDevices: function() { return null; },
 containsDevice: function(ifname) { return network.getIfnameOf(ifname) === this.getIfname(); },
 renderFormOptions: function(s) {
  var o, sid = this.sid;
  function tr(v) { return _(v, 'luci-proto-warp'); }
  o = s.taboption('general', form.ListValue, 'tunlink', tr('Upstream interface'), tr('Default follows the OpenWrt default Internet route. Registration and session keys are created automatically for each connection.'));
  o.value('default', tr('Default (OpenWrt Internet route)'));
  o.default = 'default';
  o.rmempty = true;
  uci.sections('network', 'interface').forEach(function(n) {
   if (n['.name'] !== sid && n['.name'] !== 'loopback' && n.proto !== 'warp')
    o.value(n['.name']);
  });
  o.validate = function(section_id, value) {
   if (!value || value === 'default') return true;
   return value !== section_id && value !== 'loopback' && /^[A-Za-z0-9_-]{1,32}$/.test(value) &&
    uci.sections('network', 'interface').some(function(n) { return n['.name'] === value && n.proto !== 'warp'; }) ||
    tr('Choose an existing non-WARP upstream interface.');
  };
  o = s.taboption('advanced', form.Value, 'endpoint', tr('Endpoint override'), tr('Optional IPv4 address and UDP port, for example 192.0.2.1:2408.'));
  o.rmempty = true;
  o.validate = function(section_id, value) {
   if (!value) return true;
   var m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3}):(\d{1,5})$/.exec(value);
   return !!m && m.slice(1,5).every(function(x) { return Number(x) <= 255; }) &&
    Number(m[5]) >= 1 && Number(m[5]) <= 65535 || tr('Enter a valid IPv4 address and port.');
  };
  o = s.taboption('advanced', form.Value, 'mtu', tr('MTU'));
  o.placeholder = '1280';
  o.datatype = 'range(576,9000)';
  o.rmempty = true;
  o.validate = function(section_id, value) {
   if (!value) return true;
   if (!/^\d+$/.test(value) || Number(value) < 576 || Number(value) > 9000) return _('Invalid value');
   return uci.get('network', section_id, 'ipv6') === '0' || Number(value) >= 1280 || tr('IPv6 requires an MTU of at least 1280.');
  };
  o = s.taboption('advanced', form.Value, 'keepalive', tr('Persistent keepalive (seconds)'));
  o.placeholder = '25';
  o.datatype = 'range(0,65535)';
  o.rmempty = true;
 }
});
