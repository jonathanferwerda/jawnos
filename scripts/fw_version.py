"""Put the house version into every firmware build.

PlatformIO runs this before compiling (each project registers it in
platformio.ini). JAWN_FW_VERSION is what the device reports back in its
state_request and /device_query reply, so the manager can tell which build a
board is running and whether the image it holds is newer.

The tool walks up from the project directory to the checkout that owns VERSION,
so jp/alarmclock (two levels down) and jt/jw (one level down) all find it.
"""
import os

Import("env")


def house_version(project_dir):
    here = os.path.abspath(project_dir)
    for _ in range(4):
        candidate = os.path.join(here, "VERSION")
        if os.path.isfile(candidate):
            with open(candidate) as fh:
                return fh.read().strip()
        here = os.path.dirname(here)
    return "unknown"


version = house_version(env.subst("$PROJECT_DIR"))
env.Append(BUILD_FLAGS=[f'-DJAWN_FW_VERSION=\\"{version}\\"'])
print(f"[fw_version] {version}")
