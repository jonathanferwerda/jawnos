"""The toolkit-neutral half of the page <-> app bridge.

The embedded Manager page talks to the desktop app through
``window.webkit.messageHandlers.jawnos`` (app key, peer windows, media state)
and ``...jawnos_browse`` (the native Browse window). WebKitGTK registers those
handlers itself; the Qt WebEngine shell installs a shim that forwards the same
messages over QWebChannel. Both shells need the same app key, the same Browse
launcher and the same injected page scripts, so they live here instead of in
either shell module.
"""

import base64
import os
import shutil
import sys

from . import DESKTOP_DIR, core

# At document start the page can see that it is running inside the desktop app.
# universal.js keys its app login off this, the same way the phone keys off the
# Android bridge.
DESKTOP_MARKER_JS = "window.JawnDesktop = window.JawnDesktop || {};"

# The Internet app's Browse tab calls JawnBrowse.open(url, mode, app, uuid).
# This shim is the desktop half of that contract: a real browser window is a
# sibling process, so the manager page can only ask this app to start it. The
# handler is separate from the `jawnos` channel, which is the app-key/window
# bridge the manager already uses.
BROWSE_BRIDGE_JS = """
(function () {
    if (window.JawnBrowse) { return; }
    window.JawnBrowse = {
        open: function (url, mode, app, uuid) {
            try {
                window.webkit.messageHandlers.jawnos_browse.postMessage(JSON.stringify({
                    action: 'browse',
                    url: String(url || ''),
                    mode: mode === 'measure' ? 'measure' : 'browse',
                    app: String(app || ''),
                    uuid: String(uuid || '')
                }));
            } catch (e) {}
        }
    };
})();
"""

# Report whether the page is playing audio or video. WebKit's
# is-playing-audio only covers sound, so a muted video (or one with a silent
# track) left the desktop's own power manager to blank the display while it
# played. The page posts this to the same `jawnos` handler the key bridge uses;
# the shell reconciles it with the engine's own audio flag.
MEDIA_MONITOR_JS = """
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


# ---- the app's own identity -------------------------------------------------
# The manager is app-only: a browser has no key, so it cannot prove it is the
# installed app. The desktop app holds an Ed25519 key of its own (0600 in the
# config dir) and signs the server's challenge with it. The key never leaves
# the process except as a public half, so the page -- and any script running in
# it -- can ask for a signature but cannot copy the key.

def app_key_path():
    return os.path.join(core.config_dir(), "app_ed25519.pem")


def app_private_key():
    """Load the desktop app key, creating it at 0600 the first time."""
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

    path = app_key_path()
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


def app_public_pem():
    from cryptography.hazmat.primitives import serialization

    return app_private_key().public_key().public_bytes(
        serialization.Encoding.PEM,
        serialization.PublicFormat.SubjectPublicKeyInfo,
    ).decode("ascii")


def app_sign_b64(message_b64):
    """Sign the base64 message the page handed over; return base64(raw sig)."""
    raw = base64.b64decode(message_b64 or "")
    return base64.b64encode(app_private_key().sign(raw)).decode("ascii")


def browse_launcher():
    """The jawnos-browse entry beside this package, or one on PATH.

    A copy whose executable bit did not survive a copy is still runnable with
    this interpreter, so an installed tree keeps working through an update."""
    candidates = [
        os.path.join(DESKTOP_DIR, "jawnos-browse"),
        shutil.which("jawnos-browse"),
    ]
    for candidate in candidates:
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return [candidate]
    for candidate in candidates:
        if candidate and os.path.isfile(candidate):
            return [sys.executable or "python3", candidate]
    return None
