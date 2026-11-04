#!/usr/bin/env python3
"""Find open TCP ports in a range (for example Android wireless debugging).

Answers: "which port on this host is listening?" - Android picks a random
high port for wireless debugging, and the manager's ports can move too.
Usage:   port-scan.py HOST [LO HI] [--timeout S] [--threads N]
Example: port-scan.py 192.0.2.10 30000 50000
Read-only: connect attempts only, no payload. Only scan hosts you own.
"""

import argparse
import queue
import socket
import sys
import threading


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("host")
    ap.add_argument("lo", nargs="?", type=int, default=30000)
    ap.add_argument("hi", nargs="?", type=int, default=50000)
    ap.add_argument("--timeout", type=float, default=0.25)
    ap.add_argument("--threads", type=int, default=200)
    args = ap.parse_args()

    jobs = queue.Queue()
    for port in range(args.lo, args.hi + 1):
        jobs.put(port)

    open_ports = []
    lock = threading.Lock()

    def work():
        while True:
            try:
                port = jobs.get_nowait()
            except queue.Empty:
                return
            sock = socket.socket()
            sock.settimeout(args.timeout)
            try:
                if sock.connect_ex((args.host, port)) == 0:
                    with lock:
                        open_ports.append(port)
            except OSError:
                pass
            finally:
                sock.close()

    threads = [threading.Thread(target=work, daemon=True) for _ in range(args.threads)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    print("open:", sorted(open_ports))
    return 0


if __name__ == "__main__":
    sys.exit(main())
