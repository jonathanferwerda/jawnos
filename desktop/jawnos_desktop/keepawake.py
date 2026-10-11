"""Inhibit the desktop's idle screen-saver while media is playing.

Cross-desktop: it tries the freedesktop ``org.freedesktop.ScreenSaver`` interface
first (Xfce, GNOME, KDE, Cinnamon, MATE all provide it), then GNOME's
``org.gnome.SessionManager`` as a fallback. When neither is present it quietly
no-ops, so a bare session never breaks the app.

Like the WebKit env overrides, this is kept apart from the UI so it can be
reasoned about (and tested) on its own.
"""

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

# org.gnome.SessionManager inhibit flags: 8 == inhibit the idle (screensaver) timer.
_GNOME_IDLE = 8


class ScreensaverInhibitor:
    """Holds at most one inhibitor cookie; inhibit/uninhibit are idempotent."""

    def __init__(self, app="JawnOS"):
        self.app = app
        self._cookie = None
        self._bus = None
        self._kind = None

    def _connection(self):
        if self._bus is None:
            self._bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        return self._bus

    def inhibit(self, reason="media playing"):
        if self._cookie is not None:
            return
        bus = self._connection()
        for kind, service, path, iface, method, variant in (
            ("freedesktop", "org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver",
             "org.freedesktop.ScreenSaver", "Inhibit", GLib.Variant("(ss)", (self.app, reason))),
            ("gnome", "org.gnome.SessionManager", "/org/gnome/SessionManager",
             "org.gnome.SessionManager", "Inhibit", GLib.Variant("(susu)", (self.app, 0, _GNOME_IDLE, reason))),
        ):
            try:
                result = bus.call_sync(service, path, iface, method, variant,
                                       None, Gio.DBusCallFlags.NONE, 2000, None)
                self._cookie = result.unpack()[0]
                self._kind = kind
                return
            except Exception:
                continue
        self._cookie = None

    def uninhibit(self):
        if self._cookie is None:
            return
        bus = self._connection()
        try:
            if self._kind == "gnome":
                bus.call_sync("org.gnome.SessionManager", "/org/gnome/SessionManager",
                              "org.gnome.SessionManager", "Uninhibit",
                              GLib.Variant("(u)", (self._cookie,)),
                              None, Gio.DBusCallFlags.NONE, 2000, None)
            else:
                bus.call_sync("org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver",
                              "org.freedesktop.ScreenSaver", "UnInhibit",
                              GLib.Variant("(u)", (self._cookie,)),
                              None, Gio.DBusCallFlags.NONE, 2000, None)
        except Exception:
            pass
        self._cookie = None
        self._kind = None
