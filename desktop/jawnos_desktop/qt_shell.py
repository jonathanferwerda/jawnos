"""JawnOS in a Qt WebEngine (Chromium) view -- the desktop shell.

The desktop engine is Qt WebEngine: Chromium, with the reference WebRTC
implementation, which the chat and the screening's Connect me need. Browse and
the session bar are Qt WebEngine too; there is no GTK/WebKitGTK fallback.

    ./desktop/jawnos-qt --url https://house.example:3000/manager
    ./desktop/jawnos-qt --probe     # WebRTC, media and bridge support, then exit

The login is the same ticket the desktop has always used: loading the ticket URL
mints the cookie and redirects to the Manager, and the profile keeps that
cookie across launches. The first run also copies the old WebKit shell's page
layout out of its per-origin SQLite store, and the window geometry comes from
``~/.config/jawnos/desktop.json``, saved back on close. Certificate errors are
accepted because the house serves its own self-signed certificate on its own
port.

The page bridge is the same contract the old shell exposed: a shim turns
``window.webkit.messageHandlers.jawnos`` into QWebChannel messages, so app
signing, peer Manager windows, Browse and media keep-awake keep working.
Downloads come through the shared profile's handler (the engine cancels one
nothing accepts), and a page may open a window: a same-origin Manager URL gets
a new top-level view on the same profile and its session cookie, an outside
address goes to Browse, and a ``mailto:``/``tel:`` link goes to the desktop.
Supervision (start/stop/restart, the version restart, the desktop self-update)
and the tray menu live here too, because a default launch opens only this
window.
"""

import argparse
import glob
import json
import os
import sqlite3
import sys
import threading
import time
from urllib.parse import urljoin, urlparse

from . import bridge, core, errorpage, gps, gpu, theme, webauthn

# desktop/, resolved the same way the other entry scripts do it.
DESKTOP_DIR = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
ROOT_DIR = os.path.dirname(DESKTOP_DIR)


def _qurl_host(url):
    """The lower-case host of a QUrl, or ''; QUrl spells it host(), not hostname()."""
    try:
        return (url.host() or "").strip("[]").lower()
    except Exception:
        return ""


# Non-http schemes the shell hands to the desktop's own handler. A page may
# link to anything; only these well-known schemes are delegated, so a file: or
# javascript: link can never reach an external program. Keep this list equal to
# browser.py's EXTERNAL_SCHEMES: one rule for both windows.
EXTERNAL_SCHEMES = frozenset({
    "mailto", "tel", "sms", "geo", "magnet", "bitcoin", "webcal",
    "irc", "ircs", "xmpp", "spotify", "steam",
})

# The shell's own origin: the Manager may always open a window on loopback.
LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost", "::1"})


def classify_new_window(url, manager_host="", allowed_hosts=()):
    """Where a ``window.open``/``target=_blank`` URL belongs.

    ``manager`` -- a same-origin Manager URL: loopback, the local Manager's
    host, or a peer Manager's host. These open in a new top-level view on the
    shared profile, so the session cookie comes with them.
    ``browse`` -- any other http(s) address: the native Browse window, which
    has its own profile and no session, so it must not be sent a Manager page.
    ``external`` -- a scheme the desktop owns (``mailto:`` and friends).
    ``deny`` -- everything else: ``file:``, ``javascript:``, ``about:blank``,
    an empty request, or a bare relative URL (the engine has already resolved
    those against the page that asked, so a schemeless value cannot be placed).

    Pure and Qt-free, so the rules are testable without a display.
    """
    text = str(url or "").strip()
    if not text:
        return "deny"
    try:
        parsed = urlparse(text)
        scheme = (parsed.scheme or "").lower()
    except ValueError:
        return "deny"
    if scheme in ("http", "https"):
        host = (parsed.hostname or "").lower()
        if not host:
            return "deny"
        if host in LOOPBACK_HOSTS:
            return "manager"
        if manager_host and host == str(manager_host).strip().lower():
            return "manager"
        for allowed in allowed_hosts or ():
            if host == str(allowed or "").strip().lower():
                return "manager"
        return "browse"
    if scheme in EXTERNAL_SCHEMES:
        return "external"
    return "deny"


_TRAY_ICONS = {}


def tray_icon(icon_path, rgb):
    """The jawnos mark with a state dot in its corner, cached per colour.

    The old GTK tray badge drew the same dot (green running, amber
    starting/restarting, red stopped) because a tray icon has no room for a
    separate label; a dark rim keeps it readable on a light or dark panel.

    PySide6 is imported here, not at module level, so the rest of this module
    (the localStorage reader) stays importable without the Qt bindings.
    """
    from PySide6.QtCore import QPointF, Qt
    from PySide6.QtGui import QColor, QIcon, QPainter, QPixmap

    key = (icon_path, tuple(rgb))
    cached = _TRAY_ICONS.get(key)
    if cached is not None:
        return cached
    pixmap = QPixmap(icon_path) if icon_path and os.path.exists(icon_path) else QPixmap()
    if pixmap.isNull():
        pixmap = QIcon.fromTheme("jawnos").pixmap(64, 64)
    if pixmap.isNull():
        pixmap = QPixmap(64, 64)
        pixmap.fill(Qt.GlobalColor.transparent)
    pixmap = pixmap.scaled(
        64, 64,
        Qt.AspectRatioMode.KeepAspectRatio,
        Qt.TransformationMode.SmoothTransformation)
    painter = QPainter(pixmap)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing, True)
    radius = max(3.0, pixmap.width() * 0.19)
    centre = QPointF(pixmap.width() - radius - 1.0,
                     pixmap.height() - radius - 1.0)
    painter.setPen(Qt.PenStyle.NoPen)
    painter.setBrush(QColor(0, 0, 0, 217))
    painter.drawEllipse(centre, radius + 1.5, radius + 1.5)
    painter.setBrush(QColor(*rgb))
    painter.drawEllipse(centre, radius, radius)
    painter.end()
    icon = QIcon(pixmap)
    _TRAY_ICONS[key] = icon
    return icon


def black_page(page_obj, view_obj):
    """Paint the engine's empty page black instead of Chromium's white.

    Until the Manager's first frame -- and on ``about:blank``, or after a
    failed load -- the view shows the page's base colour. Chromium's default
    is white: a flash on every launch, and a white window whenever there is
    nothing to display. The page colour is what the engine composites; the
    view's own palette and stylesheet cover the widget around it.

    PySide6 is imported here for the same reason as in ``tray_icon``.
    """
    from PySide6.QtGui import QColor, QPalette

    black = QColor(0, 0, 0)
    try:
        page_obj.setBackgroundColor(black)
    except Exception:
        pass
    try:
        palette = view_obj.palette()
        palette.setColor(QPalette.ColorRole.Window, black)
        view_obj.setPalette(palette)
        view_obj.setAutoFillBackground(True)
        view_obj.setStyleSheet("background-color: #000000;")
    except Exception:
        pass


def prepare_wayland_env():
    """Point Qt and Chromium at Wayland when the session is Wayland.

    Qt 6 may still choose xcb; a Sway session has no X server unless XWayland
    is running, and Chromium's Ozone platform should follow the same choice.
    An explicit QT_QPA_PLATFORM (or ozone flag) always wins, and X11 sessions
    are untouched.

    Chromium gets the *hint*, not `--ozone-platform=wayland`: Arch's
    qt6-webengine is not built with the Wayland Ozone platform, and the
    explicit platform aborts with "Invalid ozone platform: wayland" before the
    window exists. The hint lets the build use Wayland when it has it and fall
    back otherwise.
    """
    if not os.environ.get("WAYLAND_DISPLAY"):
        return
    if not os.environ.get("QT_QPA_PLATFORM"):
        os.environ["QT_QPA_PLATFORM"] = "wayland"
    flags = os.environ.get("QTWEBENGINE_CHROMIUM_FLAGS", "")
    if "--ozone-platform" not in flags and "--ozone-platform-hint" not in flags:
        os.environ["QTWEBENGINE_CHROMIUM_FLAGS"] = (
            flags + " --ozone-platform-hint=auto").strip()


# --------------------------------------------------------------------------
# the same login the WebKit shell uses, without importing GTK
# --------------------------------------------------------------------------

def ticket_url():
    """The stored login ticket, if any (keyring, Fernet file, or .shots)."""
    try:
        from . import secrets
        stored = secrets.load()
        if stored:
            return stored
    except Exception:
        pass
    path = os.path.join(ROOT_DIR, ".shots", "ticket.txt")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read().strip() or None
    except OSError:
        return None


def manager_url(jawn_dir, ticket=None):
    """Where the manager lives, on the host the login happened on.

    Same rule the old WebKit shell used: the cookie is scoped to the ticket's
    host, so the Manager must be loaded from that host; loopback is only the
    fallback for a plain local launch.
    """
    port = core.jawn_working_port(jawn_dir)
    host = "127.0.0.1"
    if ticket:
        try:
            host = urlparse(ticket).hostname or host
        except ValueError:
            pass
    else:
        host = core.manager_host() or host
    return "https://%s:%d/manager" % (host, port)


def profile_dir():
    return os.path.join(core.config_dir(), "qt-webengine")


