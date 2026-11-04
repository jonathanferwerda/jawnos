#!/usr/bin/env python3
"""Timestamped serial console reader for a bridge board.

Answers: "what is the board printing, and when?" - useful when a BLE bridge
stalls, and a plain cat/stty shows nothing because the board's USB-CDC waits
for DTR.
Usage:   serial-watch.py [PORT] [SECONDS] [reset]
Example: serial-watch.py /dev/ttyACM0 30 reset
Read-only: reads the serial port; `reset` toggles DTR/RTS to reboot the board.
"""

import fcntl
import os
import struct
import sys
import termios
import time

port = sys.argv[1] if len(sys.argv) > 1 else "/dev/ttyACM0"
seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 10.0
reset = len(sys.argv) > 3 and sys.argv[3] == "reset"

fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
attrs = termios.tcgetattr(fd)
attrs[0] = attrs[0] & ~(termios.IGNBRK | termios.BRKINT | termios.PARMRK |
                        termios.ISTRIP | termios.INLCR | termios.IGNCR |
                        termios.ICRNL | termios.IXON)
attrs[1] = attrs[1] & ~termios.OPOST
attrs[2] = attrs[2] & ~(termios.CSIZE | termios.PARENB)
attrs[2] = attrs[2] | termios.CS8 | termios.CREAD | termios.CLOCAL
attrs[3] = attrs[3] & ~(termios.ECHO | termios.ECHONL | termios.ICANON |
                        termios.ISIG | termios.IEXTEN)
attrs[4] = termios.B115200
attrs[5] = termios.B115200
termios.tcsetattr(fd, termios.TCSANOW, attrs)

# Assert DTR/RTS so the board gives us its console.
bits = fcntl.ioctl(fd, termios.TIOCMGET, b"\x00" * 4)
val = struct.unpack("I", bits)[0]
if reset:
    val &= ~termios.TIOCM_DTR
    val |= termios.TIOCM_RTS
    fcntl.ioctl(fd, termios.TIOCMSET, struct.pack("I", val))
    time.sleep(0.15)
val |= termios.TIOCM_DTR | termios.TIOCM_RTS
fcntl.ioctl(fd, termios.TIOCMSET, struct.pack("I", val))

deadline = time.time() + seconds
while time.time() < deadline:
    try:
        chunk = os.read(fd, 4096)
        if chunk:
            sys.stdout.write(chunk.decode("utf-8", "replace"))
            sys.stdout.flush()
    except BlockingIOError:
        time.sleep(0.05)
    except OSError:
        time.sleep(0.05)
os.close(fd)
