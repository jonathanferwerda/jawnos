"""JawnOS in a Qt WebEngine view.

The default desktop shell is WebKitGTK. On Debian that build has no WebRTC
(``RTCPeerConnection`` is absent), so the chat and the screening's Connect me
cannot run in it. This shell is the same Manager page in Chromium: the
reference WebRTC implementation, the same engine family Android's WebView
uses, and a web engine that exists on Linux, Windows and macOS.

It is a prototype behind a flag, not the default:

    JAWNOS_DESKTOP_ENGINE=qt ./jawnos-desktop
    ./desktop/jawnos-qt --url https://house.example:3000/manager
    ./desktop/jawnos-qt --probe            # media/WebRTC support, then exit

The login is the same ticket the WebKit shell uses: loading the ticket URL
mints the cookie and redirects to the Manager, and the profile keeps that
cookie across launches. The first run also copies the GTK shell's page layout
out of WebKit's per-origin SQLite store, and the window geometry comes from
``~/.config/jawnos/desktop.json``, saved back on close. Certificate errors are accepted because the house
serves its own self-signed certificate on its own port (the same exception the
WebKit shell makes).
"""

import argparse
import glob
import json
import os
import sqlite3
import sys
from urllib.parse import urlparse

from . import core

# desktop/, resolved the same way the other entry scripts do it.
DESKTOP_DIR = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
ROOT_DIR = os.path.dirname(DESKTOP_DIR)


# --------------------------------------------------------------------------
# the same login the WebKit shell uses, without importing GK
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

    Same rule as ``webview.manager_url``: the cookie is scoped to the ticket's
    host, so the Manager must be loaded from that host; loopback is only the
    fallback for a plain local launch. Kept here, GTK-free, so this module can
    run on a machine with no WebKitGTK.
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
# the GTK shell's layout, moved into the Qt profile
# --------------------------------------------------------------------------

# Keys that belong to a live session or a device identity, not to the layout:
# a copied tab id makes two windows claim one tab, and the padlock's
# device_uuid is a credential, not a preference.
_SKIP_KEYS = frozenset((
    "browser_tab", "device_uuid", "jawnos_media_lock", "jawn_app_until",
    "lastSearchTime",
))


def webkit_localstorage(host, port, base=None):
    """The WebKitGTK localStorage for one origin, as ``{key: value}``.

    The GTK shell keeps the page's layout in WebKit's per-origin SQLite store
    (``~/.local/share/<app>/localstorage/https_<host>_<port>.localstorage``):
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
    layout: (function () {
      try { return localStorage.getItem('layout') || ''; } catch (e) { return ''; }
    })(),
    url: location.href
  };
  window.__jawn_qt_probe = JSON.stringify(out);
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


def _feature_permission(page, qt):
    """Grant this page the microphone (and camera) it asks for."""
    QWebEnginePage = qt["QWebEnginePage"]
    granted = set()
    for name in ("MediaAudioCapture", "MediaVideoCapture", "MediaAudioVideoCapture"):
        value = getattr(QWebEnginePage.Feature, name, None)
        if value is not None:
            granted.add(value)

    def decide(origin, feature):
        policy = (QWebEnginePage.PermissionPolicy.PermissionGrantedByUser
                  if feature in granted else
                  QWebEnginePage.PermissionPolicy.PermissionDeniedByUser)
        page.setFeaturePermission(origin, feature, policy)

    page.featurePermissionRequested.connect(decide)


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="jawnos-qt",
        description="JawnOS in a Qt WebEngine (Chromium) view")
    parser.add_argument("--url", help="load this URL instead of the stored ticket/manager")
    parser.add_argument("--probe", action="store_true",
                        help="print WebRTC/media support and exit")
    args = parser.parse_args(argv)

    try:
        from PySide6.QtCore import QTimer, QUrl
        from PySide6.QtWidgets import QApplication
        from PySide6.QtWebEngineCore import (
            QWebEnginePage,
            QWebEngineProfile,
            QWebEngineSettings,
        )
        from PySide6.QtWebEngineWidgets import QWebEngineView
    except Exception as exc:  # noqa: BLE001
        sys.stderr.write(
            "jawnos-qt needs PySide6 with Qt WebEngine "
            "(Debian: python3-pyside6.qtwebenginewidgets): %s\n" % exc)
        return 2

    qt = {
        "QTimer": QTimer,
        "QWebEnginePage": QWebEnginePage,
        "QWebEngineProfile": QWebEngineProfile,
        "QWebEngineSettings": QWebEngineSettings,
        "QWebEngineView": QWebEngineView,
    }

    app = QApplication([sys.argv[0]])
    app.setApplicationName("JawnOS")
    app.setOrganizationName("JawnOS")

    store = profile_dir()
    os.makedirs(os.path.join(store, "storage"), exist_ok=True)
    os.makedirs(os.path.join(store, "cache"), exist_ok=True)
    profile = QWebEngineProfile("jawnos", app)
    profile.setPersistentStoragePath(os.path.join(store, "storage"))
    profile.setCachePath(os.path.join(store, "cache"))
    profile.setPersistentCookiesPolicy(
        QWebEngineProfile.PersistentCookiesPolicy.ForcePersistentCookies)

    settings = core.load_settings()

    class JawnView(QWebEngineView):
        """The view, and the window state the GTK shell also keeps in desktop.json."""

        def __init__(self, shell_settings, save_state):
            super().__init__()
            self._shell_settings = shell_settings
            self._save_state = save_state

        def closeEvent(self, event):
            if self._save_state:
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
            super().closeEvent(event)

    view = JawnView(settings, not args.probe)
    page = QWebEnginePage(profile, view)
    view.setPage(page)
    view.setWindowTitle("JawnOS")
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
    _feature_permission(page, qt)

    page_settings = page.settings()
    page_settings.setAttribute(
        QWebEngineSettings.WebAttribute.PlaybackRequiresUserGesture, False)

    ticket = None if args.url else ticket_url()
    manager = None if args.url else manager_url(settings["jawn_dir"], ticket)
    login_pending = bool(ticket)
    kick = None
    host = port = None
    if manager:
        parsed = urlparse(manager)
        host = parsed.hostname or "127.0.0.1"
        port = parsed.port or 443
    migration_pending = bool(manager)
    reloaded = {"done": False}

    if args.probe:
        def _timeout():
            print("qt-probe " + json.dumps({"error": "timeout"}))
            app.exit(1)
        QTimer.singleShot(25000, _timeout)
        kick = _probe(page, app, qt)

    def on_load(_ok):
        nonlocal login_pending, migration_pending
        if os.environ.get("JAWNOS_QT_DEBUG"):
            sys.stderr.write("qt-load ok=%s title=%r manager=%s pending=%s\n" % (
                _ok, view.title(), view.url().toString().endswith("/manager"), login_pending))
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
        url = _BLANK
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
