"""Login autostart for the BLE bridge.

Linux (today) writes an XDG ``.desktop`` file under
``$XDG_CONFIG_HOME/autostart``, the desktop analogue of the Android boot
receiver. The platform branch points the macOS and Windows lanes fill in P2/P3
are:

* ``sys.platform == "darwin"``: a LaunchAgent plist under
  ``~/Library/LaunchAgents`` instead of the XDG unit.
* ``os.name == "nt"``: a Startup-folder shortcut or an
  ``HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run`` value.

Only the Linux implementation exists. The unit text and the three functions
are the seam; the daemon and log paths come from ``core_paths`` so a port only
has to replace this file.
"""

import os
import sys

from .core_paths import _xdg, ble_log_path, daemon_path


def autostart_path():
    return os.path.join(_xdg("XDG_CONFIG_HOME", ".config"), "autostart", "jawnos-bt.desktop")


def autostart_enabled():
    return os.path.exists(autostart_path())


def set_autostart(enabled):
    path = autostart_path()
    if not enabled:
        for candidate in (path, path.replace("jawnos-bt.desktop", "jawnos-desktop.desktop")):
            try:
                os.remove(candidate)
            except OSError:
                pass
        return not autostart_enabled()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(_AUTOSTART_UNIT.format(
            daemon=daemon_path(),
            log=ble_log_path(),
            python=sys.executable,
        ))
    return True


_AUTOSTART_UNIT = """[Desktop Entry]
Type=Application
Name=JawnOS BLE bridge
Comment=Start the JawnOS Bluetooth LE bridge at login
Exec={python} "{daemon}"
Icon=jawnos
Terminal=false
Hidden=false
X-GNOME-Autostart-enabled=true
"""
