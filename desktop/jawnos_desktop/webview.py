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
from urllib.parse import urlparse

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("WebKit2", "4.1")
from gi.repository import Gdk, GLib, Gtk, WebKit2  # noqa: E402

from . import DESKTOP_DIR, core, keepawake  # noqa: E402


# One shared context so the session cookie survives window closes and reloads.
_context = None


def _apply_webkit_env():
    """Apply optional WebKit environment overrides from webkit.env.

    WebKit reads these at initialisation, so they have to be in the environment
    before the first WebView is made. The file (one KEY=VALUE per line, '#'
    comments) is an escape hatch for rendering and video tuning without editing
    code -- e.g. WEBKIT_DISABLE_DMABUF_RENDERER=1 on a driver that mishandles
    the DMABUF renderer. Existing environment variables always win."""
    path = os.path.join(core.config_dir(), "webkit.env")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            lines = fh.readlines()
    except OSError:
        return
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip())


_apply_webkit_env()


def _context_get():
    global _context
    if _context is None:
        _context = WebKit2.WebContext.get_default()
        # Cache like a desktop browser, not a viewer (the default is the minimal
        # document-viewer model). A heavy page -- the music library fires a
        # thumbnail request per song -- then comes mostly from disk on the next
        # visit instead of being fetched again.
        try:
            _context.set_cache_model(WebKit2.CacheModel.DOCUMENT_BROWSER)
        except Exception:
            pass
    return _context


def manager_url(jawn_dir, ticket=None):
    """Where the manager lives -- on the host the login happened on.

    jawn mints a ticket for the machine's ``domain`` (e.g.
    ``https://oldtop.example.com:3000/box_office/..``), and its ``/box_office``
    route redirects to ``https://<that host>:<working port>/manager``. The
    session cookie is scoped to that host, so the manager must be loaded from it
    too: navigating on to the loopback address is a *different origin* with no
    cookie, which shows the login gate. Fall back to loopback when there is no
    ticket to read a host from (a plain local launch)."""
    port = core.jawn_working_port(jawn_dir)
    if ticket:
        try:
            host = urlparse(ticket).hostname or "127.0.0.1"
        except ValueError:
            host = "127.0.0.1"
    else:
        host = core.manager_host()
    return "https://%s:%d/manager" % (host, port)


def _js_string(result):
    """The JS value a script-message handler received, as text.

    WebKit2's signal passes a WebKitJavascriptResult (<= 2.39) or a JSCValue
    (>= 2.40); accept either."""
    for getter in ("get_js_value", "get_value"):
        try:
            return getattr(result, getter)().to_string()
        except Exception:
            continue
    try:
        return result.to_string()
    except Exception:
        return ""


def ticket_url():
    """The stored login ticket, if any.

    Prefers the encrypted store (keyring, else a Fernet file); falls back to the
    gitignored live token a checkout may keep in .shots/ticket.txt."""
    try:
        from . import secrets
        stored = secrets.load()
        if stored:
            return stored
    except Exception:
        pass
    root = os.path.dirname(DESKTOP_DIR)
    path = os.path.join(root, ".shots", "ticket.txt")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read().strip() or None
    except OSError:
        return None


