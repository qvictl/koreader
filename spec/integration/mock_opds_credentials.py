#!/usr/bin/env python3
"""Two loopback-only, non-forwarding origins with synthetic Basic credentials."""
import base64
import http.server
import json
from pathlib import Path
import signal
import sys
import threading

root, book = Path(sys.argv[1]), Path(sys.argv[2])
expected = 'Basic ' + base64.b64encode('reader%40example:fake%F5:%2520+é'.encode()).decode()
lock = threading.Lock()
counter = 0


def write(name, value):
    path = root / name
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value), encoding='utf-8')
    temporary.replace(path)


class Handler(http.server.BaseHTTPRequestHandler):
    def setup(self):
        super().setup()
        self.connection.settimeout(5)

    def serve(self):
        global counter
        foreign = self.server.foreign
        authorization = self.headers.get('Authorization')
        accepted = authorization is None if foreign else authorization == expected
        status = 200 if accepted else 403
        location = None
        if accepted and self.path == '/same':
            status, location = 302, '/catalog'
        elif accepted and self.path == '/cross':
            status, location = 302, f'http://127.0.0.1:{other.server_port}/catalog'
        with lock:
            counter += 1
            observed = {
                'method': self.command, 'path': self.path, 'foreign': foreign,
                'authorization': authorization, 'status': status,
            }
            write(f'{counter}.json', {key: value for key, value in observed.items() if value is not None})
        if self.path == '/book.epub' and accepted:
            body, content_type = book.read_bytes(), 'application/epub+zip'
        else:
            body = json.dumps({
                'metadata': {'title': 'Foreign catalog' if foreign else 'Literal password catalog'},
                'links': [],
                'publications': [{
                    'metadata': {'title': 'Synthetic authenticated book'},
                    'links': [{'href': '/book.epub', 'rel': 'http://opds-spec.org/acquisition',
                               'type': 'application/epub+zip'}],
                }],
            }).encode()
            content_type = 'application/opds+json'
        self.send_response(status)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Content-Type', content_type)
        self.send_header('X-Credentials-Fixture', 'synthetic')
        if location:
            self.send_header('Location', location)
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)

    do_GET = serve
    do_HEAD = serve

    def log_message(self, *_args):
        pass


origin = http.server.HTTPServer(('127.0.0.1', 0), Handler)
other = http.server.HTTPServer(('127.0.0.1', 0), Handler)
origin.foreign, other.foreign = False, True
threading.Thread(target=other.serve_forever, daemon=True).start()
write('ready.json', {'port': origin.server_port, 'foreign_port': other.server_port})
signal.alarm(55)
origin.serve_forever()
