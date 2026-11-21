"""Login autostart for the BLE bridge.

Linux writes an XDG ``.desktop`` file under ``$XDG_CONFIG_HOME/autostart``, the
desktop analogue of the Android boot receiver. Windows has no BLE bridge yet
(it is a BlueZ D-Bus central), so the three functions are a no-op there; the
Windows installer owns the house's own login item instead. macOS (P2) will use
a LaunchAgent plist.
"""

import os
import sys

from .core_paths import _xdg, ble_log_path, daemon_path

IS_WINDOWS = os.name == "nt"


def autostart_path():
    if IS_WINDOWS:
        base = os.environ.get("APPDATA")
        if not base:
            base = os.path.join(os.path.expanduser("~"), "AppData", "Roaming")
        return os.path.join(base, "Microsoft", "Windows", "Start Menu",
                            "Programs", "Startup", "JawnOS BLE bridge.lnk")
    return os.path.join(_xdg("XDG_CONFIG_HOME", ".config"), "autostart", "jawnos-bt.desktop")


def autostart_enabled():
    if IS_WINDOWS:
        return False
    return os.path.exists(autostart_path())


def set_autostart(enabled):
    if IS_WINDOWS:
        # Nothing to write: the Windows package has no BLE daemon, and the
        # installer's startup entry is the house's own login item.
        return True
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
