#!/usr/bin/env python3
"""Loopback TCP proxy that adds a fixed one-way propagation delay.

Each chunk is delivered `--delay-ms` after it arrived, in order, without
serializing the delay: two packets sent back to back still arrive back to
back. That is what makes round trips countable from wall-clock time, which
scripts/fixtures/weak-network-proxy.py (a per-chunk sleep) does not model.
Prints the listen port on stdout once ready.
"""

import argparse
import collections
import socket
import threading
import time


def pump(source: socket.socket, destination: socket.socket, delay: float) -> None:
    queue: collections.deque = collections.deque()
    ready = threading.Condition()
    closed = [False]

    def deliver() -> None:
        while True:
            with ready:
                while not queue and not closed[0]:
                    ready.wait()
                if not queue:
                    break
                due, chunk = queue.popleft()
            pause = due - time.monotonic()
            if pause > 0:
                time.sleep(pause)
            try:
                destination.sendall(chunk)
            except OSError:
                return
        try:
            destination.shutdown(socket.SHUT_WR)
        except OSError:
            pass

    threading.Thread(target=deliver, daemon=True).start()
    while True:
        try:
            chunk = source.recv(65536)
        except OSError:
            chunk = b""
        with ready:
            if chunk:
                queue.append((time.monotonic() + delay, chunk))
            else:
                closed[0] = True
            ready.notify()
        if not chunk:
            return


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target-port", type=int, required=True)
    parser.add_argument("--delay-ms", type=float, required=True)
    arguments = parser.parse_args()
    delay = arguments.delay_ms / 1000

    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(16)
    print(listener.getsockname()[1], flush=True)
    while True:
        client, _ = listener.accept()
        upstream = socket.create_connection(("127.0.0.1", arguments.target_port))
        for sock in (client, upstream):
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        threading.Thread(target=pump, args=(client, upstream, delay), daemon=True).start()
        threading.Thread(target=pump, args=(upstream, client, delay), daemon=True).start()


if __name__ == "__main__":
    main()
