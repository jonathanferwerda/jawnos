"""Embed the JawnOS web UI inside the desktop app, using WebKitGTK.

Why WebKitGTK and not the things you may have read about:

* **Chromium DevTools Protocol** (the "endpoint framework") does not embed a
  browser -- it drives a *separate* Chrome process over a socket. You can fake
  an embedded look by positioning a borderless window, but it is not inside
  our app, and it drags a full Chromium around.
* **CEF** (Chromium Embedded Framework) is a real embedded Chromium and is the
  most faithful, but it is a large bundled dependency and there is no binding
  for this Python (3.14) on this machine.
* **WebKitGTK** is the embeddable view that ships with GTK on Linux. It is
  already installed here (2.52) and its ``WebView`` is a normal GTK widget we
  drop into our own window.

Camera, microphone and location all work in WebKitGTK, with two caveats: the
features must be enabled and each origin must be granted permission (both done
here), and capture depends on the distro's GStreamer capture plugins while
location depends on GeoClue. If a site asks for something we do not recognise,
we deny it by default.
"""

import os

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("WebKit2", "4.1")
from gi.repository import GLib, Gtk, Pango, WebKit2  # noqa: E402

from . import DESKTOP_DIR, core  # noqa: E402

# One shared context so the session cookie survives window closes and reloads.
_context = None


def _context_get():
    global _context
    if _context is None:
        _context = WebKit2.WebContext.get_default()
    return _context


def manager_url(jawn_dir):
    return "https://127.0.0.1:%d/manager" % core.jawn_working_port(jawn_dir)


def ticket_url():
    """The live login ticket, if the checkout has one.

    Loading it mints the session cookie and redirects to /manager, so the
    embedded view is logged in without a password. The file is gitignored (it is
    a live token); a plain /manager load is the fallback."""
    root = os.path.dirname(DESKTOP_DIR)
    path = os.path.join(root, ".shots", "ticket.txt")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read().strip() or None
    except OSError:
        return None


class WebViewWindow(Gtk.Window):
    def __init__(self, settings, start_url=None):
        super().__init__(title="JawnOS")
        self.settings_data = settings
        self.set_default_size(1100, 820)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        box.pack_start(self._toolbar(), False, False, 0)

        self.view = WebKit2.WebView.new_with_context(_context_get())
        self._configure(self.view)
        box.pack_start(self.view, True, True, 0)
        self.add(box)

        self._manager_url = manager_url(settings["jawn_dir"])
        # The ticket URL logs in and redirects; loading it and then heading to
        # /manager guarantees the session cookie is set even if the ticket page
        # does not redirect on its own.
        login = None if start_url else ticket_url()
        self._login_pending = bool(login)
        self._gate_retries = 0
        self.load(start_url or login or self._manager_url)
        self.show_all()

    # ---- chrome ----

    def _toolbar(self):
        bar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=4)
        bar.set_border_width(4)
        for label, handler in (("\u2190", self.view_go_back),
                               ("\u21bb", self.view_reload),
                               ("\u2302", self.view_home)):
            button = Gtk.Button(label=label)
            button.set_relief(Gtk.ReliefStyle.NONE)
            button.connect("clicked", lambda _b, h=handler: h())
            bar.pack_start(button, False, False, 0)
        self.url_label = Gtk.Label(xalign=0)
        self.url_label.set_ellipsize(Pango.EllipsizeMode.END)
        bar.pack_start(self.url_label, True, True, 4)
        return bar

    def view_go_back(self):
        if self.view.can_go_back():
            self.view.go_back()

    def view_reload(self):
        self.view.reload()

    def view_home(self):
        self.load(manager_url(self.settings_data["jawn_dir"]))

    def load(self, url):
        self.view.load_uri(url)

    # ---- webkit wiring ----

    def _configure(self, view):
        s = view.get_settings()
        for prop, value in (
            ("enable-media-stream", True),        # getUserMedia: camera + mic
            ("enable-webrtc", True),
            ("enable-media", True),               # HTML5 <audio>/<video>
            ("media-playback-requires-user-gesture", False),  # allow autoplay
            ("enable-geolocation", True),
            ("enable-developer-extras", True),
            ("enable-html5-local-storage", True),
            ("javascript-can-open-windows-automatically", True),
        ):
            try:
                s.set_property(prop, value)
            except Exception:
                pass
        view.connect("load-changed", self._on_load_changed)
        view.connect("load-failed-with-tls-errors", self._on_tls_error)
        view.connect("permission-request", self._on_permission)

    def _on_load_changed(self, view, event):
        try:
            self.url_label.set_text(view.get_uri() or "")
        except Exception:
            pass
        if event != WebKit2.LoadEvent.FINISHED:
            return
        if self._login_pending:
            # WebKit needs a moment to commit the session cookie the ticket set,
            # or the /manager navigation races ahead of it and lands on the
            # login gate ('Gate').
            self._login_pending = False
            GLib.timeout_add(1500, self._after_login)
            return
        # If we still hit the gate (a slow cookie commit), try again a beat later.
        if (view.get_title() or "").strip().lower() == "gate" and self._gate_retries < 2:
            self._gate_retries += 1
            GLib.timeout_add(2000, self._after_login)

    def _after_login(self):
        self.load(self._manager_url)
        return False

    def _on_tls_error(self, view, failing_uri, certificate, errors):
        # jawn serves https with a self-signed certificate on 127.0.0.1; trust
        # it for this host and retry. (A one-off file:// fallback is not needed.)
        host = "127.0.0.1"
        try:
            host = failing_uri.split("/")[2].split(":")[0] or host
        except Exception:
            pass
        try:
            _context_get().allow_tls_certificate_for_host(certificate, host)
        except Exception:
            pass
        view.load_uri(failing_uri)
        return True

    def _on_permission(self, view, request):
        # Granted only for our own loopback origin; anything else is denied.
        # The origin is taken from the view's current URI: the request objects
        # do not all expose get_origin() (UserMediaPermissionRequest does not),
        # and reading it there raised and silently denied the camera/mic.
        uri = ""
        try:
            uri = view.get_uri() or ""
        except Exception:
            pass
        if not uri:
            for attr in ("get_origin", "get_uri"):
                try:
                    value = getattr(request, attr)()
                    uri = value.to_string() if hasattr(value, "to_string") else str(value)
                    break
                except Exception:
                    continue
        if "127.0.0.1" in uri or "localhost" in uri:
            request.allow()
        else:
            request.deny()
        return True


def run_webview(settings=None, start_url=None):
    settings = settings or core.load_settings()
    window = WebViewWindow(settings, start_url=start_url)
    window.present()
    return window


def main(argv=None):
    import argparse
    parser = argparse.ArgumentParser(prog="jawnos-webview",
                                     description="JawnOS UI in an embedded WebKitGTK view")
    parser.add_argument("--url", help="override the start URL")
    args = parser.parse_args(argv)
    run_webview(start_url=args.url)
    Gtk.main()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
