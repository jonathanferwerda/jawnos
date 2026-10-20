"""Inhibit the desktop's idle screen-saver while media is playing.

Cross-desktop: it tries the freedesktop ``org.freedesktop.ScreenSaver`` interface
first (Xfce, GNOME, KDE, Cinnamon, MATE all provide it), then GNOME's
``org.gnome.SessionManager``, then the power manager's own ``Inhibit`` interface
and systemd-logind's idle block. When none is present it quietly no-ops, so a
bare session never breaks the app.

Like the WebKit env overrides, this is kept apart from the UI so it can be
reasoned about (and tested) on its own.
"""

import os

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

# org.gnome.SessionManager inhibit flags: 8 == inhibit the idle (screensaver) timer.
_GNOME_IDLE = 8


class ScreensaverInhibitor:
    """Holds the session's idle inhibitors; inhibit/uninhibit are idempotent.

    Four independent mechanisms keep a desktop from going idle, and a session may
    provide one, some, or (rarely) none:

    * the screensaver/locker -- ``org.freedesktop.ScreenSaver`` (Xfce, MATE,
      Cinnamon, KDE, ...) or GNOME's ``org.gnome.SessionManager``;
    * the power manager's own ``org.freedesktop.PowerManagement.Inhibit`` object
      (e.g. xfce4-power-manager), which is what blanks the display on idle; and
    * systemd-logind's ``Inhibit('idle', ...)``, honoured by every major desktop.

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
        # The power manager's own inhibitor. The freedesktop spec puts it on a
        # child object, not the core interface: asking the core object (as this
        # did before) raised UnknownMethod and left Xfce blanking the display
        # exactly as the person described.
        try:
            service = "org.freedesktop.PowerManagement"
            path = "/org/freedesktop/PowerManagement/Inhibit"
            interface = "org.freedesktop.PowerManagement.Inhibit"
            cookie = self._call(service, path, interface, "Inhibit",
                                GLib.Variant("(ss)", (self.app, reason))).unpack()[0]
            self._held.append((service, path, interface, "UnInhibit", cookie))
        except Exception:
            pass
        # systemd-logind's idle block is the portable last line: every major
        # desktop's power manager honours it, including Xfce's. Inhibit returns a
        # file descriptor that must stay open for the block to last.
        try:
            reply = self._call("org.freedesktop.login1", "/org/freedesktop/login1",
                               "org.freedesktop.login1.Manager", "Inhibit",
                               GLib.Variant("(ssss)", ("idle", self.app, reason, "block")))
            fd = reply.unpack()[0]
            # PyGObject normally unpacks a handle as an int; older builds hand
            # back the GLib.Variant itself.
            if hasattr(fd, "get_handle"):
                fd = fd.get_handle()
            fd = int(fd)
            if fd >= 0:
                self._held.append(("logind", fd, None, None, None))
        except Exception:
            pass

    def uninhibit(self):
        for service, path, interface, unmethod, cookie in self._held:
            if service == "logind":
                try:
                    os.close(cookie)
                except OSError:
                    pass
                continue
            try:
                self._call(service, path, interface, unmethod, GLib.Variant("(u)", (cookie,)))
            except Exception:
                pass
        self._held = []
