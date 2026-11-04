#!/usr/bin/env python3
"""Fake BLE bridge for testing `jawn-bt listen` without a device.

Answers: "how does the client behave when the bridge holds, closes, or streams?"
Usage:   ble-mock.py PORT [hold|close|data]
Example: ble-mock.py 45998 hold
Modes:   hold  - accept the connection and stay silent
         close - accept, then close immediately
         data  - emit a status event every second (up to 120)
Read-only: binds a local port; writes nothing.
"""

import socket
import sys
import time

if len(sys.argv) < 2:
    print(__doc__.strip(), file=sys.stderr)
    sys.exit(2)

port = int(sys.argv[1])
mode = sys.argv[2] if len(sys.argv) > 2 else "hold"

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", port))
server.listen(5)
print("mock %s on %d" % (mode, port))

try:
    while True:
        conn, _ = server.accept()
        if mode == "close":
            conn.close()
            continue
        count = 0
        while True:
            if mode == "data":
                conn.sendall(b'{"event":"status","connected":false,"count":0,"links":[]}\n')
            time.sleep(1)
            count += 1
            if count > 120:
                break
        conn.close()
except KeyboardInterrupt:
    pass
finally:
    server.close()
