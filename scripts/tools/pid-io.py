#!/usr/bin/env python3
"""CPU and I/O rates of one process.

Answers: "this PID is hot - is it burning CPU, or is it moving bytes?"
Usage:   pid-io.py PID [WINDOW_SECONDS] [LOG_PATH]
Example: pid-io.py 12345 3 ~/manager.log
Read-only: reads /proc and stat() of the log path.
"""

import os
import sys
import time

if len(sys.argv) < 2:
    print(__doc__.strip(), file=sys.stderr)
    sys.exit(2)

PID = sys.argv[1]
WINDOW = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0
LOG = sys.argv[3] if len(sys.argv) > 3 else os.path.join(os.environ.get("HOME", ""), "manager.log")
HZ = os.sysconf("SC_CLK_TCK")


def cpu_ticks(pid):
    with open("/proc/%s/stat" % pid) as fh:
        line = fh.read()
    idx = line.rfind(")")
    fields = line[idx + 2:].split()
    return int(fields[11]) + int(fields[12])


def io_counters(pid):
    out = {}
    try:
        with open("/proc/%s/io" % pid) as fh:
            for line in fh:
                key, _, value = line.partition(":")
                value = value.strip()
                if value.isdigit():
                    out[key] = int(value)
    except OSError:
        pass
    return out


def log_size(path):
    try:
        return os.stat(path).st_size
    except OSError:
        return 0


try:
    t0 = time.time()
    c0 = cpu_ticks(PID)
    i0 = io_counters(PID)
    l0 = log_size(LOG)
except (OSError, ValueError) as exc:
    print("pid %s: %s" % (PID, exc), file=sys.stderr)
    sys.exit(1)

time.sleep(WINDOW)

dt = time.time() - t0
dc = cpu_ticks(PID) - c0
i1 = io_counters(PID)
dl = log_size(LOG) - l0

print("pid %s over %.2fs" % (PID, dt))
print("cpu: %.1f%% of one core (user+sys ticks %d)" % (dc * 100.0 / (dt * HZ), dc))
print("read:  %d B (%.0f B/s)" % (i1.get("rchar", 0) - i0.get("rchar", 0),
                                 (i1.get("rchar", 0) - i0.get("rchar", 0)) / dt))
print("write: %d B (%.0f B/s)" % (i1.get("wchar", 0) - i0.get("wchar", 0),
                                 (i1.get("wchar", 0) - i0.get("wchar", 0)) / dt))
print("%s grew %d B (%.0f B/s)" % (LOG, dl, dl / dt))
