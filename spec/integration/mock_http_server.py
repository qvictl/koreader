#!/usr/bin/env python3
"""Loopback-only HTTP fixture with per-request release gates."""
import http.server
import json
import os
from pathlib import Path
import sys
import threading
import time

root = Path(sys.argv[1])
lock = threading.Lock()
counter = 0


def write(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value), encoding="utf-8")
    temporary.replace(path)


class Handler(http.server.BaseHTTPRequestHandler):
    def serve(self):
        global counter
        with lock:
            counter += 1
            index = counter
        job = root / str(index)
        job.mkdir(exist_ok=True)
        try:
            plan = json.loads((job / "plan.json").read_text())
        except (OSError, ValueError):
            plan = {"status": 500, "body": {"message": "unplanned request"}, "unexpected": True}
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            payload = json.loads(raw) if raw else {}
        except ValueError:
            payload = {}
        safe = {key: payload[key] for key in ("username", "document", "progress", "percentage") if key in payload}
        write(job / "received.json", {"method": self.command, "path": self.path,
              "username": self.headers.get("x-auth-user"), "payload": safe,
              "unexpected": plan.get("unexpected", False)})
        deadline = time.monotonic() + 15
        delayed = plan.get("delay")
        if delayed is not None:
            time.sleep(delayed)
        else:
            while not (job / "release").exists() and time.monotonic() < deadline:
                time.sleep(0.005)
        expired = delayed is None and not (job / "release").exists()
        disconnected = False
        body = json.dumps(plan.get("body", {})).encode()
        try:
            self.send_response(plan.get("status", 200))
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except OSError:
            disconnected = True
        finally:
            write(job / "finished.json", {"expired": expired, "disconnected": disconnected})

    do_GET = serve
    do_PUT = serve
    do_POST = serve

    def log_message(self, *_args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
write(root / "ready.json", {"port": server.server_port, "pid": os.getpid()})
server.serve_forever()
