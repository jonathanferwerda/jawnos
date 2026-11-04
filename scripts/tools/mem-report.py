#!/usr/bin/env python3
"""RSS/PSS by process category, and by PURPOSE for JawnOS workers.

Answers: "where is the memory going, and which purpose is growing?"
Usage:   mem-report.py
Example: mem-report.py
Read-only: reads /proc/<pid>/status, smaps_rollup, environ and cmdline.
The "jawnos" category recognises President.pl / Manager.pl / Websocket.pl; the
other categories are conveniences and can be edited for another machine.
"""

import glob
import os
from collections import defaultdict


def read_status(pid):
    rss = pss = 0
    try:
        with open("/proc/%s/status" % pid) as fh:
            for line in fh:
                if line.startswith("VmRSS:"):
                    rss = int(line.split()[1])
        with open("/proc/%s/smaps_rollup" % pid) as fh:
            for line in fh:
                if line.startswith("Pss:"):
                    pss = int(line.split()[1])
    except (OSError, ValueError):
        pass
    return rss, pss


def read_env(pid):
    try:
        raw = open("/proc/%s/environ" % pid, "rb").read().split(b"\0")
        env = {}
        for item in raw:
            if b"=" in item:
                key, value = item.split(b"=", 1)
                env[key.decode(errors="replace")] = value.decode(errors="replace")
        return env
    except OSError:
        return {}


def read_cmd(pid):
    try:
        return open("/proc/%s/cmdline" % pid, "rb").read().replace(
            b"\0", b" ").decode(errors="replace").strip()
    except OSError:
        return ""


categories = [
    ("zed", ("zed-editor",)),
    ("chromium", ("/usr/lib/chromium/",)),
    ("webkit", ("WebKitWebProcess",)),
    ("jawnos", ("President.pl", "Manager.pl", "Websocket.pl")),
    ("desktop", ("jawnos-desktop",)),
]

cat_totals = {name: [0, 0, 0] for name, _ in categories}
jawnos_by_purpose = defaultdict(lambda: [0, 0, 0])
top = []

for path in glob.glob("/proc/[0-9]*"):
    try:
        pid = int(os.path.basename(path))
    except ValueError:
        continue
    cmd = read_cmd(pid)
    if not cmd:
        continue
    rss, pss = read_status(pid)
    if rss == 0:
        continue
    matched = None
    for name, needles in categories:
        if any(needle in cmd for needle in needles):
            matched = name
            break
    if matched:
        cat_totals[matched][0] += 1
        cat_totals[matched][1] += rss
        cat_totals[matched][2] += pss
    if matched == "jawnos":
        purpose = read_env(pid).get("PURPOSE", "?")
        jawnos_by_purpose[purpose][0] += 1
        jawnos_by_purpose[purpose][1] += rss
        jawnos_by_purpose[purpose][2] += pss
    top.append((pss, rss, pid, cmd[:110]))

print("%-10s %3s %9s %9s" % ("category", "n", "RSS MB", "PSS MB"))
for name, (n, rss, pss) in cat_totals.items():
    print("%-10s %3d %9.1f %9.1f" % (name, n, rss / 1024, pss / 1024))
print()
print("%-24s %3s %9s %9s" % ("jawnos purpose", "n", "RSS MB", "PSS MB"))
for purpose, (n, rss, pss) in sorted(jawnos_by_purpose.items(), key=lambda kv: -kv[1][2]):
    print("%-24s %3d %9.1f %9.1f" % (purpose, n, rss / 1024, pss / 1024))
print()
print("top processes by PSS")
for pss, rss, pid, cmd in sorted(top, reverse=True)[:15]:
    print("%8d %8.1f %8.1f  %s" % (pid, rss / 1024, pss / 1024, cmd))
