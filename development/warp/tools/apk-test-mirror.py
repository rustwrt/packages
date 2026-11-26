#!/usr/bin/env python3
"""Local, test-only relay for the native OpenWrt apk chroot.

The host verifies TLS; apk inside the chroot still verifies every official
index/package signature. Never expose the relay outside loopback.
"""
import http.server
import re
import shutil
import urllib.error
import urllib.request

PREFIX = "/releases/25.12.6/"
HOST = "https://downloads.openwrt.org"

class Mirror(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if not self.path.startswith(PREFIX) or not re.fullmatch(
            r"/releases/25\.12\.6/[A-Za-z0-9_./+~%=-]+(?:\.apk|/packages\.adb)",
            self.path,
        ) or ".." in self.path.split("/"):
            self.send_error(404)
            return
        # Reject encoded traversal and encoded separators as well.
        from urllib.parse import unquote
        decoded = unquote(self.path)
        if ".." in decoded.split("/") or not re.fullmatch(
            r"/releases/25\.12\.6/[A-Za-z0-9_./+~=-]+(?:\.apk|/packages\.adb)", decoded
        ):
            self.send_error(404)
            return
        try:
            with urllib.request.urlopen(HOST + self.path, timeout=90) as upstream:
                if not upstream.geturl().startswith("https://"):
                    raise ValueError("Non-TLS upstream redirect")
                body = upstream.read(128 * 1024 * 1024 + 1)
            if len(body) > 128 * 1024 * 1024:
                raise ValueError("Oversize test dependency")
        except urllib.error.HTTPError as error:
            self.send_error(error.code)
            return
        except (OSError, ValueError):
            self.send_error(502)
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

if __name__ == "__main__":
    http.server.ThreadingHTTPServer(("127.0.0.1", 18765), Mirror).serve_forever()
