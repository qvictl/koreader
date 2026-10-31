#!/usr/bin/env python3
"""Loopback-only, non-forwarding proxy for synthetic OPDS credentials."""
import http.server
import json
from pathlib import Path
import sys
import signal
from urllib.parse import urlsplit

root = Path(sys.argv[1])


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
        self.server.counter += 1
        target = urlsplit(self.path)
        # Behave like proxies that reject credentials in absolute-form targets.
        status = 400 if target.username is not None else 200
        observed = {
            'method': self.command, 'target': self.path,
            'host': self.headers.get('Host'),
            'authorization': self.headers.get('Authorization'),
            'proxy_authorization': self.headers.get('Proxy-Authorization'),
        }
        write(str(self.server.counter) + '.json',
              {key: value for key, value in observed.items() if value is not None})
        body = json.dumps({'metadata': {'title': 'Synthetic proxy catalog'},
                           'links': [], 'publications': []}).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/opds+json')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('X-Proxy-Fixture', 'synthetic')
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)

    do_GET = serve
    do_HEAD = serve

    def log_message(self, *_args):
        pass


server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
server.counter = 0
server.timeout = 5
write('ready.json', {'port': server.server_port})
signal.alarm(40)  # Bound lifetime even if the emulator is terminated before cleanup.
server.serve_forever()
