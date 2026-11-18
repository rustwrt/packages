# Automatic registration

The netifd path uses automatic registration metadata. Former registration field overrides are ignored. Device type, model, locale and OS metadata use existing backend defaults; install ID and serial number are empty. Device credentials are retained separately from session keys. The unofficial registration API and applicable terms must be respected.

General Settings selects the upstream interface. Advanced Settings retains MTU, keepalive and endpoint override plus common OpenWrt options. IPv6 is enabled by default (UCI ipv6=1); an explicit ipv6=0 disables IPv6 for WARP. Advanced users can set it via UCI. WARP does not add its own IPv6 checkbox.
