#!/usr/bin/env python3
"""A fake upstream for source tests (stdlib only): replays a recording, so no test needs a real Uptime Kuma or
Proxmox. Binds 127.0.0.1 only.

    python3 server/fake_upstream.py server/recordings/example/normal.json [--port 8795]

A recording is server/recordings/<type>/<case>.json, made up or scrubbed (no real hosts, keys, names or IPs):

    {"_about": "what it is, and the upstream version its shape comes from",
     "routes": {
       "GET /api/status": {"status": 200, "json": {...}},
       "GET /api/other?page=2": {"body": "plain text", "headers": {"Content-Type": "text/plain"}},
       "POST /api/auth": {"status": 200, "json": {...}, "delay": 0.5, "pad": 9437184}
     }}

Per route: `status` (200), `json` or `body` (text), `headers`, `delay` (seconds before the answer), `pad` (append
that many spaces to the body: a large answer without a large file). A route with a query matches only that query; one
without matches any query. Unknown routes answer 404. `requests` lists what came in (method, path, headers, body),
so tests can check that the key was sent and nothing else.
"""

import argparse
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def load(recording):
    """A recording from a path or a dict; returns its routes."""
    if isinstance(recording, str):
        with open(recording, encoding="utf-8") as fh:
            recording = json.load(fh)
    routes = recording.get("routes")
    if not isinstance(routes, dict):
        raise ValueError("a recording needs a \"routes\" object")
    return routes


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _answer(self):
        server = self.server
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length > 0 else b""
        with server.lock:
            server.requests.append({"method": self.command, "path": self.path, "headers": dict(self.headers),
                                    "body": body.decode("utf-8", "replace")})
        path, _, query = self.path.partition("?")
        route = server.routes.get("%s %s" % (self.command, self.path)) if query else None
        if route is None:
            route = server.routes.get("%s %s" % (self.command, path))
        if route is None:
            route = {"status": 404, "json": {"error": "not in the recording"}}
        if route.get("delay"):
            time.sleep(float(route["delay"]))
        if "json" in route:
            data = json.dumps(route["json"]).encode("utf-8")
            ctype = "application/json"
        else:
            data = str(route.get("body", "")).encode("utf-8")
            ctype = "text/plain; charset=utf-8"
        if route.get("pad"):
            data += b" " * int(route["pad"])
        try:
            self.send_response(int(route.get("status", 200)))
            headers = {"Content-Type": ctype}
            headers.update(route.get("headers") or {})
            for k, v in headers.items():
                self.send_header(k, str(v))
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (ConnectionError, OSError):
            pass   # the client gave up (a timeout test)

    do_GET = do_POST = do_PUT = do_DELETE = _answer


class FakeUpstream(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, recording, port=0):
        self.routes = load(recording)
        self.requests = []
        self.lock = threading.Lock()
        super().__init__(("127.0.0.1", port), _Handler)

    @property
    def url(self):
        return "http://127.0.0.1:%d" % self.server_address[1]

    def handle_error(self, request, client_address):
        pass

    def start(self):
        threading.Thread(target=self.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True).start()
        return self

    def stop(self):
        self.shutdown()
        self.server_close()

    def __enter__(self):
        return self.start()

    def __exit__(self, *exc):
        self.stop()


def main(argv=None):
    ap = argparse.ArgumentParser(description="Replay a recorded upstream API on 127.0.0.1.")
    ap.add_argument("recording", help="server/recordings/<type>/<case>.json")
    ap.add_argument("--port", type=int, default=8795)
    args = ap.parse_args(argv)
    httpd = FakeUpstream(args.recording, args.port)
    sys.stderr.write("replaying %s on %s\n" % (args.recording, httpd.url))
    try:
        httpd.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