# --------------------------------------------------------------------------
# the old GTK shell's layout, moved into the Qt profile
# --------------------------------------------------------------------------

# Keys that belong to a live session, not the layout: a copied tab id makes
# two windows claim one tab. device_uuid is kept: it is this machine's own
# device identity (the same one the app key is paired with), and the
# app-required page needs it to sign in. The session timestamps stay behind.
_SKIP_KEYS = frozenset((
    "browser_tab", "jawnos_media_lock", "jawn_app_until",
    "lastSearchTime",
))


def webkit_localstorage(host, port, base=None):
    """The legacy WebKitGTK localStorage for one origin, as ``{key: value}``.

    The removed GTK shell kept the page's layout in WebKit's per-origin SQLite
    store (``~/.local/share/<app>/localstorage/https_<host>_<port>.localstorage``):
    ``layout``, ``background_images``, ``background_images_opacity``, the
    ``dock_apps`` family, the soft-keyboard layout. Qt WebEngine uses
    Chromium's LevelDB store, so the keys have to be copied once.

    ``base`` exists so the reader can be tested against a fixture; the default
    is the XDG data directory the installed desktop app writes to.
    """
    base = base or os.path.expanduser("~/.local/share")
    name = "https_%s_%s.localstorage" % (host, port)
    candidates = []
    for pattern in ("*/localstorage/" + name, "*/*/localstorage/" + name):
        candidates.extend(glob.glob(os.path.join(base, pattern)))
    files = []
    for path in candidates:
        try:
            files.append((os.path.getmtime(path), path))
        except OSError:
            pass
    for _mtime, path in sorted(files, reverse=True):
        try:
            con = sqlite3.connect("file:%s?mode=ro" % path, uri=True)
            tables = [row[0] for row in con.execute(
                "select name from sqlite_master where type='table'")]
            table = "ItemTable" if "ItemTable" in tables else (tables[0] if tables else "")
            rows = con.execute("select key, value from %s" % table).fetchall() if table else []
            con.close()
        except sqlite3.Error:
            continue
        out = {}
        for key, value in rows:
            if str(key) in _SKIP_KEYS:
                continue
            if isinstance(value, bytes):
                try:
                    text = value.decode("utf-16-le")
                except UnicodeDecodeError:
                    text = value.decode("utf-8", "replace")
            else:
                text = str(value)
            out[str(key)] = text
        if out:
            return path, out
    return None, {}


# A Qt profile that was created by the old migration has the marker but no
# device_uuid (the old skip list dropped it), so the app-required page had no
# device to sign for. The seed below runs at document start, before the page's
# scripts: it writes the WebKit desktop's identity once, then leaves it alone.
# A profile that already has a device_uuid is overwritten once on purpose --
# that value is this machine's device identity, the one the app key was paired
# under.
def device_seed_js(host, port, base=None):
    """A document-start script that seeds the WebKit desktop's device_uuid.

    Older Qt profiles were migrated without it (see _SKIP_KEYS); the app-key
    login then has no device to name and lands on the app-required page. Only
    run once per profile (the marker), and only when there is a value to use.
    """
    _path, data = webkit_localstorage(host, port, base=base)
    value = data.get("device_uuid")
    if not value:
        return ""
    return ("(function(){try{"
            "if(localStorage.getItem('__jawn_device_seeded')){return;}"
            "localStorage.setItem('device_uuid', %s);"
            "localStorage.setItem('__jawn_device_seeded','1');"
            "}catch(e){}})()" % json.dumps(value))


# Sets every migrated key, once, then marks the profile so a later Qt run does
# not overwrite what the person changed here.
_MIGRATE_JS = """
(function () {
  try {
    if (localStorage.getItem('__jawn_qt_migrated')) { return 'already'; }
    var data = %s;
    for (var k in data) {
      if (Object.prototype.hasOwnProperty.call(data, k)) {
        try { localStorage.setItem(k, data[k]); } catch (e) {}
      }
    }
    localStorage.setItem('__jawn_qt_migrated', '1');
    return 'migrated';
  } catch (e) { return 'error: ' + e; }
})()
"""


# --------------------------------------------------------------------------
# the page <-> app bridge
# --------------------------------------------------------------------------

# Installed at document creation, after Qt's qwebchannel.js. It gives the page
# the legacy ``window.webkit.messageHandlers`` names, forwards them through
# QWebChannel, and marks the page as running inside the desktop app
# (universal.js keys its app login off that marker). Messages that arrive before
# the channel is ready are queued, not dropped.
_BRIDGE_SHIM_JS = r"""
(function () {
  if (window.__jawnQtShim) { return; }
  window.__jawnQtShim = true;
  window.webkit = window.webkit || {};
  window.webkit.messageHandlers = window.webkit.messageHandlers || {};
  window.__jawnQtQueue = [];
  window.__jawnQtPost = function (name, raw) {
    if (window.__jawnQtBridge) {
      try { window.__jawnQtBridge.postMessage(name, String(raw)); } catch (e) {}
    } else {
      window.__jawnQtQueue.push([name, String(raw)]);
    }
  };
  ['jawnos', 'jawnos_browse'].forEach(function (name) {
    window.webkit.messageHandlers[name] = {
      postMessage: function (raw) { window.__jawnQtPost(name, raw); }
    };
  });
  if (typeof QWebChannel !== 'function' || !window.qt ||
      !window.qt.webChannelTransport) { return; }
  try {
    new QWebChannel(window.qt.webChannelTransport, function (channel) {
      window.__jawnQtBridge = channel.objects.jawnos;
      var queued = window.__jawnQtQueue || [];
      window.__jawnQtQueue = [];
      for (var i = 0; i < queued.length; i++) {
        try {
          window.__jawnQtBridge.postMessage(queued[i][0], queued[i][1]);
        } catch (e) {}
      }
    });
  } catch (e) {}
})();
"""


# Coasting after a trackpad flick. Chromium's scroll animator smooths the
# deltas it is handed, and stops as soon as they stop; the laptop's touchpad is
# libinput, which has no coasting of its own either. WebKitGTK's view animated a
# wheel burst for longer, and that is the feel that went missing with the port.
# So: keep a short velocity from the burst and, once the wheel goes quiet, keep
# scrolling the container under the pointer with a per-millisecond decay.
#
# It is a page script, not a Qt one, because only the page knows which element
# scrolls (a window's inner div, not the document). The wardrobe's canvases are
# left alone: clotheslineScroller already glides them ~32x their distance and a
# second glide would overshoot. A wheel the app handled itself (defaultPrevented
# at the window, where this listener runs last) is left alone too. JAWNOS_MOMENTUM=0
# in qt.env turns the whole thing off.
_MOMENTUM_JS = r"""
(function () {
  if (window.__jawnMomentum) { return; }
  window.__jawnMomentum = true;

  var FRICTION = 0.996;   // share of the velocity kept per millisecond
  var QUIET = 60;         // ms of no wheel events: the flick has ended
  var WINDOW = 120;       // ms of history the velocity is read from
  var MIN_SAMPLES = 3;    // a mouse wheel notch is one or two events
  var MIN_SPAN = 40;      // ms; a notch is shorter than a flick
  var MIN_SPEED = 0.06;   // px/ms; a slow drag does not coast
  var MAX_SPEED = 6;      // px/ms; a sanity cap
  var MIN_STEP = 0.02;    // px/ms; below this the tail is invisible

  var history = [];
  var target = null;
  var quiet = null;
  var coast = null;       // {el, v, last}
  var frame = null;

  function scrollerFor(node) {
    var el = node && node.nodeType === 1 ? node : (node && node.parentElement);
    while (el && el !== document.body && el !== document.documentElement) {
      var overflow = window.getComputedStyle(el).overflowY;
      if (/(auto|scroll|overlay)/.test(overflow) &&
          el.scrollHeight > el.clientHeight + 1) {
        return el;
      }
      el = el.parentElement;
    }
    return document.scrollingElement || document.documentElement;
  }

  function stop() {
    if (frame) { cancelAnimationFrame(frame); frame = null; }
    coast = null;
  }

  function step(now) {
    if (!coast) { return; }
    var dt = now - coast.last;
    if (dt <= 0) {
      // The frame's timestamp is its start, which can precede the release.
      frame = requestAnimationFrame(step);
      return;
    }
    dt = Math.min(dt, 32);
    coast.last = now;
    var el = coast.el;
    var was = el.scrollTop;
    el.scrollTop = was + coast.v * dt;
    if (el.scrollTop === was) { stop(); return; }   // the end of the list
    coast.v *= Math.pow(FRICTION, dt);
    if (Math.abs(coast.v) < MIN_STEP) { stop(); return; }
    frame = requestAnimationFrame(step);
  }

  function release() {
    quiet = null;
    var burst = history;
    history = [];
    // Same node for every event of a burst unless the pointer moved to
    // another window mid-flick; the last one is the one being read.
    target = burst.length ? burst[burst.length - 1][2] : target;
    if (burst.length < MIN_SAMPLES) { return; }
    var span = burst[burst.length - 1][0] - burst[0][0];
    if (span < MIN_SPAN) { return; }
    var travel = 0;
    for (var i = 0; i < burst.length; i++) { travel += burst[i][1]; }
    var v = travel / span;
    if (!isFinite(v) || Math.abs(v) < MIN_SPEED) { return; }
    v = Math.max(-MAX_SPEED, Math.min(MAX_SPEED, v));
    coast = { el: scrollerFor(target), v: v, last: performance.now() };
    frame = requestAnimationFrame(step);
  }

  window.addEventListener('wheel', function (e) {
    var wasCoasting = coast !== null;
    stop();
    if (wasCoasting) { history = []; }
    if (e.ctrlKey || e.defaultPrevented) { history = []; return; }
    if (e.target && e.target.closest && e.target.closest('.background')) {
      history = [];
      return;
    }
    var now = performance.now();
    history.push([now, e.deltaY, e.target]);
    while (history.length && now - history[0][0] > WINDOW) { history.shift(); }
    if (quiet !== null) { clearTimeout(quiet); }
    quiet = setTimeout(release, QUIET);
  }, { passive: true });

  // Any other input takes the scroll back from the coast, the way a finger on
  // the pad would.
  ['mousedown', 'keydown', 'touchstart', 'blur'].forEach(function (name) {
    window.addEventListener(name, function () {
      stop();
      history = [];
    }, { passive: true });
  });
})();
"""


