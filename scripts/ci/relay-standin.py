#!/usr/bin/env python3
"""A plain-http stand-in for the Waycar push relay, for the install checks.

    python3 scripts/ci/relay-standin.py [--host 127.0.0.1] [--port 0] [--port-file FILE]

It is the test's own server, never the Host under test: the Host Tools (the
native `waycar`) POST their push and Live Activity requests to the
`relay_url` in notify.json, and this server records them. Standard library
only.

  POST <any path>   records {"url": <path>, "kind": <body.kind or "push">,
                    "body": <parsed body>} and answers 200 {}.
  GET /requests     one compact JSON line per recorded request, oldest first.

--port 0 picks a free port; --port-file receives it once the server listens.
"""
import argparse
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

records = []
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body, content_type):
        data = body.encode()
        self.send_response(status)
        self.send_header("content-type", content_type)
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("content-length") or 0))
        try:
            body = json.loads(raw)
        except ValueError:
            body = None
        kind = body.get("kind", "push") if isinstance(body, dict) else "push"
        line = json.dumps({"url": self.path, "kind": kind, "body": body}, separators=(",", ":"))
        with lock:
            records.append(line)
        self.reply(200, "{}", "application/json")

    def do_GET(self):
        if self.path != "/requests":
            self.reply(404, "", "text/plain")
            return
        with lock:
            text = "".join(line + "\n" for line in records)
        self.reply(200, text, "text/plain")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--port-file")
    args = parser.parse_args()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    if args.port_file:
        with open(args.port_file, "w") as handle:
            handle.write(str(server.server_address[1]))
    server.serve_forever()


if __name__ == "__main__":
    main()
