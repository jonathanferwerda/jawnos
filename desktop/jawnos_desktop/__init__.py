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

The supervisor, ticket storage, shell command and GPU seam have Windows
branches; ``ble`` and the Wayland session bar remain Linux-only.
"""

import os
import sys

# Qt auto-selects its GTK platform theme on XFCE/GNOME, which maps libgtk-3
# into every Qt process. The desktop is Qt only now, so ask for a non-GTK
# theme on Linux; an explicit choice from the user still wins.
#
# This is deliberately Linux-only. The generic platform-theme plugin is not in
# the Windows Qt build, and asking for it there crashes qwindows.dll with an
# access violation before the first window (VM200, 2026-11-21).
if sys.platform.startswith("linux"):
    os.environ.setdefault("QT_QPA_PLATFORMTHEME", "generic")

__version__ = "0.1.0"

# .../desktop/jawnos_desktop/
PKG_DIR = os.path.dirname(os.path.abspath(__file__))
# .../desktop/
DESKTOP_DIR = os.path.dirname(PKG_DIR)

__all__ = ["core", "bridge", "ble", "cli", "qt_shell", "qt_panel", "shell", "__version__", "PKG_DIR", "DESKTOP_DIR"]
