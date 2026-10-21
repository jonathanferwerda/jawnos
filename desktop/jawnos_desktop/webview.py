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
location depends on GeoClue. Geolocation is granted only on a machine that
really carries a GPS receiver (see :func:`_has_gps`): with none, GeoClue answers
with the ISP's coarse position, which the house disregards, so it is denied.
If a site asks for something we do not recognise, we deny it by default.
"""

import base64
import glob
import json
import os
from urllib.parse import urljoin, urlparse

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("WebKit2", "4.1")
from gi.repository import Gdk, GLib, Gtk, WebKit2  # noqa: E402

from . import DESKTOP_DIR, core, keepawake  # noqa: E402


# One shared context so the session cookie survives window closes and reloads.
_context = None

# Intel Gen9 (Skylake) display IDs. WebKitGTK 2.52 marks
# hardware-acceleration-policy deprecated and ignores it, so the view is always
# GPU-composited. On these GPUs under X11/Xfwm the accelerated backing store
# corrupts the window as soon as another program forces a redraw (the table's
# HD 530 does it), and the corruption stays until the app is restarted. Default
# those machines to the software path; JAWNOS_GPU=1 (environment or
# webkit.env) opts back in.
_SKYLAKE_IDS = frozenset({
    "0x1902", "0x1906", "0x190b", "0x190e",
    "0x1912", "0x1916", "0x191b", "0x191d", "0x191e",
    "0x1921", "0x1923", "0x1926", "0x1927", "0x192a", "0x192b",
    "0x1932", "0x193a", "0x193b", "0x193d",
})


# Report whether the page is playing audio or video. WebKit's
# is-playing-audio only covers sound, so a muted video (or one with a silent
# track) left the desktop's own power manager to blank the display while it
# played. The page posts this to the same `jawnos` handler the key bridge uses;
# _on_message reconciles it with WebKit's own audio flag.
_MEDIA_MONITOR_JS = """
(function () {
    var last = '';
    function mediaState() {
        var audio = false, video = false;
        var els = document.querySelectorAll('audio,video');
        for (var i = 0; i < els.length; i++) {
            var el = els[i];
            if (el.paused || el.ended) { continue; }
            if (el.tagName.toLowerCase() === 'video') { video = true; }
            else { audio = true; }
        }
        return { audio: audio, video: video };
    }
    function report() {
        var s = mediaState();
        var key = (s.audio ? 'a' : '') + (s.video ? 'v' : '');
        if (key === last) { return; }
        last = key;
        try {
            window.webkit.messageHandlers.jawnos.postMessage(JSON.stringify({
                action: 'media_state', audio: s.audio, video: s.video
            }));
        } catch (e) {}
    }
    setInterval(report, 2000);
    ['play', 'playing', 'pause', 'ended', 'emptied'].forEach(function (ev) {
        document.addEventListener(ev, report, true);
    });
    window.addEventListener('load', report);
    report();
})();
"""


def _is_skylake_x11():
    """True on an X11 session whose display is an Intel Skylake GPU.

    Wayland is excluded: its compositor path does not share the X11 backing
    store that corrupts, and the machines that work today use newer Intel GPUs
    or Wayland."""
    if os.environ.get("WAYLAND_DISPLAY"):
        return False
    session = (os.environ.get("XDG_SESSION_TYPE") or "").strip().lower()
    if session and session != "x11":
        return False
    if not os.environ.get("DISPLAY"):
        return False
    for path in glob.glob("/sys/class/drm/card*/device"):
        name = os.path.basename(os.path.dirname(path))
        if not name.startswith("card") or not name[4:].isdigit():
            continue
        try:
            with open(os.path.join(path, "vendor"), "r", encoding="ascii") as fh:
                vendor = fh.read().strip().lower()
            if vendor != "0x8086":
                continue
            with open(os.path.join(path, "device"), "r", encoding="ascii") as fh:
                device = fh.read().strip().lower()
        except OSError:
            continue
        if device in _SKYLAKE_IDS:
            return True
    return False


def _apply_webkit_env():
    """Apply WebKit environment overrides from webkit.env and safe defaults.

    WebKit reads these at initialisation, so they have to be in the environment
    before the first WebView is made. The file (one KEY=VALUE per line, '#'
    comments) is an escape hatch for rendering and video tuning without editing
    code -- e.g. WEBKIT_DISABLE_COMPOSITING_MODE=1 on an X11/Intel driver that
    corrupts the window when another program forces a redraw, or
    WEBKIT_DISABLE_DMABUF_RENDERER=1 on a driver that mishandles the DMABUF
    renderer. Existing environment variables always win over the file.

    The file also wins over the automatic Skylake/X11 fallback below (including
    JAWNOS_GPU=1 to keep the GPU path on such a machine)."""
    values = {}
    path = os.path.join(core.config_dir(), "webkit.env")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            lines = fh.readlines()
    except OSError:
        lines = []
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip()
    real = set(os.environ)
    for key, value in values.items():
        if key not in real:
            os.environ[key] = value
    opt_out = (os.environ.get("JAWNOS_GPU") or "").strip().lower()
    if not opt_out or opt_out in ("0", "false", "no", "off"):
        if _is_skylake_x11():
            os.environ.setdefault("WEBKIT_DISABLE_COMPOSITING_MODE", "1")
            os.environ.setdefault("WEBKIT_SKIA_ENABLE_CPU_RENDERING", "1")


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


def _has_gps(jawn_dir):
    """Whether this machine really carries a GPS receiver.

    A machine with none still gets a position from GeoClue - the ISP's coarse
    one - which the house deliberately disregards, so geolocation is denied
    rather than let that through. Opt in explicitly with ``"gps": true`` in
    config.json (or name the device with ``"gps_device"``); otherwise a running
    gpsd or a receiver named on the USB bus is taken as the tell."""
    try:
        config = core.read_app_config(jawn_dir) if jawn_dir else {}
    except Exception:
        config = {}
    if isinstance(config, dict):
        if config.get("gps"):
            return True
        device = config.get("gps_device")
        if device and os.path.exists(str(device)):
            return True
    for sock in ("/run/gpsd.sock", "/var/run/gpsd.sock"):
        if os.path.exists(sock):
            return True
    try:
        import subprocess
        out = subprocess.run(["lsusb"], capture_output=True, text=True, timeout=3).stdout.lower()
    except Exception:
        out = ""
    return any(mark in out for mark in ("gps", "u-blox", "ublox", "sirf", "globaltop", "quectel"))


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


# ---- the app's own identity -------------------------------------------------
# The manager is app-only: a browser has no key, so it cannot prove it is the
# installed app. This view holds an Ed25519 key of its own (0600 in the config
# dir) and signs the server's challenge with it. The key never leaves this
# process except as a public half, so the page -- and any script running in it
# -- can ask for a signature but cannot copy the key.

def _app_key_path():
    return os.path.join(core.config_dir(), "app_ed25519.pem")


def _app_private_key():
    """Load the desktop app key, creating it at 0600 the first time."""
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

    path = _app_key_path()
    try:
        with open(path, "rb") as fh:
            data = fh.read()
        key = serialization.load_pem_private_key(data, password=None)
        if isinstance(key, Ed25519PrivateKey):
            try:
                os.chmod(path, 0o600)
            except OSError:
                pass
            return key
    except (OSError, ValueError, TypeError):
        pass
    key = Ed25519PrivateKey.generate()
    data = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    os.makedirs(os.path.dirname(path), exist_ok=True)
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        # Another window won the race (or a left-over file is unreadable). Do
        # not recurse: read that file once, and fail loudly if it is not a key.
        with open(path, "rb") as fh:
            return serialization.load_pem_private_key(fh.read(), password=None)
    with os.fdopen(fd, "wb") as fh:
        fh.write(data)
    return key


def _app_public_pem():
    from cryptography.hazmat.primitives import serialization

    return _app_private_key().public_key().public_bytes(
        serialization.Encoding.PEM,
        serialization.PublicFormat.SubjectPublicKeyInfo,
    ).decode("ascii")


def _app_sign_b64(message_b64):
    """Sign the base64 message the page handed over; return base64(raw sig)."""
    raw = base64.b64decode(message_b64 or "")
    return base64.b64encode(_app_private_key().sign(raw)).decode("ascii")


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

    def __init__(self, settings, start_url=None, manager_url_override=None, seed_device_uuid=None):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.settings_data = settings
        # A peer's Manager opens in a window of its own: the URL is already the
        # manager, so it is not rebuilt from the local working port, and the
        # device id is seeded into the peer's own localStorage so its app gate
        # can sign this install in.
        self._manager_url_override = manager_url_override
        self._seed_device_uuid = seed_device_uuid
        self._remote_windows = []
        # A JawnOS manager window may ask the app to open another machine's
        # window. The page-origin check in _on_message keeps a public page from
        # doing it; a peer's manager is still a JawnOS manager, so Go inside a
        # peer window is a legitimate use.
        self._can_open_windows = True
        self._fullscreen = False
        # True when the window's fullscreen was asked for by the page (a video),
        # so leaving the video restores it -- but an F11 fullscreen survives.
        self._page_fullscreen = False
        # Set by the dashboard: the page's admin-console icon calls it to come
        # back to the control panel.
        self.on_admin = None
        # Holds the screensaver off while this view is playing media.
        self._inhibitor = keepawake.ScreensaverInhibitor()
        # Media state from the page's own monitor and from WebKit's audio
        # property; either one holds the screen awake.
        self._js_media = {}
        self._webkit_audio = False
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
        self._manager_url = manager_url_override or manager_url(settings["jawn_dir"], start_url or login)
        self._manager_host = urlparse(self._manager_url).hostname or "127.0.0.1"
        # Geolocation is offered only where there is a real receiver (see _has_gps).
        self._gps = _has_gps(settings.get("jawn_dir"))
        self._login_pending = bool(login)
        self._gate_retries = 0
        # A reload that lands while the tree is restarting (an update, or a
        # restart) hits a closed port; count the retries so it cannot loop.
        self._load_retries = 0
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
        # Keep the documented default for older WebKitGTK releases. 2.52 marks
        # this property deprecated and ignores it (the view is always GPU
        # composited); _apply_webkit_env's Skylake/X11 fallback is what handles
        # the corruption there. Video and canvas still get an accelerated layer
        # where the policy is honoured, but the whole view is not forced onto
        # the GPU.
        try:
            s.set_property("hardware-acceleration-policy",
                           WebKit2.HardwareAccelerationPolicy.ON_DEMAND)
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
            # canvas and speculative DNS. The back/forward page cache is left
            # OFF on purpose: it keeps a whole rendered document alive per
            # history entry, and the manager opens its apps as in-page windows
            # rather than navigating, so there is little to gain and a live DOM
            # to lose. A back press that has to reload is cheap against a
            # permanent copy of the heaviest page.
            #
            # Accelerated 2D canvas stays on: the Skylake/X11 fallback above
            # disables the GPU path there, and other machines benefit from it.
            ("enable-smooth-scrolling", True),
            ("enable-accelerated-2d-canvas", True),
            ("enable-dns-prefetching", True),
            ("enable-page-cache", False),
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
            # At document start the page can see that it is running inside the
            # desktop app. universal.js keys its app login off this, the same
            # way the phone keys off the Android bridge.
            content.add_script(WebKit2.UserScript.new(
                "window.JawnDesktop = window.JawnDesktop || {};",
                WebKit2.UserContentInjectedFrames.TOP_FRAME,
                WebKit2.UserScriptInjectionTime.START,
                None, None,
            ))
            # A peer Manager's page has its own origin and therefore its own
            # localStorage. Seed this install's device id there, so the peer's
            # app-required page can ask this app to sign its login instead of
            # sitting there with no device to name. This window is on this
            # desktop, so this desktop is the client device, even when the
            # Manager it shows belongs to a peer.
            if self._seed_device_uuid:
                content.add_script(WebKit2.UserScript.new(
                    "try { localStorage.setItem('device_uuid', %s); } catch (e) {}"
                    % json.dumps(self._seed_device_uuid),
                    WebKit2.UserContentInjectedFrames.TOP_FRAME,
                    WebKit2.UserScriptInjectionTime.START,
                    None, None,
                ))
            # Tell the app when a video plays, not only when it makes sound.
            content.add_script(WebKit2.UserScript.new(
                _MEDIA_MONITOR_JS,
                WebKit2.UserContentInjectedFrames.TOP_FRAME,
                WebKit2.UserScriptInjectionTime.END,
                None, None,
            ))
        except Exception:
            pass
        view.connect("load-changed", self._on_load_changed)
        view.connect("load-failed", self._on_load_failed)
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
            self._webkit_audio = bool(view.get_property("is-playing-audio"))
        except Exception:
            self._webkit_audio = False
        self._reconcile_inhibitor()

    def _reconcile_inhibitor(self):
        """Hold the screen awake while either the page or WebKit says media plays."""
        media = self._js_media or {}
        if self._webkit_audio or media.get("audio") or media.get("video"):
            self._inhibitor.inhibit("media playing")
        else:
            self._inhibitor.uninhibit()

    def _on_load_changed(self, view, event):
        if event != WebKit2.LoadEvent.FINISHED:
            return
        # a load that reached FINISHED is a good one: let a later drop retry again
        self._load_retries = 0
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

    def _on_load_failed(self, view, event, uri, error):
        # jawn closes its port for a moment on every restart, and a tab that
        # reloads on an update (or the app's own restart) can land in exactly
        # that window. Rather than strand the view on a network error page - the
        # state that forced a trip out to the dashboard and back - wait for the
        # tree to answer and ask for the manager again, a few times, for our own
        # host only. Return True so WebKit does not paint its error page over it.
        #
        # A load we replaced ourselves (a newer navigation cancelled this one)
        # reports as cancelled - WebKitNetworkError 402 - and is not a failure to
        # recover from: retrying it would fight the newer navigation.
        if getattr(error, "code", None) == 402:
            return False
        host = ""
        try:
            host = urlparse(uri).hostname or ""
        except Exception:
            host = ""
        if host and host == self._manager_host and self._load_retries < 6:
            self._load_retries += 1
            GLib.timeout_add(1500, self._retry_load)
            return True
        return False

    def _retry_load(self):
        self.load(self._manager_url)
        return False

    # ---- the page -> app channel ----

    def _on_message(self, _content, result):
        raw = _js_string(result) or ""
        if "admin" in raw and self.on_admin:
            self.on_admin()
            return False
        try:
            message = json.loads(raw)
        except (ValueError, TypeError):
            message = None
        if not isinstance(message, dict):
            return False
        action = message.get("action")
        if action not in ("app_pubkey", "app_sign", "media_state", "open_manager"):
            return False
        if action == "open_manager" and not self._can_open_windows:
            return False
        # Only answer our own origin. A link opened in this view (the public
        # homepage) must not be able to borrow the app's key.
        try:
            host = urlparse(self.view.get_uri() or "").hostname or ""
        except ValueError:
            host = ""
        if host not in (self._manager_host, "127.0.0.1", "localhost", "::1"):
            return False
        if action == "media_state":
            self._js_media = {
                "audio": bool(message.get("audio")),
                "video": bool(message.get("video")),
            }
            self._reconcile_inhibitor()
            return False
        msg_id = message.get("id") or ""
        try:
            if action == "app_pubkey":
                reply = {"ok": True, "pubkey": _app_public_pem(), "kind": "ed25519"}
            elif action == "open_manager":
                args = message.get("args") or {}
                url = args.get("url") or ""
                manager = args.get("manager") or url
                # A ticket can arrive as a path; resolve it against the peer's
                # manager before the new window is given it.
                if url.startswith("/"):
                    base = manager if urlparse(manager).scheme in ("http", "https") else self._manager_url
                    url = urljoin(base, url)
                parsed = urlparse(url)
                if parsed.scheme not in ("https", "http") or not parsed.netloc:
                    raise ValueError("not a manager url")
                mparsed = urlparse(manager)
                if mparsed.scheme not in ("https", "http") or not mparsed.netloc:
                    manager = url
                win = WebViewWindow(
                    self.settings_data,
                    start_url=url,
                    manager_url_override=manager,
                    seed_device_uuid=args.get("device_uuid") or "",
                    title=args.get("name") or "JawnOS Machine",
                )
                self._remote_windows.append(win)
                win.connect("destroy", self._remote_window_closed)
                win.present()
                reply = {"ok": True}
            else:
                args = message.get("args") or {}
                reply = {"ok": True, "signature": _app_sign_b64(args.get("message"))}
        except Exception:
            # No cryptography on this machine, or an unreadable key file. The
            # page then falls back to the open-in-the-app explanation.
            reply = {"ok": False, "error": "unavailable"}
        if action == "open_manager" and not reply.get("ok"):
            reply = {"ok": False, "error": "could not open"}
        try:
            self.view.evaluate_javascript(
                "window.__jawnAppResult && window.__jawnAppResult(%s, %s);"
                % (json.dumps(msg_id), json.dumps(reply)),
                -1, None, None, None, None, None)
        except Exception:
            pass
        return False

    def _remote_window_closed(self, win):
        try:
            if win in self._remote_windows:
                self._remote_windows.remove(win)
        except Exception:
            pass

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
        geo = "geolocation" in type(request).__name__.lower()
        if host in allowed and (not geo or self._gps):
            request.allow()
        else:
            request.deny()
        return True


class WebViewWindow(Gtk.Window):
    """The embedded view on its own, for a one-off or a debug launch."""

    def __init__(self, settings, start_url=None, manager_url_override=None, seed_device_uuid=None, title=None):
        super().__init__(title=title or "JawnOS")
        self.set_default_size(1100, 820)
        self.panel = WebViewPanel(settings, start_url=start_url,
                                   manager_url_override=manager_url_override,
                                   seed_device_uuid=seed_device_uuid)
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