def momentum_enabled():
    """False when JAWNOS_MOMENTUM=0 (qt.env is read into the environment)."""
    value = str(os.environ.get("JAWNOS_MOMENTUM", "1")).strip().lower()
    return value not in ("0", "false", "no", "off")


def _webchannel_js():
    """Qt's QWebChannel JavaScript, read from the resource the library ships."""
    try:
        from PySide6.QtCore import QFile, QIODevice
    except Exception:
        return ""
    handle = QFile(":/qtwebchannel/qwebchannel.js")
    if not handle.open(QIODevice.ReadOnly):
        return ""
    try:
        return bytes(handle.readAll()).decode("utf-8")
    finally:
        handle.close()


# --------------------------------------------------------------------------
# the WebRTC probe
# --------------------------------------------------------------------------

# Sets window.__jawn_qt_probe to a JSON string. The synchronous part answers
# whether the engine has the APIs; the offer proves the stack itself works.
_PROBE_JS = r"""
(function () {
  var out = {
    rtc: typeof RTCPeerConnection,
    media: !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia),
    secure: !!window.isSecureContext,
    sheets: document.styleSheets.length,
    links: document.querySelectorAll('link[rel="stylesheet"]').length,
    title: document.title,
    taskbar: !!document.getElementById('taskbar'),
    bridge: !!window.__jawnQtBridge,
    ping: false,
    desktop: !!window.JawnDesktop,
    layout: (function () {
      try { return localStorage.getItem('layout') || ''; } catch (e) { return ''; }
    })(),
    // Which renderer is actually painting: software (SwiftShader/llvmpipe)
    // means the blocklist or the driver, not the page. The GTK fixes were
    // about this; here the answer should name the Intel card.
    gpu: (function () {
      try {
        var canvas = document.createElement('canvas');
        var gl = canvas.getContext('webgl') || canvas.getContext('experimental-webgl');
        if (!gl) { return 'none'; }
        var info = gl.getExtension('WEBGL_debug_renderer_info');
        var renderer = info ? gl.getParameter(info.UNMASKED_RENDERER_WEBGL)
                            : gl.getParameter(gl.RENDERER);
        var vendor = info ? gl.getParameter(info.UNMASKED_VENDOR_WEBGL)
                          : gl.getParameter(gl.VENDOR);
        return String(vendor) + ' / ' + String(renderer);
      } catch (e) { return 'error: ' + e; }
    })(),
    url: location.href
  };
  window.__jawn_qt_probe = JSON.stringify(out);
  if (out.bridge) {
    // Prove the page -> app -> page path, not only that an object exists.
    window.__jawnAppResult = function (id, res) {
      if (id !== 'probe-ping') { return; }
      try {
        var r = JSON.parse(window.__jawn_qt_probe);
        r.ping = !!(res && res.ok && res.pong);
        window.__jawn_qt_probe = JSON.stringify(r);
      } catch (e) {}
    };
    try {
      window.__jawnQtBridge.postMessage('jawnos', JSON.stringify({
        action: 'ping', id: 'probe-ping'
      }));
    } catch (e) {}
    try {
      // Also exercise the origin-checked path (no reply): a handler that
      // references a name it cannot see raises here, on any real page.
      window.__jawnQtBridge.postMessage('jawnos', JSON.stringify({
        action: 'media_state', audio: false, video: false
      }));
    } catch (e) {}
  }
  if (out.rtc !== 'function') { return; }
  try {
    var pc = new RTCPeerConnection({ iceServers: [] });
    pc.createDataChannel('probe');
    pc.createOffer()
      .then(function (offer) { return pc.setLocalDescription(offer); })
      .then(function () {
        var r = JSON.parse(window.__jawn_qt_probe);
        r.offer = (pc.localDescription && pc.localDescription.type) || 'none';
        window.__jawn_qt_probe = JSON.stringify(r);
        pc.close();
      })
      .catch(function (err) {
        var r = JSON.parse(window.__jawn_qt_probe);
        r.offer = 'error: ' + err;
        window.__jawn_qt_probe = JSON.stringify(r);
      });
  } catch (err) {
    var r = JSON.parse(window.__jawn_qt_probe);
    r.offer = 'error: ' + err;
    window.__jawn_qt_probe = JSON.stringify(r);
  }
})();
"""

_BLANK = "data:text/html,<html><body style='font-family:sans-serif'>JawnOS Qt probe</body></html>"


def _probe_url():
    """A file:// page for --probe: the bridge needs a real origin.

    A data: URL is an opaque origin, so QWebChannel's transport is absent:
    bridge/ping report false even on a healthy engine (seen on Arch's Qt 6.12).
    A tiny local file gives the probe a normal origin and the full result.
    """
    import tempfile
    path = os.path.join(tempfile.gettempdir(), "jawnos-qt-probe.html")
    try:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("<!doctype html><html><body>JawnOS Qt probe</body></html>")
        return "file://" + path
    except OSError:
        return _BLANK


def _probe(page, app, qt):
    """Print the probe JSON and exit 0 when the engine has WebRTC."""
    QTimer = qt["QTimer"]
    state = {"tries": 0}

    def finish(value):
        text = str(value or "")
        if not text:
            state["tries"] += 1
            if state["tries"] < 20:
                QTimer.singleShot(250, read)
                return
            print("qt-probe " + json.dumps({"error": "no result"}))
            app.exit(1)
            return
        try:
            data = json.loads(text)
        except Exception:
            data = {}
        # Let the asynchronous bridge ping land before reading the result.
        if data.get("bridge") and not data.get("ping") and state["tries"] < 20:
            state["tries"] += 1
            QTimer.singleShot(250, read)
            return
        # The ticket page mints the cookie and then redirects; probe the page
        # after it, not the ticket itself.
        if "/box_office/" in str(data.get("url") or ""):
            QTimer.singleShot(500, kick)
            return
        print("qt-probe " + text)
        # A data: URL is not a secure context, so getUserMedia is absent there
        # by design; WebRTC itself is the engine's property.
        ok = data.get("rtc") == "function"
        app.exit(0 if ok else 1)

    def read():
        page.runJavaScript("window.__jawn_qt_probe || ''", finish)

    def kick():
        page.runJavaScript(_PROBE_JS, lambda _value: QTimer.singleShot(250, read))

    return kick


# --------------------------------------------------------------------------
# the shell
# --------------------------------------------------------------------------

def _accept_certificate(error):
    """Accept the house's self-signed certificate (as the WebKit shell does)."""
    try:
        if hasattr(error, "isOverridable") and not error.isOverridable():
            return False
        # Qt 6.8 spells it acceptCertificate(); older bindings used accept().
        if hasattr(error, "acceptCertificate"):
            error.acceptCertificate()
        else:
            error.accept()
        return True
    except Exception:
        return False


# The features Qt WebEngine asks a page for, and the house will grant. Only
# these names are allowed; everything else, and every other origin, is denied.
# The WebKitGTK view granted every feature type to the same hosts.
_HOUSE_PERMISSIONS = (
    # Microphone, camera, or both (the chat and the screening's Connect me).
    "MediaAudioCapture",
    "MediaVideoCapture",
    "MediaAudioVideoCapture",
    # Screen share (getDisplayMedia) in the Wardrobe, Jp and Studio apps.
    "DesktopVideoCapture",
    "DesktopAudioVideoCapture",
    # requestPointerLock in the remote control.
    "MouseLock",
    # navigator.clipboard and execCommand('copy') in the remote control,
    # folders, box office and chat apps.
    "ClipboardReadWrite",
    # new Notification(...) in the chat.
    "Notifications",
)

# Offered only on a machine with a real receiver; see gps.has_gps.
_GPS_PERMISSION = "Geolocation"


def _permission_host(origin):
    """The lower-case host of a request's origin (a QUrl, or a URL string)."""
    host = _qurl_host(origin)
    if host:
        return host
    try:
        return (urlparse(str(origin or "")).hostname or "").lower()
    except ValueError:
        return ""


