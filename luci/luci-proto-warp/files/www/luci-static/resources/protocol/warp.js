'use strict';
'require form';
'require network';
'require uci';

return network.registerProtocol('warp', {
 getI18n: function() { return _('Cloudflare WARP'); },
 getIfname: function() { return this._ubus('l3_device') || this.sid; },
 getPackageName: function() { return 'cloudflare-warp'; },
 isFloating: function() { return true; },
 isVirtual: function() { return true; },

 renderFormOptions: function(s) {
  var o, mtu;

  o = s.taboption('general', form.ListValue, 'tunlink', _('Upstream interface'),
   _('Default follows the OpenWrt default Internet route. Registration and session keys are created automatically for each connection.'));
  o.value('default', _('Default (OpenWrt Internet route)'));
  uci.sections('network', 'interface').forEach(function(iface) {
   if (iface['.name'] !== 'loopback' && iface.proto !== 'warp')
    o.value(iface['.name'], iface['.name']);
  });
  o.default = 'default';
  o.rmempty = false;
  o.validate = function(sectionId, value) {
   if (!value || value === 'default') return true;
   var upstreamProto = uci.get('network', value, 'proto');
   return (/^[A-Za-z0-9_-]{1,32}$/.test(value) && value !== sectionId && value !== 'loopback' &&
    !!upstreamProto && upstreamProto !== 'warp') || _('Choose an existing non-WARP upstream interface.');
  };

  // Use the standard LuCI Advanced Settings for defaultroute and metric.

  mtu = s.taboption('advanced', form.Value, 'mtu', _('MTU'));
  mtu.datatype = 'range(576,9000)';
  mtu.placeholder = '1280';
  mtu.rmempty = true;
  mtu.validate = function(sectionId, value) {
   return /^(0|off|false|no|disabled)$/.test(uci.get('network', sectionId, 'ipv6') || '') || Number(value || 1280) >= 1280 || _('IPv6 requires an MTU of at least 1280.');
  };

  o = s.taboption('advanced', form.Value, 'keepalive', _('Persistent keepalive (seconds)'));
  o.datatype = 'range(0,65535)';
  o.placeholder = '25';
  o.rmempty = true;

  o = s.taboption('advanced', form.Value, 'endpoint', _('Endpoint override'),
   _('Optional IPv4 address and UDP port, for example 192.0.2.1:2408.'));
  o.rmempty = true;
  o.validate = function(sectionId, value) {
   if (!value) return true;
   var match = value.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3}):(\d{1,5})$/);
   if (!match || +match[1] > 255 || +match[2] > 255 || +match[3] > 255 || +match[4] > 255 || +match[5] < 1 || +match[5] > 65535)
    return _('Enter a valid IPv4 address and port.');
   return true;
  };

  // DNS is provided by LuCI's standard Advanced Settings.

 }
});
