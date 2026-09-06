"""A stand-in for Spotify's /v1/me used by the HTTP tests: any bearer token
is a user whose id is the token itself; 'bad' is rejected like an expired
session. Point CHORDLYZE_SPOTIFY_ME_URL at it."""
import json
import threading
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, HTTPServer


class _Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        token = self.headers.get('Authorization', '').removeprefix('Bearer ').strip()
        if not token or token == 'bad':
            self.send_response(401)
            self.end_headers()
            return
        body = json.dumps({'id': token, 'display_name': token.title()}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


@contextmanager
def fake_spotify():
    server = HTTPServer(('127.0.0.1', 0), _Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f'http://127.0.0.1:{server.server_address[1]}/me'
    finally:
        server.shutdown()
        server.server_close()
