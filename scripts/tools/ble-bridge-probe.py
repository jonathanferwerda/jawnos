#!/usr/bin/env python3
"""Time the BLE bridge read loop: is select() returning immediately (a spin)?

Answers: "does `jawn-bt listen` actually block between events, or does it
busy-spin on a socket that is always readable?"
Usage:   ble-bridge-probe.py [--host H] [--port P] [--seconds N] [--timeout T]
                             [--cmd JSON]
Example: ble-bridge-probe.py --seconds 6
Read-only: opens one TCP connection and sends one status request.
"""

import argparse
import json
import select
import socket
import sys
import time


def main():
    ap = argparse.ArgumentParser(add_help=True, description=__doc__.splitlines()[0])
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=45999)
    ap.add_argument("--seconds", type=float, default=6.0)
    ap.add_argument("--timeout", type=float, default=0.2)
    ap.add_argument("--cmd", default='{"cmd":"status"}')
    args = ap.parse_args()

    sock = socket.create_connection((args.host, args.port), timeout=2)
    sock.setblocking(False)
    sock.sendall((args.cmd + "\n").encode())

    buf = b""
    iterations = 0
    fast = 0
    printed = 0
    end = time.time() + args.seconds

    while time.time() < end:
        t0 = time.time()
        ready, _, _ = select.select([sock], [], [], args.timeout)
        dt = time.time() - t0
        iterations += 1
        if dt < 0.05:
            fast += 1
        if printed < 12:
            print("iter %d select %.4fs ready=%d" % (iterations, dt, len(ready)))
            printed += 1
        if not ready:
            continue
        try:
            chunk = sock.recv(65536)
        except BlockingIOError:
            continue
        print("  read got=%s err=%s" % (len(chunk) if chunk else 0, "none"))
        if not chunk:
            break
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            if printed < 40:
                print("  line len %d" % len(line))

    print("iterations=%d fast=%d leftover=%d" % (iterations, fast, len(buf)))
    sock.close()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except OSError as exc:
        print("connect failed: %s" % exc, file=sys.stderr)
        sys.exit(1)
