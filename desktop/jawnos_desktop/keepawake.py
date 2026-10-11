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
    """Holds the session's idle inhibitors; inhibit/uninhibit are idempotent.

    Two independent mechanisms keep a desktop from going idle, and a session may
    provide either, both, or (rarely) neither:

    * the screensaver/locker -- ``org.freedesktop.ScreenSaver`` (Xfce, MATE,
      Cinnamon, KDE, ...) or GNOME's ``org.gnome.SessionManager``; and
    * the power manager that blanks the display on idle --
      ``org.freedesktop.PowerManagement`` (e.g. xfce4-power-manager).

    Inhibiting only the screensaver left the screen blanking anyway on Xfce, so
    every interface that answers is taken; all of them are released together.
    """

    def __init__(self, app="JawnOS"):
        self.app = app
        # (service, path, interface, uninhibit-method, cookie) per held inhibit
        self._held = []
        self._bus = None

    def _connection(self):
        if self._bus is None:
            self._bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        return self._bus

    def _call(self, service, path, interface, method, variant):
        return self._connection().call_sync(
            service, path, interface, method, variant, None,
            Gio.DBusCallFlags.NONE, 2000, None)

    def inhibit(self, reason="media playing"):
        if self._held:
            return
        # The screensaver/locker: whichever of the two this session provides. The
        # argument variants are built lazily, inside the guard, so a session
        # without one interface falls through to the next instead of dying on it.
        for service, path, interface, unmethod, build in (
            ("org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver",
             "org.freedesktop.ScreenSaver", "UnInhibit",
             lambda: GLib.Variant("(ss)", (self.app, reason))),
            ("org.gnome.SessionManager", "/org/gnome/SessionManager",
             "org.gnome.SessionManager", "Uninhibit",
             lambda: GLib.Variant("(suus)", (self.app, 0, _GNOME_IDLE, reason))),
        ):
            try:
                cookie = self._call(service, path, interface, "Inhibit", build()).unpack()[0]
                self._held.append((service, path, interface, unmethod, cookie))
                break
            except Exception:
                continue
        # The power manager, which is what actually blanks the display on idle.
        # Additive to the screensaver inhibit above.
        try:
            service = "org.freedesktop.PowerManagement"
            path = "/org/freedesktop/PowerManagement"
            cookie = self._call(service, path, service, "Inhibit",
                                GLib.Variant("(s)", (reason,))).unpack()[0]
            self._held.append((service, path, service, "UnInhibit", cookie))
        except Exception:
            pass

    def uninhibit(self):
        for service, path, interface, unmethod, cookie in self._held:
            try:
                self._call(service, path, interface, unmethod, GLib.Variant("(u)", (cookie,)))
            except Exception:
                pass
        self._held = []
