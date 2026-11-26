# Chromecast TLS verification priority

User instruction (2026-11-22): Test current pure-ucode Chromecast implementation first. Validate ucode module imports, protobuf framing, TLS handshake, bidirectional TLS socket read/write and Cast V2 communication where hardware is available. Do not count successful module import as a working Chromecast connection. Record exact commands, pass/fail evidence, and distinguish unavailable real hardware from test failure.

If the existing ucode TLS path cannot work on stock OpenWrt 24.10 (for example missing ucode-mod-ffi), prefer a small native ucode binding using libustream-openssl/libubox rather than disabling Chromecast TLS. Implement and test fallback only if first approach fails. Ensure packaging dependencies, SDK build, and tests are verified. Do not claim success without handshake and bidirectional I/O evidence.