class WebViewPanel(Gtk.Box):
    """The embedded JawnOS view: a compact nav strip over the WebView.

    A Gtk.Box, not a window, so it can be the main area of the dashboard (the
    "one app": Dashboard and JawnOS tabs) as well as a window of its own. There
    is deliberately no address bar -- the session comes from the stored ticket,
    so there is no URL for the user to type or read.
    """

    def __init__(self, settings, start_url=None):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.settings_data = settings
        self._fullscreen = False
        # True when the window's fullscreen was asked for by the page (a video),
        # so leaving the video restores it -- but an F11 fullscreen survives.
        self._page_fullscreen = False
        # Set by the dashboard: the page's admin-console icon calls it to come
        # back to the control panel.
        self.on_admin = None
        # Holds the screensaver off while this view is playing media.
        self._inhibitor = keepawake.ScreensaverInhibitor()
        self.connect("destroy", lambda *_: self._inhibitor.uninhibit())

        self.view = WebKit2.WebView.new_with_context(_context_get())
        self._configure(self.view)
        self.pack_start(self.view, True, True, 0)

        # The ticket URL logs in and redirects; loading it and then heading to
        # /manager guarantees the session cookie is set even if the ticket page
        # does not redirect on its own. The manager is addressed on the ticket's
        # own host, where that cookie is scoped (see manager_url). The ticket URL
        # is kept so a gated landing can go through it again for a fresh session.
        login = None if start_url else ticket_url()
        self._login_url = login
        self._manager_url = manager_url(settings["jawn_dir"], start_url or login)
        self._manager_host = urlparse(self._manager_url).hostname or "127.0.0.1"
        self._login_pending = bool(login)
        self._gate_retries = 0
        self.load(start_url or login or self._manager_url)

    # ---- navigation (no toolbar: the start menu's admin icon comes back here,
    # and the notebook's own tabs are always present) ----

    def view_go_back(self):
        if self.view.can_go_back():
            self.view.go_back()

    def view_reload(self):
        self.view.reload()

    def view_home(self):
        self.load(self._manager_url)

    # ---- fullscreen (drives whichever top-level window holds us) ----

    def _set_fullscreen(self, on):
        top = self.get_toplevel()
        if not isinstance(top, Gtk.Window):
            return
        if on:
            top.fullscreen()
        else:
            top.unfullscreen()

    def _toggle_fullscreen(self):
        self._fullscreen = not self._fullscreen
        self._page_fullscreen = False
        self._set_fullscreen(self._fullscreen)

    def attach_keys(self, window):
        """Handle F11 on the window that hosts this panel."""
        window.connect("key-press-event", self._on_key)

    def _on_key(self, _widget, event):
        # F11 is the only way out of the app's fullscreen. Esc must not drop it:
        # Esc belongs to the page (it leaves a video's own fullscreen), and
        # while a video is fullscreen, Esc was taking the whole app with it.
        if event.keyval == Gdk.KEY_F11:
            self._toggle_fullscreen()
            return True
        return False

    def _on_enter_fullscreen(self, _view):
        # A page (a video) asked for fullscreen. Escalate the window only if the
        # app is not already fullscreen, and remember who did it.
        if not self._fullscreen:
            self._page_fullscreen = True
            self._fullscreen = True
            self._set_fullscreen(True)
        return False

    def _on_leave_fullscreen(self, _view):
        # Only undo the window's fullscreen if the page put it there -- leaving a
        # video must not close an F11 fullscreen.
        if self._page_fullscreen:
            self._page_fullscreen = False
            self._fullscreen = False
            self._set_fullscreen(False)
        return False

    def load(self, url):
        self.view.load_uri(url)

    # ---- webkit wiring ----

    def _configure(self, view):
        s = view.get_settings()
        # Ask for the GPU path explicitly. Video and canvas get an accelerated
        # compositing layer either way, but ALWAYS keeps the whole view on it.
        # (Video *decode* is GStreamer's job: without a VA-API plugin such as
        # gst-plugin-va, WebKit falls back to software decode and HD video is
        # choppy however this is set.)
        try:
            s.set_property("hardware-acceleration-policy",
                           WebKit2.HardwareAccelerationPolicy.ALWAYS)
        except Exception:
            pass
        for prop, value in (
            ("enable-media-stream", True),        # getUserMedia: camera + mic
            ("enable-webrtc", True),
            ("enable-media", True),               # HTML5 <audio>/<video>
            ("media-playback-requires-user-gesture", False),  # allow autoplay
            ("enable-geolocation", True),
            ("enable-developer-extras", True),
            ("enable-html5-local-storage", True),
            ("javascript-can-open-windows-automatically", True),
            # Closer to a desktop browser's feel: momentum scroll, a GPU 2d
            # canvas, speculative DNS and the back/forward page cache.
            ("enable-smooth-scrolling", True),
            ("enable-accelerated-2d-canvas", True),
            ("enable-dns-prefetching", True),
            ("enable-page-cache", True),
            ("enable-mediasource", True),
            ("enable-webaudio", True),
        ):
            try:
                s.set_property(prop, value)
            except Exception:
                pass
        # A channel for the page: this view exposes a `jawnos` script-message
        # handler, which the manager's start menu uses to offer a way back to
        # the dashboard. A plain browser has no such handler, so the page hides
        # its icon there.
        try:
            content = view.get_user_content_manager()
            content.register_script_message_handler("jawnos")
            content.connect("script-message-received::jawnos", self._on_message)
        except Exception:
            pass
        view.connect("load-changed", self._on_load_changed)
        view.connect("load-failed-with-tls-errors", self._on_tls_error)
        view.connect("permission-request", self._on_permission)
        # A page (e.g. a video element) asking for fullscreen drives the window.
        view.connect("enter-fullscreen", self._on_enter_fullscreen)
        view.connect("leave-fullscreen", self._on_leave_fullscreen)
        # Hold the screen awake while this view is playing audio or video.
        try:
            view.connect("notify::is-playing-audio", self._on_playing_audio)
        except Exception:
            pass

    def _on_playing_audio(self, view, _param):
        try:
            playing = bool(view.get_property("is-playing-audio"))
        except Exception:
            playing = False
        if playing:
            self._inhibitor.inhibit("media playing")
        else:
            self._inhibitor.uninhibit()

    def _on_load_changed(self, view, event):
        if event != WebKit2.LoadEvent.FINISHED:
            return
        if self._login_pending:
            # WebKit needs a moment to commit the session cookie the ticket set,
            # or the /manager navigation races ahead of it and lands on the
            # login gate ('Gate').
            self._login_pending = False
            GLib.timeout_add(1500, self._after_login)
            return
        # Landing on the gate means the session cookie did not take. Go through
        # the ticket again (which mints a fresh session) rather than re-asking for
        # the manager, which would only gate again.
        if (view.get_title() or "").strip().lower() == "gate" and self._gate_retries < 3:
            self._gate_retries += 1
            GLib.timeout_add(2000, self._retry_login)

    def _after_login(self):
        self.load(self._manager_url)
        return False

    def _retry_login(self):
        if self._login_url:
            self._login_pending = True
        self.load(self._login_url or self._manager_url)
        return False

    # ---- the page -> app channel ----

    def _on_message(self, _content, result):
        if "admin" in _js_string(result) and self.on_admin:
            self.on_admin()
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
        # Granted only for our own manager origin (loopback, or the ticket's
        # host) and nothing else. The origin is taken from the view's current
        # URI: the request objects do not all expose get_origin()
        # (UserMediaPermissionRequest does not), and reading it there raised and
        # silently denied the camera/mic.
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
        try:
            host = urlparse(uri).hostname or ""
        except ValueError:
            host = ""
        allowed = {"127.0.0.1", "localhost", "::1", self._manager_host}
        if host in allowed:
            request.allow()
        else:
            request.deny()
        return True


class WebViewWindow(Gtk.Window):
    """The embedded view on its own, for a one-off or a debug launch."""

    def __init__(self, settings, start_url=None):
        super().__init__(title="JawnOS")
        self.set_default_size(1100, 820)
        self.panel = WebViewPanel(settings, start_url=start_url)
        self.add(self.panel)
        self.panel.attach_keys(self)
        self.show_all()


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
