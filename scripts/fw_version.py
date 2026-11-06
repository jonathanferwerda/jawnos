"""Put a build's own version into the firmware.

PlatformIO runs this before compiling (each project registers it in
platformio.ini). JAWN_FW_VERSION is what the device reports back in its
state_request and /device_query reply, so the manager can tell which build a
board is running and whether the image it holds is newer.

Each firmware project carries its own VERSION - jt/VERSION for the deck,
jw/VERSION for the watch, jp/alarmclock/VERSION for the Pico - so a board's
number moves when that board's firmware changes, not when the house does. The
walk starts at the project directory and climbs, so the project's own VERSION
wins; the checkout's VERSION is the fallback for a tree that predates the split.
"""
import os

Import("env")


def build_version(project_dir):
    here = os.path.abspath(project_dir)
    for _ in range(4):
        candidate = os.path.join(here, "VERSION")
        if os.path.isfile(candidate):
            with open(candidate) as fh:
                return fh.read().strip(), candidate
        here = os.path.dirname(here)
    return "unknown", ""


version, source = build_version(env.subst("$PROJECT_DIR"))
env.Append(BUILD_FLAGS=[f'-DJAWN_FW_VERSION=\\"{version}\\"'])
print(f"[fw_version] {version} ({os.path.relpath(source) if source else 'no VERSION'})")
