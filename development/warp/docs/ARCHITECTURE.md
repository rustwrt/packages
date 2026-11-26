# Architecture

warp owns the netifd protocol and Lua registration helper. It uses the kernel WireGuard interface and netifd for addresses, default routes and DNS. Per-tunnel transport routing binds encrypted endpoint traffic to its selected upstream; it does not select the default Internet route. Standard netifd metrics determine route preference. Active WAN health-based failover and kill switches are external responsibilities.

luci-app-warp provides configuration and read-only RPC status. It depends on warp. Standard LuCI settings handle default gateway, metric and custom DNS; IPv6 defaults to enabled. The optional luci-i18n-warp-vi package compiles its PO catalog into LMO.

Credentials remain root-only under /etc/warp-reg. Session keys reside in /tmp/warp. Reconnect reuses an existing bound device account and rotates the session key. Old registration UCI overrides are ignored. Registration attempt limits prevent unbounded account creation. Never include runtime account files or private keys in the repository.

After a failed HTTPS health check, the backend probes tunnel packet sizes and, where nftables is available, applies a per-family TCP MSS limit only when a lower working PMTU is observed. Rules are scoped to the owned tunnel and removed at teardown. The IPv6 link MTU remains at least 1280; UDP/QUIC is not repaired by TCP MSS adjustment.