def _feature_permission(page, qt, allowed_hosts, gps_on=False):
    """Grant this page the house's features, and only to the house's origins.

    Qt 6.8 moved web permissions from ``QWebEnginePage`` to
    ``QWebEnginePermission``; newer builds (Arch ships 6.12) have only the new
    signal. Keep the old path for a PySide6 older than that.

    ``allowed_hosts`` is the live set of loopback hosts plus the Manager's
    origin and each peer window's: the Manager view can also show a public
    page, which must not inherit the camera, the screen, the clipboard or a
    notification. A feature outside ``_HOUSE_PERMISSIONS`` is always denied.
    Geolocation is added only where ``gps.has_gps`` found a real receiver.
    """
    names = list(_HOUSE_PERMISSIONS)
    if gps_on:
        names.append(_GPS_PERMISSION)

    Permission = qt.get("QWebEnginePermission")
    if Permission is not None and hasattr(page, "permissionRequested"):
        enum = getattr(Permission, "PermissionType", None)
        if enum is None:
            enum = getattr(Permission, "Feature", Permission)
        granted = set()
        for name in names:
            value = getattr(enum, name, None)
            if value is not None:
                granted.add(value)

        def decide(permission):
            try:
                feature = permission.permissionType()
                if feature in granted and _permission_host(
                        permission.origin()) in allowed_hosts:
                    permission.grant()
                else:
                    permission.deny()
            except Exception:
                pass

        page.permissionRequested.connect(decide)
        return

    QWebEnginePage = qt["QWebEnginePage"]
    granted = set()
    for name in names:
        value = getattr(QWebEnginePage.Feature, name, None)
        if value is not None:
            granted.add(value)

    def decide_legacy(origin, feature):
        allow = feature in granted and _permission_host(origin) in allowed_hosts
        policy = (QWebEnginePage.PermissionPolicy.PermissionGrantedByUser
                  if allow else
                  QWebEnginePage.PermissionPolicy.PermissionDeniedByUser)
        page.setFeaturePermission(origin, feature, policy)

    page.featurePermissionRequested.connect(decide_legacy)


def _allow_screen_capture(page, qt, allowed_hosts):
    """Answer a page's ``getDisplayMedia`` with the first screen.

    Qt keeps screen capture switched off until ``ScreenCaptureEnabled`` is set,
    and then hands the request to the app. ``QWebEngineDesktopMediaRequest``
    has no accept(): there is only a screen/window model to choose from, so
    this shares the first screen rather than presenting a picker. The request
    does not expose its origin, so the page's committed URI is checked against
    the same host allowlist as the permission handler.
    """
    try:
        page.settings().setAttribute(
            qt["QWebEngineSettings"].WebAttribute.ScreenCaptureEnabled, True)
    except Exception:
        pass

    def choose(model, select):
        if model is None or model.rowCount() < 1:
            return False
        select(model.index(0, 0))
        return True

    def handle(request):
        try:
            if _permission_host(page.url()) not in allowed_hosts:
                request.cancel()
                return
            if choose(request.screensModel(), request.selectScreen):
                return
            # A session with no screen output may still offer windows; take
            # the first of those instead of failing the share outright.
            if not choose(request.windowsModel(), request.selectWindow):
                request.cancel()
        except Exception:
            try:
                request.cancel()
            except Exception:
                pass

    try:
        page.desktopMediaRequested.connect(handle)
    except Exception:
        pass


def _allow_clipboard(page, qt):
    """Turn on the clipboard attribute the Manager's apps use.

    ``JavascriptCanAccessClipboard`` is off by default. It is not the origin
    check: a page's read/write still goes through the permission handler's
    ``ClipboardReadWrite`` grant, which is limited to the house's hosts.
    """
    try:
        page.settings().setAttribute(
            qt["QWebEngineSettings"].WebAttribute.JavascriptCanAccessClipboard,
            True)
    except Exception:
        pass


def open_external(uri):
    """Hand a known desktop scheme to the OS; never file: or javascript:.

    The Manager links to ``mailto:``, ``tel:`` and friends. Qt WebEngine asks
    no one about a scheme it cannot render, so the page's request is answered
    here; the allowlist is the same one Browse uses.
    """
    try:
        scheme = (urlparse(str(uri or "")).scheme or "").lower()
    except ValueError:
        return False
    if scheme not in EXTERNAL_SCHEMES:
        return False
    from PySide6.QtCore import QUrl
    from PySide6.QtGui import QDesktopServices

    try:
        return bool(QDesktopServices.openUrl(QUrl(uri)))
    except Exception:
        return False


def _install_downloads(profile, parent, tray_holder):
    """Ask where to save a download, accept it, and report it through the tray.

    Qt cancels a download when nothing answers the profile's
    ``downloadRequested``, and the Manager downloads things (an email
    attachment, a file, a store receipt). The handler is connected once to the
    shared named profile, so the Manager view and every peer Manager window
    opened from it inherit it. Browse keeps its own handler and profile.

    There is no progress bar in the Manager view, so the tray reports the
    start, the end and a failure; ``active`` holds the item until it finishes,
    as Qt does not keep the Python object alive across the signals.
    """
    from PySide6.QtCore import QStandardPaths
    from PySide6.QtWidgets import QFileDialog, QSystemTrayIcon

    try:
        from PySide6.QtWebEngineCore import QWebEngineDownloadRequest as Download
    except Exception:  # Qt 5's name for the same object
        try:
            from PySide6.QtWebEngineCore import QWebEngineDownloadItem as Download
        except Exception:
            Download = None
    enum = getattr(Download, "DownloadState", None) if Download is not None else None
    completed = getattr(enum, "DownloadCompleted", None) if enum is not None else None
    active = set()

    def note(title, body):
        tray = tray_holder.get("tray")
        if tray is None:
            return
        try:
            tray.showMessage(title, body,
                             QSystemTrayIcon.MessageIcon.Information, 6000)
        except Exception:
            pass

    def changed(item, state):
        if completed is not None and state == completed:
            name = "the file"
            try:
                name = item.downloadFileName() or name
            except Exception:
                pass
            note("Downloaded", name)
        else:
            reason = "the download did not finish"
            try:
                reason = item.interruptReasonString() or reason
            except Exception:
                pass
            note("Download failed", reason)
        active.discard(item)

    def started(item):
        suggested = (item.suggestedFileName() or "download").strip() or "download"
        folder = QStandardPaths.writableLocation(
            QStandardPaths.StandardLocation.DownloadLocation)
        if not folder:
            folder = os.path.expanduser("~")
        path, _selected = QFileDialog.getSaveFileName(
            parent, "Save download", os.path.join(folder, suggested))
        if not path:
            try:
                item.cancel()
            except Exception:
                pass
            return
        try:
            item.setDownloadDirectory(os.path.dirname(path) or folder)
            item.setDownloadFileName(os.path.basename(path))
            item.stateChanged.connect(lambda state: changed(item, state))
            item.accept()
        except Exception:
            return
        active.add(item)
        note("Downloading", os.path.basename(path))

    try:
        profile.downloadRequested.connect(started)
    except Exception:
        pass


def _install_notifications(profile, qt, allowed_hosts, tray):
    """Show a page's ``new Notification`` through the tray.

    Qt WebEngine has no default notification presenter -- without one the
    Manager's chat notifications are dropped silently -- and the engine only
    reports them through ``QWebEngineProfile.setNotificationPresenter``. The
    tray icon the shell already keeps is the presenter; when the shell was
    asked to run without one (or the desktop has no tray), a small one is
    created on demand, because a message needs an icon to come from.

    ``tray`` is a one-slot holder: main() creates the real tray after the
    profile, so the presenter reads it when a notification arrives.
    """
    from PySide6.QtGui import QIcon
    from PySide6.QtWidgets import QSystemTrayIcon

    hidden = {"tray": None}

    def presenter(notification):
        try:
            if _permission_host(notification.origin()) not in allowed_hosts:
                return
            title = notification.title() or "JawnOS"
            body = notification.message() or ""
        except Exception:
            return
        icon = tray.get("tray")
        if icon is None:
            icon = hidden["tray"]
            if icon is None:
                path = os.path.join(DESKTOP_DIR, "icons", "jawnos.png")
                mark = (QIcon(path) if os.path.exists(path)
                        else QIcon.fromTheme("jawnos"))
                icon = QSystemTrayIcon(mark, profile)
                icon.setToolTip("JawnOS")
                icon.show()
                hidden["tray"] = icon
        try:
            icon.showMessage(title, body,
                             QSystemTrayIcon.MessageIcon.Information, 8000)
        except Exception:
            pass
        # Tell the engine it was presented, and let it forget the notification
        # once the message's lifetime is over.
        try:
            notification.show()
        except Exception:
            pass
        try:
            qt["QTimer"].singleShot(8000, notification.close)
        except Exception:
            pass

    try:
        profile.setNotificationPresenter(presenter)
    except Exception:
        pass


