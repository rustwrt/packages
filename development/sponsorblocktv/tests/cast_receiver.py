"""Loopback-only Cast V2 receiver fixture. Run with a test certificate and key."""
import json
import socketserver
import ssl
import struct
import sys

from pychromecast.generated.cast_channel_pb2 import CastMessage

MDX = "urn:x-cast:com.google.youtube.mdx"


class Receiver(socketserver.StreamRequestHandler):
    def handle(self):
        while header := self.rfile.read(4):
            size, = struct.unpack(">I", header)
            message = CastMessage.FromString(self.rfile.read(size))
            request = json.loads(message.payload_utf8)
            kind = request.get("type")
            if kind == "GET_STATUS" and message.namespace.endswith(".receiver"):
                app = {"appId": "233637DE", "displayName": "YouTube",
                       "sessionId": "test-session", "transportId": "test-transport",
                       "namespaces": [{"name": MDX}]}
                result = {"type": "RECEIVER_STATUS", "status": {"applications": [app],
                          "volume": {"level": 0.5, "muted": False}}}
            elif kind == "PING":
                result = {"type": "PONG"}
            elif kind == "getMdxSessionStatus":
                result = {"type": "mdxSessionStatus", "data": {"screenId": "mock-screen-24104"}}
            else:
                continue
            if "requestId" in request:
                result["requestId"] = request["requestId"]
            response = CastMessage(protocol_version=0, payload_type=0,
                                   source_id=message.destination_id, destination_id=message.source_id,
                                   namespace=message.namespace, payload_utf8=json.dumps(result))
            payload = response.SerializeToString()
            self.wfile.write(struct.pack(">I", len(payload)) + payload)


if __name__ == "__main__":
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(sys.argv[1], sys.argv[2])
    with socketserver.ThreadingTCPServer(("127.0.0.1", 8009), Receiver) as server:
        server.socket = context.wrap_socket(server.socket, server_side=True)
        server.serve_forever()
