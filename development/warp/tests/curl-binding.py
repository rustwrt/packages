#!/usr/bin/env python3
"""Verify curl config binds to a named local interface and fails closed."""
import http.server, subprocess, threading

class Handler(http.server.BaseHTTPRequestHandler):
    count = 0
    def do_GET(self):
        type(self).count += 1
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'ok')
    def log_message(self, *args):
        pass

httpd=http.server.HTTPServer(('127.0.0.1',0), Handler)
thread=threading.Thread(target=httpd.serve_forever,daemon=True)
thread.start()
url=f'http://127.0.0.1:{httpd.server_port}/'
def run(device):
    config=f'url = "{url}"\ninterface = "if!{device}"\nnoproxy = "*"\nsilent\nmax-time = 5\n'
    return subprocess.run(['curl','--config','-'],input=config,text=True,capture_output=True,timeout=10)
try:
    success=run('lo')
    assert success.returncode==0 and success.stdout=='ok', 'loopback bind failed'
    failed=run('warpnoexist0')
    assert failed.returncode==45, f'missing interface did not fail closed ({failed.returncode})'
    assert Handler.count==1, 'request leaked to another interface'
    print('PASS: curl binds to selected device and fails if that device is absent')
finally:
    httpd.shutdown(); httpd.server_close()
