#!/usr/bin/env python3
"""Unix-socket echo server standing in for herdr's API socket."""

import os
import socket
import sys
import threading


def serve(connection: socket.socket) -> None:
    with connection:
        while True:
            data = connection.recv(65536)
            if not data:
                return
            connection.sendall(data)


def main() -> None:
    path = sys.argv[1]
    if os.path.exists(path):
        os.unlink(path)
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(path)
    listener.listen(64)
    print("ready", flush=True)
    while True:
        connection, _ = listener.accept()
        threading.Thread(target=serve, args=(connection,), daemon=True).start()


if __name__ == "__main__":
    main()
