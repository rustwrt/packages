from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import sys
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        code=400 if self.path=='/error' else 200
        body=b'Unknown SID' if code==400 else b'fixture-data'
        self.send_response(code)
        self.send_header('Content-Length',str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self,*args): pass
server=HTTPServer(('127.0.0.1',0),Handler)
Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
