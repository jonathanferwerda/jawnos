"""JawnOS desktop: the Linux port of the JawnOS Android app.

The Android app is two things -- a supervisor that starts and stops the jawn
Perl tree, and a Bluetooth LE bridge for the watches. This package is the same
two things on a desktop:

    jawnos_desktop.core   the supervisor (start/stop/restart, ports, settings)
    jawnos_desktop.bridge the toolkit-neutral page bridge (app key, scripts)
    jawnos_desktop.ble    the BLE bridge (BlueZ over D-Bus)
    jawnos_desktop.cli    the ``jawnosctl`` command line
    jawnos_desktop.qt_shell  the default ``jawnos-desktop`` view (Qt WebEngine)
    jawnos_desktop.qt_panel  the Qt control panel (the admin window)
    jawnos_desktop.shell  the Qt session bar

Only ``core`` and ``bridge`` are meant to be portable; ``ble``, ``qt_shell``
and ``shell`` are Linux-specific.
"""

import os

# Qt auto-selects its GTK platform theme on XFCE/GNOME, which maps libgtk-3
# into every Qt process. The desktop is Qt only now, so ask for a non-GTK
# theme; an explicit choice from the user still wins.
os.environ.setdefault("QT_QPA_PLATFORMTHEME", "generic")

__version__ = "0.1.0"

# .../desktop/jawnos_desktop/
PKG_DIR = os.path.dirname(os.path.abspath(__file__))
# .../desktop/
DESKTOP_DIR = os.path.dirname(PKG_DIR)

__all__ = ["core", "bridge", "ble", "cli", "qt_shell", "qt_panel", "shell", "__version__", "PKG_DIR", "DESKTOP_DIR"]
