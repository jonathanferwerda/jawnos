"""JawnOS desktop: the Linux port of the JawnOS Android app.

The Android app is two things -- a supervisor that starts and stops the jawn
Perl tree, and a Bluetooth LE bridge for the watches. This package is the same
two things on a desktop:

    jawnos_desktop.core   the supervisor (start/stop/restart, ports, settings)
    jawnos_desktop.ble    the BLE bridge (BlueZ over D-Bus)
    jawnos_desktop.cli    the ``jawnosctl`` command line
    jawnos_desktop.ui     the ``jawnos-desktop`` GTK dashboard

Only ``core`` is meant to be portable; ``ble`` and ``ui`` are Linux-specific.
"""

import os

__version__ = "0.1.0"

# .../desktop/jawnos_desktop/
PKG_DIR = os.path.dirname(os.path.abspath(__file__))
# .../desktop/
DESKTOP_DIR = os.path.dirname(PKG_DIR)

__all__ = ["core", "ble", "cli", "ui", "__version__", "PKG_DIR", "DESKTOP_DIR"]
