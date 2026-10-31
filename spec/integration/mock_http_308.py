#!/usr/bin/env python3
"""Loopback-only RSS fixture: 308 with a body, then 301, then a valid feed."""
import http.server
import json
from pathlib import Path
import signal
import sys

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

    def do_GET(self):
        self.server.requests.append(self.path)
        write('requests.json', self.server.requests)
        status, location, content_type = 200, None, 'application/rss+xml'
        if self.path == '/start':
            status, location = 308, '/permanent'
            body = b'not XML: permanent redirect body'
        elif self.path == '/permanent':
            status, location = 301, '/feed'
            body = b'not XML: second redirect body'
        elif self.path == '/feed':
            paragraphs = '&lt;p&gt;The synthetic redirect article remains readable.&lt;/p&gt;' * 80
            body = (f'<?xml version="1.0"?><rss version="2.0"><channel>'
                    f'<title>Permanent redirect fixture</title><item><title>Redirect article</title>'
                    f'<link>http://127.0.0.1:{self.server.server_port}/article</link>'
                    f'<description>{paragraphs}</description></item></channel></rss>').encode()
        elif self.path == '/loop':
            status, location = 308, '/loop'
            body = b'redirect limit reached'
        else:
            status, content_type, body = 404, 'text/plain', b'not found'
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        if location is not None:
            self.send_header('Location', location)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
server.requests = []
write('ready.json', {'port': server.server_port})
signal.alarm(50)
server.serve_forever()
