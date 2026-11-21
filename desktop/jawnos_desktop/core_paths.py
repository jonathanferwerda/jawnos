"""Filesystem paths for the desktop supervisor.

Linux follows the XDG base-directory spec and takes the user's home from
``os.path.expanduser("~")``. Windows keeps the same shape under its own roots:

* Linux: ``$XDG_CONFIG_HOME/jawnos`` and ``$XDG_STATE_HOME/jawnos``.
* Windows: ``%APPDATA%\\JawnOS`` and ``%LOCALAPPDATA%\\JawnOS\\state``.
* macOS (P2): ``~/Library/Application Support/JawnOS``.

The boot id separates a stop from a later login on Linux via
``/proc/sys/kernel/random/boot_id`` and on Windows via the boot epoch derived
from ``GetTickCount64``. Both are the same string for every process in one boot
and a different string after a reboot.
"""

import os
import time

from . import DESKTOP_DIR

IS_WINDOWS = os.name == "nt"

DEFAULT_DIRNAME = "jawnos"


def home():
    return os.path.expanduser("~")


def _xdg(env, default):
    value = os.environ.get(env)
    if value:
        return value
    return os.path.join(home(), default)


def _appdata():
    """``%APPDATA%`` (roaming), with a profile-shaped fallback."""
    value = os.environ.get("APPDATA")
    if value:
        return value
    return os.path.join(home(), "AppData", "Roaming")


def _local_appdata():
    """``%LOCALAPPDATA%`` (this machine), with a profile-shaped fallback."""
    value = os.environ.get("LOCALAPPDATA")
    if value:
        return value
    return os.path.join(home(), "AppData", "Local")


def config_dir():
    if IS_WINDOWS:
        return os.path.join(_appdata(), "JawnOS")
    return os.path.join(_xdg("XDG_CONFIG_HOME", ".config"), "jawnos")


def state_dir():
    if IS_WINDOWS:
        return os.path.join(_local_appdata(), "JawnOS", "state")
    return os.path.join(_xdg("XDG_STATE_HOME", ".local/state"), "jawnos")


def data_dir():
    """The per-user data root (XDG on Linux, LOCALAPPDATA on Windows)."""
    if IS_WINDOWS:
        return os.path.join(_local_appdata(), "JawnOS")
    return _xdg("XDG_DATA_HOME", ".local/share")


def settings_path():
    return os.path.join(config_dir(), "desktop.json")


def _windows_boot_id(now=None, tick_ms=None):
    """A boot stamp derived from the boot epoch, stable across processes.

    ``GetTickCount64`` counts milliseconds since the last boot and ``time.time``
    is wall-clock, so their difference is the boot time. Rounding to the minute
    absorbs the sub-second difference between two processes and clock drift; a
    rebuild starts a new boot and therefore a new stamp. ``now`` and ``tick_ms``
    are test seams.
    """
    if tick_ms is None:
        try:
            import ctypes
            tick_ms = ctypes.windll.kernel32.GetTickCount64()
        except Exception:
            return ""
    if now is None:
        now = time.time()
    try:
        return str(int((float(now) - float(tick_ms) / 1000.0) // 60))
    except (TypeError, ValueError, OverflowError):
        return ""


def _boot_id():
    if IS_WINDOWS:
        return _windows_boot_id()
    try:
        with open("/proc/sys/kernel/random/boot_id", "r", encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def held_path():
    """A deliberate Stop is remembered for this boot only.

    The watcher must not resurrect a tree the person stopped, but a stop before
    a reboot should not keep jawn down at the next login either. The Android
    app's ``wantRunning`` has the same lifetime; the boot id gives the desktop
    the equivalent.
    """
    return os.path.join(state_dir(), "held")


def is_held():
    try:
        with open(held_path(), "r", encoding="utf-8") as fh:
            return fh.read().strip() == _boot_id() and bool(_boot_id())
    except OSError:
        return False


def set_held(on):
    if on:
        os.makedirs(state_dir(), exist_ok=True)
        with open(held_path(), "w", encoding="utf-8") as fh:
            fh.write(_boot_id() + "\n")
        return
    try:
        os.remove(held_path())
    except OSError:
        pass


def daemon_path():
    """The BLE bridge daemon that ships beside this package."""
    return os.path.join(DESKTOP_DIR, "jawnos-bt-daemon")


def default_jawn_dir():
    """Prefer the tree this package lives in (a checkout); else the platform's
    default install.

    The package sits at ``<root>/desktop/jawnos_desktop/core.py``, so two
    levels above the package directory is the repo root. The Windows bundle
    ships ``desktop/`` inside ``<install>\\app``, so the same rule finds the
    installed house; the fallback names that install when the package was
    copied somewhere else."""
    root = os.path.dirname(DESKTOP_DIR)
    if os.path.exists(os.path.join(root, "jawn")):
        return root
    if IS_WINDOWS:
        return os.path.join(_local_appdata(), "JawnOS", "app")
    return os.path.join(home(), DEFAULT_DIRNAME)


def jawn_stdout_log_path():
    return os.path.join(state_dir(), "jawn-stdout.log")


def ble_log_path():
    return os.path.join(state_dir(), "jawnos-bt.log")


def ble_pid_path():
    return os.path.join(state_dir(), "jawnos-bt.pid")
