"""Filesystem paths for the desktop supervisor.

Linux (today) follows the XDG base-directory spec and takes the user's home
from ``os.path.expanduser("~")``. The platform branch points the macOS and
Windows lanes fill in P2/P3 are:

* ``sys.platform == "darwin"``: ``~/Library/Application Support/JawnOS``
  replaces the XDG config and state roots; the boot id comes from
  ``sysctl kern.boottime`` instead of ``/proc``.
* ``os.name == "nt"``: ``%APPDATA%\\JawnOS`` and
  ``%LOCALAPPDATA%\\JawnOS`` replace ``XDG_CONFIG_HOME``/``XDG_STATE_HOME``;
  the boot id comes from the Windows boot time.

Every function here is still the Linux implementation: the names above are the
seam, not a dispatch.
"""

import os

from . import DESKTOP_DIR

DEFAULT_DIRNAME = "jawnos"


def home():
    return os.path.expanduser("~")


def _xdg(env, default):
    value = os.environ.get(env)
    if value:
        return value
    return os.path.join(home(), default)


def config_dir():
    return os.path.join(_xdg("XDG_CONFIG_HOME", ".config"), "jawnos")


def state_dir():
    return os.path.join(_xdg("XDG_STATE_HOME", ".local/state"), "jawnos")


def data_dir():
    """The XDG data root (``$XDG_DATA_HOME``, else ``~/.local/share``)."""
    return _xdg("XDG_DATA_HOME", ".local/share")


def settings_path():
    return os.path.join(config_dir(), "desktop.json")


def _boot_id():
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
    """Prefer the tree this package lives in (a checkout); else ~/jawnos.

    The package sits at ``<root>/desktop/jawnos_desktop/core.py``, so two
    levels above the package directory is the repo root."""
    root = os.path.dirname(DESKTOP_DIR)
    if os.path.exists(os.path.join(root, "jawn")):
        return root
    return os.path.join(home(), DEFAULT_DIRNAME)


def jawn_stdout_log_path():
    return os.path.join(state_dir(), "jawn-stdout.log")


def ble_log_path():
    return os.path.join(state_dir(), "jawnos-bt.log")


def ble_pid_path():
    return os.path.join(state_dir(), "jawnos-bt.pid")