def _allow_fullscreen(page, window, qt, restore=None):
    """Let a page's video fill the screen.

    Qt WebEngine keeps the Fullscreen API switched off until
    ``FullScreenSupportEnabled`` is set, and then drops a request the app does
    not accept. The WebKitGTK view this shell replaced did both, so a player's
    fullscreen worked; without the attribute ``fullScreenRequested`` never
    fires and the picture stays inside its box.

    ``restore`` puts the window back the way it was when the video leaves
    fullscreen; without one it returns to a normal window.
    """
    try:
        page.settings().setAttribute(
            qt["QWebEngineSettings"].WebAttribute.FullScreenSupportEnabled,
            True)
    except Exception:
        pass

    was_maximized = {"on": False}

    def handle(request):
        try:
            on = bool(request.toggleOn())
            request.accept()
        except Exception:
            return
        if on:
            was_maximized["on"] = bool(window.isMaximized())
            window.showFullScreen()
        elif restore is not None:
            restore()
        elif was_maximized["on"]:
            window.showMaximized()
        else:
            window.showNormal()

    try:
        page.fullScreenRequested.connect(handle)
    except Exception:
        pass


def _launch_browse(url, manager_base, mode="browse", app="", uuid=""):
    """Start the native Browse window for a URL the Manager does not own.

    One launcher invocation for both callers: the page's ``browse`` bridge
    action and an outside link opened by ``window.open``/``target=_blank``.
    Browse has its own profile and no session, which is exactly why a
    same-origin Manager URL must never come through here.

    ``spawn_detached`` returns at once, so the GUI thread keeps painting. A
    missing launcher raises for the bridge action's reply.
    """
    launcher = bridge.browse_launcher()
    if not launcher:
        raise ValueError("no browse launcher")
    argv = launcher + [
        "--manager", manager_base or "",
        "--url", url,
        "--mode", mode,
        "--app", app,
        "--uuid", uuid,
    ]
    core.spawn_detached(
        argv, DESKTOP_DIR,
        os.path.join(core.state_dir(), "browse.log"))


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="jawnos-qt",
        description="JawnOS in a Qt WebEngine (Chromium) view")
    parser.add_argument("--url", help="load this URL instead of the stored ticket/manager")
    parser.add_argument("--probe", action="store_true",
                        help="print WebRTC/media/bridge support and exit")
    parser.add_argument("--webview", action="store_true",
                        help="(default) open the JawnOS view")
    parser.add_argument("--tray", action="store_true",
                        help="(default) keep a status-tray icon")
    parser.add_argument("--no-tray", action="store_true",
                        help="no status-tray icon; closing the window quits")
    parser.add_argument("--no-start", action="store_true",
                        help="do not start jawn when the view opens")
    parser.add_argument("--panel", action="store_true",
                        help="open the control panel")
    args = parser.parse_args(argv)

    # Before QApplication: Qt WebEngine reads the VA-API driver and the Chromium
    # flags when it initialises. The GPU flags go first so the Wayland ozone hint
    # is appended to the same string.
    gpu.prepare_env()
    prepare_wayland_env()

    try:
        from PySide6.QtCore import (
            QObject,
            QTimer,
            QUrl,
            Qt,
            Signal,
            Slot,
        )
        from PySide6.QtGui import QIcon
        from PySide6.QtWidgets import (
            QApplication,
            QDialog,
            QMenu,
            QPlainTextEdit,
            QSystemTrayIcon,
            QVBoxLayout,
        )
        from PySide6.QtWebEngineCore import (
            QWebEnginePage,
            QWebEngineProfile,
            QWebEngineScript,
            QWebEngineSettings,
        )
        from PySide6.QtWebEngineWidgets import QWebEngineView
        try:
            from PySide6.QtWebEngineCore import QWebEnginePermission
        except Exception:
            QWebEnginePermission = None
        try:
            from PySide6.QtWebChannel import QWebChannel
        except Exception:
            QWebChannel = None
    except Exception as exc:  # noqa: BLE001
        sys.stderr.write(
            "jawnos-qt needs PySide6 with Qt WebEngine "
            "(Arch: pyside6 qt6-webengine; Debian: python3-pyside6.qtwebenginewidgets): %s\n"
            % exc)
        return 2

    qt = {
        "QTimer": QTimer,
        "QWebEnginePage": QWebEnginePage,
        "QWebEngineProfile": QWebEngineProfile,
        "QWebEngineSettings": QWebEngineSettings,
        "QWebEngineView": QWebEngineView,
        "QWebEnginePermission": QWebEnginePermission,
    }

    try:
        from .qt_panel import ControlPanel
    except Exception:
        ControlPanel = None

    app = QApplication([sys.argv[0]])
    app.setApplicationName("JawnOS")
    app.setApplicationDisplayName("JawnOS")
    app.setOrganizationName("JawnOS")
    # Wayland derives app_id from the executable name unless the desktop file is
    # named. Running through `python3 jawnos-desktop` would otherwise present as
    # "python3": Sway's fullscreen rule and the taskbar/icon no longer match.
    # `jawnos` is the installed desktop entry (jawnos.desktop); the live image's
    # window rule accepts both spellings.
    try:
        app.setDesktopFileName("jawnos")
    except Exception:
        pass

    store = profile_dir()
    os.makedirs(os.path.join(store, "storage"), exist_ok=True)
    os.makedirs(os.path.join(store, "cache"), exist_ok=True)
    profile = QWebEngineProfile("jawnos", app)
    profile.setPersistentStoragePath(os.path.join(store, "storage"))
    profile.setCachePath(os.path.join(store, "cache"))
    profile.setPersistentCookiesPolicy(
        QWebEngineProfile.PersistentCookiesPolicy.ForcePersistentCookies)

    # Chromium's scroll animator is off unless it is asked for, so a wheel or
    # trackpad scroll steps instead of gliding, and a flick stops dead rather
    # than coasting. This is Qt's counterpart of the old WebKitGTK
    # ``enable-smooth-scrolling``. Profile settings are the ones every page
    # created from this profile starts with, so the Manager view and each peer
    # machine window opened from it get the same feel; Browse sets the same
    # attribute on each of its own views.
    try:
        profile.settings().setAttribute(
            QWebEngineSettings.WebAttribute.ScrollAnimatorEnabled, True)
    except Exception:
        pass

    settings = core.load_settings()

    # The origins the house's permissions and screen sharing are granted to:
    # loopback, plus the Manager's host (added once the ticket gives it) and
    # every peer window's. One live set is shared by each page's permission
    # handler, its screen-capture handler and the notification presenter.
    allowed_hosts = set(LOOPBACK_HOSTS)
    gps_on = gps.has_gps(settings.get("jawn_dir"))
    # The real tray is made later in main(); the presenter reads this slot
    # when a notification arrives.
    tray_holder = {"tray": None}
    _install_notifications(profile, qt, allowed_hosts, tray_holder)
    # Filled once the Manager's window plumbing below exists; a page only asks
    # for a new window after it has loaded something, which is later still.
    new_window_handler = {"open": None}

    class JawnView(QWebEngineView):
        """The view, and the window state also kept in desktop.json."""

        def __init__(self, shell_settings, save_state):
            super().__init__()
            self._shell_settings = shell_settings
            self._save_state_enabled = save_state
            self._tray = None

        def _save_state(self):
            if not self._save_state_enabled:
                return
            state = dict(self._shell_settings)
            state["fullscreen"] = bool(self.isFullScreen())
            state["maximized"] = bool(self.isMaximized())
            if not state["fullscreen"] and not state["maximized"]:
                state["window_width"] = self.width()
                state["window_height"] = self.height()
                state["window_x"] = self.x()
                state["window_y"] = self.y()
            try:
                core.save_settings(state)
            except Exception:
                pass

        def closeEvent(self, event):
            self._save_state()
            # With a tray, closing hides the window and leaves the app (and
            # jawn) running; the tray's Quit items are the way out.
            if self._tray is not None and self._tray.isVisible():
                self.hide()
                event.ignore()
                return
            super().closeEvent(event)

        def keyPressEvent(self, event):
            if event.key() == Qt.Key.Key_F11:
                self._toggle_fullscreen()
                return
            super().keyPressEvent(event)

        def _toggle_fullscreen(self):
            if self.isFullScreen():
                if self._shell_settings.get("maximized"):
                    self.showMaximized()
                else:
                    self.showNormal()
            else:
                self.showFullScreen()

    class JawnPage(QWebEnginePage):
        """A Manager page: it opens windows and hands outside links away.

        Qt drops a ``window.open``/``target=_blank`` whose page returns no
        window, and the WebKitGTK view this shell replaced opened one by
        default. ``on_new_window`` decides: a same-origin Manager URL opens a
        new top-level view on the shared profile (the session cookie comes
        along), an outside http(s) address goes to Browse, a desktop scheme
        goes to the OS, and anything else is dropped.

        Qt 6.2+ reports the popup through ``newWindowRequested`` with its URL
        in hand, so nothing is loaded here -- the callback loads a Manager
        URL itself and the engine's request is simply not accepted. An older
        binding calls ``createWindow`` first and only then loads the URL into
        the page it returned; that page is marked ``popup`` and classifies its
        first navigation in ``acceptNavigationRequest``.
        """

        def __init__(self, profile_obj, parent=None, on_new_window=None,
                     popup=False):
            super().__init__(profile_obj, parent)
            self._on_new_window = on_new_window
            self._popup = bool(popup)
            self._popup_spent = False
            self._signal_ok = False
            if on_new_window is not None and hasattr(self, "newWindowRequested"):
                try:
                    self.newWindowRequested.connect(self._requested_window)
                    self._signal_ok = True
                except Exception:
                    self._signal_ok = False

        def _requested_window(self, request):
            try:
                url = request.requestedUrl().toString()
            except Exception:
                return
            try:
                self._on_new_window(url)
            except Exception:
                pass

        def createWindow(self, window_type):
            # Old bindings only: the engine loads the URL into the page this
            # returns, so give it an empty one that classifies its first load.
            if self._on_new_window is None or self._signal_ok:
                return None
            try:
                return self._on_new_window(None, self)
            except Exception:
                return None

        def acceptNavigationRequest(self, url, nav_type, is_main_frame):
            try:
                uri = url.toString()
                scheme = (url.scheme() or "").lower()
            except Exception:
                return True
            # A mailto:/tel: link is not a page: hand it to the desktop and
            # cancel the navigation. http(s) is left alone -- the Manager is a
            # single-page app and must keep navigating its own routes.
            if is_main_frame and scheme in EXTERNAL_SCHEMES:
                open_external(uri)
                if self._popup:
                    self._popup_spent = True
                    win = self.parent()
                    try:
                        if win is not None:
                            win.close()
                    except Exception:
                        pass
                return False
            if self._popup and not self._popup_spent and is_main_frame:
                self._popup_spent = True
                if self._on_new_window is None:
                    return True
                try:
                    return self._on_new_window(uri, self) is self
                except Exception:
                    return True
            return True

    def dispatch_new_window(url, pending=None):
        # The main page exists before the Manager's own window plumbing is
        # defined; the slot is filled as soon as it is (before any load).
        handler = new_window_handler.get("open")
        if handler is None:
            return None
        return handler(url, pending)

    view = JawnView(settings, not args.probe)
    page = JawnPage(profile, view, on_new_window=dispatch_new_window)
    view.setPage(page)
    black_page(page, view)
    view.setWindowTitle("JawnOS")
    icon_path = os.path.join(DESKTOP_DIR, "icons", "jawnos.png")
    if os.path.exists(icon_path):
        view.setWindowIcon(QIcon(icon_path))
    width = int(settings.get("window_width") or 0)
    height = int(settings.get("window_height") or 0)
    if width >= 400 and height >= 300:
        view.resize(width, height)
    else:
        view.resize(1100, 820)
    left, top = settings.get("window_x"), settings.get("window_y")
    if isinstance(left, int) and isinstance(top, int):
        view.move(left, top)

    page.certificateError.connect(_accept_certificate)
    _feature_permission(page, qt, allowed_hosts, gps_on)
    _allow_screen_capture(page, qt, allowed_hosts)
    _allow_clipboard(page, qt)
    # Qt renders no passkey UX by itself (Qt 6.8+ hands the request over); a
    # binding without the signal simply keeps the old behaviour.
    try:
        webauthn.install_webauthn(page, view)
    except Exception:
        pass
    _install_downloads(profile, view, tray_holder)

    page_settings = page.settings()
    page_settings.setAttribute(
        QWebEngineSettings.WebAttribute.PlaybackRequiresUserGesture, False)
    # Qt's own error page is white; errorpage.py supplies a dark one instead.
    try:
        page_settings.setAttribute(
            QWebEngineSettings.WebAttribute.ErrorPageEnabled, False)
    except Exception:
        pass

    # ---- keep the screen awake while media plays ---------------------------
    media = {"audio": False, "video": False}
    engine_audio = {"on": False}
    try:
        from . import keepawake
        inhibitor = keepawake.ScreensaverInhibitor()
    except Exception:
        inhibitor = None

    def reconcile_media():
        if inhibitor is None:
            return
        if media["audio"] or media["video"] or engine_audio["on"]:
            inhibitor.inhibit("media playing")
        else:
            inhibitor.uninhibit()

    try:
        page.recentlyAudibleChanged.connect(
            lambda on: (engine_audio.__setitem__("on", bool(on)),
                        reconcile_media()))
    except Exception:
        pass
    app.aboutToQuit.connect(lambda: inhibitor and inhibitor.uninhibit())

    # ---- the page <-> app bridge ------------------------------------------
    windows = []
    channel_js = _webchannel_js()
    admin_opener = {"open": None}

    def manager_window(win, page_obj, manager_override, title):
        """Wire a view and page as a Manager window on the shared profile.

        The one wiring for a peer machine's window and for a same-origin
        ``window.open``: black page, dark error page, the video's fullscreen,
        the house's permissions and screen share, and the app bridge. Nothing
        is loaded here, so the caller can either set the URL itself (the
        engine's own popup request is then dropped) or return the page to an
        older binding's ``createWindow``.
        """
        black_page(page_obj, win)
        _allow_fullscreen(page_obj, win, qt)
        try:
            page_obj.settings().setAttribute(
                QWebEngineSettings.WebAttribute.ErrorPageEnabled, False)
        except Exception:
            pass
        errorpage.watch(page_obj)
        win.setWindowTitle(title or "JawnOS Machine")
        win.resize(900, 700)
        page_obj.certificateError.connect(_accept_certificate)
        peer_host = (urlparse(manager_override).hostname or "").lower()
        # A peer's Manager is a house origin too, so its host joins the shared
        # allowlist before this page loads anything.
        if peer_host:
            allowed_hosts.add(peer_host)
        _feature_permission(page_obj, qt, allowed_hosts, gps_on)
        _allow_screen_capture(page_obj, qt, allowed_hosts)
        _allow_clipboard(page_obj, qt)
        try:
            webauthn.install_webauthn(page_obj, win)
        except Exception:
            pass
        install_bridge(
            page_obj, win,
            peer_host,
            manager_override)

    def open_manager_window(url, manager_override, title):
        win = JawnView(settings, save_state=False)
        other = JawnPage(profile, win, on_new_window=open_new_window)
        win.setPage(other)
        manager_window(win, other, manager_override, title)
        win.setUrl(QUrl(url))
        win.show()
        windows.append(win)

        def _forget(*_):
            try:
                windows.remove(win)
            except ValueError:
                pass

        win.destroyed.connect(_forget)
        return other

    def manager_origin(url):
        """The scheme://host[:port] a Manager URL belongs to, for its bridge."""
        parsed = urlparse(url)
        if parsed.scheme in ("http", "https") and parsed.netloc:
            return "%s://%s" % (parsed.scheme, parsed.netloc)
        return manager_base

    def make_popup_page():
        """A hidden Manager window for an older binding's createWindow.

        The engine loads the requested URL into this page after returning; its
        first main-frame navigation is classified in ``JawnPage``, which shows
        the window for a Manager URL and closes it for anything else.
        """
        win = JawnView(settings, save_state=False)
        other = JawnPage(profile, win, on_new_window=open_new_window, popup=True)
        win.setPage(other)
        black_page(other, win)
        win.setWindowTitle("JawnOS")
        win.resize(900, 700)
        return other

    def open_new_window(url, pending=None):
        """Place a ``window.open``/``target=_blank`` URL, or drop it.

        ``pending`` is the page an older binding's ``createWindow`` already
        created (and is about to load ``url`` into); it is adopted for a
        Manager URL and closed otherwise. With the newer signal there is no
        pending page: a Manager URL gets a window of its own here, and the
        engine request that carried it is not accepted (it never loads), so a
        popup cannot load twice. Returns the page the engine may load into, or
        None once Browse or the desktop took the URL.
        """
        if url is None:
            return make_popup_page()
        kind = classify_new_window(url, host or "", allowed_hosts)
        if os.environ.get("JAWNOS_QT_DEBUG"):
            sys.stderr.write("qt-new-window kind=%s url=%s\n" % (kind, url))
        win = pending.parent() if pending is not None else None
        if kind == "manager":
            if pending is not None:
                if win is not None:
                    manager_window(win, pending, manager_origin(url), "JawnOS")
                    win.show()
                return pending
            open_manager_window(url, manager_origin(url), "JawnOS")
            return None
        if kind == "browse":
            try:
                _launch_browse(url, manager_base)
            except Exception:
                pass
        elif kind == "external":
            open_external(url)
        if win is not None:
            try:
                win.close()
            except Exception:
                pass
        return None

    def install_bridge(page_obj, view_obj, allowed_host, manager_base, extra_js=""):
        if QWebChannel is not None:
            channel = QWebChannel(page_obj)

            class PageBridge(QObject):
                @Slot(str, str)
                def postMessage(self, name, raw):
                    handle_message(name, raw, page_obj, view_obj, allowed_host,
                                   manager_base)

            handler = PageBridge(page_obj)
            channel.registerObject("jawnos", handler)
            page_obj.setWebChannel(channel)
            page_obj._jawn_channel = channel
            page_obj._jawn_handler = handler

        source = ""
        if extra_js:
            source = extra_js + "\n"
        if channel_js:
            source += channel_js + "\n"
        source += (_BRIDGE_SHIM_JS + "\n" + bridge.DESKTOP_MARKER_JS + "\n" +
                   bridge.BROWSE_BRIDGE_JS + "\n" + bridge.MEDIA_MONITOR_JS)
        if momentum_enabled():
            source += "\n" + _MOMENTUM_JS
        script = QWebEngineScript()
        script.setName("jawnos-bridge")
        script.setSourceCode(source)
        try:
            script.setInjectionPoint(
                QWebEngineScript.InjectionPoint.DocumentCreation)
            script.setWorldId(QWebEngineScript.ScriptWorldId.MainWorld)
        except Exception:
            script.setInjectionPoint(QWebEngineScript.DocumentCreation)
            script.setWorldId(QWebEngineScript.MainWorld)
        script.setRunsOnSubFrames(False)
        page_obj.scripts().insert(script)

    def handle_message(name, raw, page_obj, view_obj, allowed_host, manager_base):
        """Handle one page message; allowed_host is this window's manager host.

        It is the host the window's Manager belongs to (the primary's, or a
        peer's), not the URL of whatever page is loaded: a public page has a
        different origin and must not borrow the app key. ``manager_base`` is
        the window's Manager URL, which Browse opens with.
        """
        # The start menu's admin icon asks for the control panel. The panel is
        # defined later; until then (or on a machine without it) raise the view.
        if "admin" in raw:
            opener = admin_opener.get("open")
            if opener:
                opener()
            else:
                view_obj.showNormal()
                view_obj.raise_()
                view_obj.activateWindow()
            return
        try:
            message = json.loads(raw)
        except (ValueError, TypeError):
            return
        if not isinstance(message, dict):
            return
        action = message.get("action")
        if action == "ping":
            # A health check for --probe: no secret, so any origin may ask.
            msg_id = message.get("id") or ""
            if msg_id:
                page_obj.runJavaScript(
                    "window.__jawnAppResult && window.__jawnAppResult(%s, %s);"
                    % (json.dumps(msg_id),
                       json.dumps({"ok": True, "pong": True})))
            return
        if action not in ("app_pubkey", "app_sign", "media_state",
                          "open_manager", "browse"):
            return
        # Only the manager's own origin may use the bridge. A public page
        # loaded in this view must not be able to borrow the app's key.
        try:
            host = _qurl_host(page_obj.url())
        except Exception:
            host = ""
        if not host:
            # During a redirect/reload QWebEnginePage.url() can be empty while
            # the view already knows the committed origin.
            try:
                host = _qurl_host(view_obj.url())
            except Exception:
                pass
        allowed = set(LOOPBACK_HOSTS)
        if allowed_host:
            allowed.add(allowed_host)
        if host not in allowed:
            if os.environ.get("JAWNOS_QT_DEBUG"):
                sys.stderr.write("qt-bridge reject %s host=%r allowed=%r\n" % (
                    action, host, sorted(allowed)))
            # Answer a rejected caller so the page's app-login promise settles;
            # silence here left the gate on "Checking this app..." forever.
            msg_id = message.get("id") or ""
            if msg_id:
                page_obj.runJavaScript(
                    "window.__jawnAppResult && window.__jawnAppResult(%s, %s);"
                    % (json.dumps(msg_id),
                       json.dumps({"ok": False, "error": "unavailable"})))
            return
        if os.environ.get("JAWNOS_QT_DEBUG"):
            sys.stderr.write("qt-bridge %s host=%r allowed_host=%r\n" % (
                action, host, allowed_host))
        if action == "media_state":
            media["audio"] = bool(message.get("audio"))
            media["video"] = bool(message.get("video"))
            reconcile_media()
            return
        msg_id = message.get("id") or ""
        try:
            if action == "app_pubkey":
                reply = {"ok": True, "pubkey": bridge.app_public_pem(),
                         "kind": "ed25519"}
            elif action == "app_sign":
                reply = {"ok": True,
                         "signature": bridge.app_sign_b64(
                             (message.get("args") or {}).get("message"))}
            elif action == "open_manager":
                args = message.get("args") or {}
                url = args.get("url") or ""
                manager = args.get("manager") or url
                if url.startswith("/"):
                    base = manager if urlparse(manager).scheme in ("http", "https") else (manager_base or url)
                    url = urljoin(base, url)
                parsed = urlparse(url)
                if parsed.scheme not in ("https", "http") or not parsed.netloc:
                    raise ValueError("not a manager url")
                mparsed = urlparse(manager)
                if mparsed.scheme not in ("https", "http") or not mparsed.netloc:
                    manager = url
                open_manager_window(url, manager,
                                    args.get("name") or "JawnOS Machine")
                reply = {"ok": True}
            else:
                args = message.get("args") or {}
                url = args.get("url") or ""
                parsed = urlparse(url)
                if parsed.scheme not in ("http", "https") or not parsed.netloc:
                    raise ValueError("not a browse url")
                _launch_browse(
                    url, manager_base,
                    "measure" if args.get("mode") == "measure" else "browse",
                    str(args.get("app") or "")[:200],
                    str(args.get("uuid") or "")[:200])
                reply = {"ok": True}
        except Exception:
            # No cryptography on this machine, an unreadable key file, or a
            # bad URL. The page falls back to its open-in-the-app explanation.
            reply = {"ok": False, "error": "unavailable"}
        if msg_id:
            try:
                page_obj.runJavaScript(
                    "window.__jawnAppResult && window.__jawnAppResult(%s, %s);"
                    % (json.dumps(msg_id), json.dumps(reply)))
            except Exception:
                pass
        if os.environ.get("JAWNOS_QT_DEBUG"):
            sys.stderr.write("qt-bridge reply %s ok=%s error=%r\n" % (
                action, reply.get("ok"), reply.get("error")))

    # ---- fullscreen asked for by the page (a video) ------------------------
    def restore_window():
        if settings.get("maximized"):
            view.showMaximized()
        elif settings.get("fullscreen"):
            view.showFullScreen()
        else:
            view.showNormal()

    _allow_fullscreen(page, view, qt, restore_window)

    # ---- the launcher URL, and the bridge installation --------------------
    ticket = None if (args.url or args.probe) else ticket_url()
    manager = None if (args.url or args.probe) else manager_url(settings["jawn_dir"], ticket)
    manager_base = manager or args.url or ""
    login_pending = bool(ticket)
    kick = None
    host = port = None
    if manager:
        parsed = urlparse(manager)
        host = parsed.hostname or "127.0.0.1"
        port = parsed.port or 443
        allowed_hosts.add(host.lower())
    migration_pending = bool(manager)
    reloaded = {"done": False}

    # The pages are all built by now; from here on a window.open can place
    # itself (nothing loads before the view's setUrl at the end of main).
    new_window_handler["open"] = open_new_window

    install_bridge(page, view, host or "", manager_base,
                   device_seed_js(host, port) if manager else "")

    if args.probe:
        def _timeout():
            print("qt-probe " + json.dumps({"error": "timeout"}))
            app.exit(1)
        QTimer.singleShot(25000, _timeout)
        kick = _probe(page, app, qt)

    # ---- supervision and the tray -----------------------------------------

    def restart_self():
        try:
            view._save_state()
            os.execv(sys.executable,
                     [sys.executable, os.path.realpath(sys.argv[0])] + sys.argv[1:])
        except Exception as exc:
            sys.stderr.write(
                "jawnos-qt: updated - close and reopen to run it (%s)\n" % exc)

    def show_window():
        if view.isMinimized():
            view.showNormal()
        else:
            view.show()
        view.raise_()
        view.activateWindow()

    def call_core(fn):
        def runner():
            try:
                ok, message = fn()
                if not ok:
                    sys.stderr.write("jawnos-qt: %s\n" % message)
            except Exception as exc:
                sys.stderr.write("jawnos-qt: %s\n" % exc)

        threading.Thread(target=runner, daemon=True).start()

    class Quitter(QObject):
        done = Signal()

    quitter = Quitter()
    quitter.done.connect(app.quit)

    def quit_only():
        view._save_state()
        app.quit()

    def quit_and_stop():
        view._save_state()
        view.hide()
        with_ble = bool(settings.get("ble_with_jawn", True))

        def runner():
            try:
                core.stop_all(settings["jawn_dir"], with_ble)
            except Exception:
                pass
            quitter.done.emit()

        threading.Thread(target=runner, daemon=True).start()

    log_windows = []

    def show_log():
        win = LogWindow(core.jawn_log_path(settings["jawn_dir"]))
        log_windows.append(win)

        def _forget(*_):
            try:
                log_windows.remove(win)
            except ValueError:
                pass

        win.destroyed.connect(_forget)
        win.show()

    panel_holder = {"panel": None}

    def show_panel():
        if ControlPanel is None:
            show_window()
            return
        if panel_holder["panel"] is None:
            panel_holder["panel"] = ControlPanel(
                settings,
                {
                    "show_view": show_window,
                    "show_log": show_log,
                    "restart": restart_self,
                },
                parent=view,
            )
        panel_holder["panel"].show()
        panel_holder["panel"].raise_()
        panel_holder["panel"].activateWindow()

    admin_opener["open"] = show_panel
    if args.panel:
        QTimer.singleShot(0, show_panel)

    icon_path = os.path.join(DESKTOP_DIR, "icons", "jawnos.png")

    def make_tray():
        try:
            if not QSystemTrayIcon.isSystemTrayAvailable():
                return None
        except Exception:
            return None
        icon = QIcon(icon_path) if os.path.exists(icon_path) else QIcon.fromTheme("jawnos")
        tray = QSystemTrayIcon(icon, app)
        tray.setToolTip("JawnOS")
        menu = QMenu()
        for label, callback in (
            ("Control panel", show_panel),
            ("Show JawnOS", show_window),
            ("Start jawn", lambda: call_core(lambda: core.start_all(
                settings["jawn_dir"], settings.get("ble_with_jawn", True)))),
            ("Stop jawn", lambda: call_core(lambda: core.stop_all(
                settings["jawn_dir"], settings.get("ble_with_jawn", True)))),
            ("Restart jawn", lambda: call_core(lambda: core.restart_all(
                settings["jawn_dir"], settings.get("ble_with_jawn", True)))),
            ("Log", show_log),
            ("Quit and stop jawn", quit_and_stop),
            ("Quit", quit_only),
        ):
            action = menu.addAction(label)
            action.triggered.connect(callback)
        tray.setContextMenu(menu)
        try:
            trigger = QSystemTrayIcon.ActivationReason.Trigger
        except AttributeError:
            trigger = QSystemTrayIcon.Trigger
        tray.activated.connect(
            lambda reason: show_window() if reason == trigger else None)
        tray._menu = menu  # QSystemTrayIcon does not own the menu
        tray.show()
        return tray

    def tray_status(jawn_up, ble_up):
        if tray is None:
            return
        tray.setToolTip("JawnOS - jawn %s, BLE %s" % (
            "running" if jawn_up else "stopped",
            "running" if ble_up else "stopped"))
        _label, tone = core.jawn_status(jawn_up)
        try:
            tray.setIcon(tray_icon(icon_path, theme.TONES[tone]))
        except Exception:
            pass

    class LogWindow(QDialog):
        """A small tail of jawn's manager.log, refreshing every two seconds."""

        def __init__(self, path):
            super().__init__()
            self.path = path
            self.setWindowTitle("JawnOS log")
            self.resize(900, 600)
            self.text = QPlainTextEdit(self)
            self.text.setReadOnly(True)
            layout = QVBoxLayout(self)
            layout.addWidget(self.text)
            self.timer = QTimer(self)
            self.timer.timeout.connect(self.reload)
            self.timer.start(2000)
            self.reload()

        def reload(self):
            try:
                self.text.setPlainText(core.tail_log(self.path, 200))
                bar = self.text.verticalScrollBar()
                bar.setValue(bar.maximum())
            except Exception:
                pass

    class Supervisor(QObject):
        """The desktop tick: liveness, restart, update, reload."""

        status = Signal(bool, bool)
        note = Signal(str)
        reload = Signal()
        updated = Signal(str)

        def __init__(self, shell_settings, start_now):
            super().__init__()
            self._settings = shell_settings
            self._start_now = start_now
            self._busy = False
            self._check_at = 0.0
            self._restart_at = 0.0
            self._update_pending = None
            self._update_at = 0.0
            self._version = self._manager_version()
            self._timer = QTimer(self)
            self._timer.timeout.connect(self.tick)

        def start(self):
            self._timer.start(2000)
            QTimer.singleShot(800, self.tick)

        def _manager_version(self):
            try:
                with open(os.path.join(self._settings["jawn_dir"], "VERSION"),
                          encoding="utf-8") as fh:
                    return fh.read().strip()
            except OSError:
                return ""

        def tick(self):
            if self._busy:
                return
            self._busy = True
            threading.Thread(target=self._work, daemon=True).start()

        def _work(self):
            try:
                shell_settings = self._settings
                jawn_dir = shell_settings["jawn_dir"]
                with_ble = bool(shell_settings.get("ble_with_jawn", True))
                if self._start_now:
                    self._start_now = False
                    if not core.jawn_up(jawn_dir):
                        core.start_all(jawn_dir, with_ble)
                        self.note.emit("started jawn")
                        # The ticket/Manager load can have run before the port
                        # answered; load it again once the tree is up.
                        self.reload.emit()
                jawn = core.jawn_up(jawn_dir)
                ble = core.ble_up()
                self.status.emit(jawn, ble)
                now = time.monotonic()
                if now - self._check_at >= 60:
                    self._check_at = now
                    if jawn and now - self._restart_at >= 300:
                        stale = core.version_mismatch(jawn_dir)
                        if stale:
                            running, disk = stale
                            self._restart_at = now
                            # This tick blocks until the tree answers again, so
                            # tell the tray now: amber for the restart, not the
                            # green it last saw.
                            core.mark_start_requested()
                            self.status.emit(False, ble)
                            ok, message = core.restart_all(jawn_dir, with_ble)
                            self.note.emit(
                                ("restarted %s -> %s" % (running, disk))
                                if ok else ("restart failed: %s" % message))
                            if ok:
                                self.reload.emit()
                            jawn = core.jawn_up(jawn_dir)
                    newer = core.auto_update_available(shell_settings)
                    if newer:
                        if (self._update_pending == newer
                                and now - self._update_at >= 55):
                            self._update_pending = None
                            ok, name, _code = core.apply_update(shell_settings)
                            if ok:
                                self.updated.emit(name or "")
                            else:
                                self.note.emit("app update could not be applied")
                        else:
                            self._update_pending = newer
                            self._update_at = now
                    else:
                        self._update_pending = None
                    version = self._manager_version()
                    if version and version != self._version:
                        self._version = version
                        self.reload.emit()
            finally:
                self._busy = False

    class UiRelay(QObject):
        """A main-thread landing point for signals emitted by the tick thread."""

        @Slot(bool, bool)
        def status(self, jawn_up, ble_up):
            tray_status(jawn_up, ble_up)

        @Slot(str)
        def note(self, text):
            sys.stderr.write("jawnos-qt: %s\n" % text)

        @Slot(str)
        def updated(self, _name):
            restart_self()

        @Slot()
        def reload(self):
            QTimer.singleShot(6000, view.reload)

    tray = None
    tray = None
    if not args.probe and not args.no_tray:
        tray = make_tray()
    tray_holder["tray"] = tray
    app.setQuitOnLastWindowClosed(tray is None)
    view._tray = tray

    if not args.probe:
        supervisor = Supervisor(
            settings,
            start_now=(not args.url and not args.no_start))
        relay = UiRelay()
        supervisor.reload.connect(relay.reload)
        supervisor.updated.connect(relay.updated)
        supervisor.note.connect(relay.note)
        if tray is not None:
            supervisor.status.connect(relay.status)
        supervisor.start()

    load_failures = {"n": 0}

    def on_load(_ok):
        nonlocal login_pending, migration_pending
        if os.environ.get("JAWNOS_QT_DEBUG"):
            sys.stderr.write("qt-load ok=%s title=%r manager=%s pending=%s\n" % (
                _ok, view.title(), view.url().toString().endswith("/manager"), login_pending))
        if not _ok:
            # jawn may still be starting (the supervisor's first tick starts
            # it). Retry the same URL instead of leaving the window empty;
            # after the retries are spent, say so on the dark error page.
            load_failures["n"] += 1
            current = view.url().toString()
            retry = current if current.startswith(("http://", "https://")) else url
            if load_failures["n"] <= 40 and not args.probe:
                QTimer.singleShot(1500, lambda: view.setUrl(QUrl(retry)))
                return
            if not args.probe:
                page.setHtml(errorpage.dark_page(
                    "The Manager did not answer.",
                    retry,
                    hint="It may still be starting. Press Try again, or read "
                         "the log from the control panel."))
            return
        load_failures["n"] = 0
        if login_pending:
            # The ticket page mints the session cookie; give it a moment, the
            # same 1.5 s the WebKit shell allows, then load the Manager on the
            # ticket's own host (where the cookie is scoped).
            login_pending = False
            QTimer.singleShot(1500, lambda: view.setUrl(QUrl(manager)))
            return
        current = urlparse(view.url().toString())
        on_manager = (manager and current.hostname == host
                      and (current.port or 443) == port)
        if migration_pending and on_manager:
            migration_pending = False
            _path, data = webkit_localstorage(host, port)
            if data:
                def migrated(result):
                    if str(result) == "migrated" and not reloaded["done"]:
                        reloaded["done"] = True
                        QTimer.singleShot(250, view.reload)
                page.runJavaScript(_MIGRATE_JS % json.dumps(data), migrated)
            return
        if kick is not None:
            QTimer.singleShot(1200, kick)

    page.loadFinished.connect(on_load)

    if args.url:
        url = args.url
    elif ticket:
        url = ticket
    elif args.probe:
        url = _probe_url()
    else:
        url = manager
    view.setUrl(QUrl(url))
    if args.probe:
        view.resize(800, 600)
        view.show()
    elif settings.get("fullscreen"):
        view.showFullScreen()
    elif settings.get("maximized"):
        view.showMaximized()
    else:
        view.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
