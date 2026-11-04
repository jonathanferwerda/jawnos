#!/usr/bin/env python3
"""Per-process CPU from /proc over a short window.

Answers: "which process is burning a core right now?"
Usage:   cpuspy.py [SECONDS] [TOP]
Example: cpuspy.py 3 15
Read-only: reads /proc only.
"""

import os
import sys
import time

WINDOW = float(sys.argv[1]) if len(sys.argv) > 1 else 3.0
TOP = int(sys.argv[2]) if len(sys.argv) > 2 else 20
HZ = os.sysconf("SC_CLK_TCK")  # 100 on Android


def snap():
    out = {}
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % name) as fh:
                line = fh.read()
            idx = line.rfind(")")
            if idx < 0:
                continue
            fields = line[idx + 2:].split()
            cpu = int(fields[11]) + int(fields[12])
            with open("/proc/%s/cmdline" % name, "rb") as fh:
                cmd = fh.read().replace(b"\0", b" ").decode("utf-8", "replace").strip()
        except (OSError, ValueError, IndexError):
            continue
        # Trim the Termux/Android install prefix so rows stay readable.
        cmd = cmd.replace("/data/data/com.jawnos/files/home/jawnos/", "")
        out[name] = {"cpu": cpu, "cmd": cmd}
    return out


before = snap()
time.sleep(WINDOW)
after = snap()

rows = []
for pid, now in after.items():
    was = before.get(pid)
    if not was:
        continue
    delta = now["cpu"] - was["cpu"]
    if delta <= 0:
        continue
    rows.append([delta * 100.0 / (WINDOW * HZ), pid, now["cmd"]])
rows.sort(key=lambda r: -r[0])

print("cpu window=%ss  processes burning: %d" % (WINDOW, len(rows)))
shown = rows[:TOP]
for pct, pid, cmd in shown:
    print("%6.1f%%  pid %-7s %s" % (pct, pid, cmd[:150]))
total_shown = sum(r[0] for r in shown)
total_all = sum(r[0] for r in rows)
print("sum of top shown: %.1f%%   sum all processes: %.1f%%   (10 cores = 1000%%)"
      % (total_shown, total_all))
