"""``jawnos-shell`` -- the JawnOS session bar for Sway, in Qt.

A thin PySide6 panel along the top of the screen. On a Wayland compositor it
claims the wlr-layer-shell "top" layer with an exclusive zone, so windows tile
below it instead of under it; on X11 (or when layer-shell is unavailable) it is
a frameless, always-on-top window placed at the screen edge. Left to right it
shows:

* a launcher (fuzzel, or a Qt command dialog when fuzzel is not installed),
* one button per Sway workspace (click switches; ``swaymsg workspace <name>``),
* the focused app's icon and name (read from Sway's tree),
* today's recorded app time (the manager's usage summary, every minute),
* an optional now-playing line (``playerctl``, when present),
* the clock and date.

The GTK bar used ``gtk-layer-shell``. PySide6 has no layer-shell bindings and
layer-shell-qt ships no C API, only C++ symbols, so :class:`_LayerShell` is a
small ctypes shim over ``libLayerShellQtInterface.so``: it resolves
``LayerShellQt::Window::get`` and the integer setters, hands the library the
QWindow PySide6 created, and then shows the window. That gives the same top
layer, anchors, exclusive zone and keyboard mode the GTK bar had. The package
(``layer-shell-qt``) is optional: without it, or on a compositor that does not
implement wlr-layer-shell, the bar falls back to a frameless always-on-top
window. On Sway the fallback asks ``swaymsg`` to float it at 0,0, size it to the
output and make it sticky -- it then overlays windows rather than reserving an
exclusive zone, and a fullscreen window covers it.

Nothing here blocks the Qt main loop: the Sway event subscription, the periodic
Sway poll, the manager request and playerctl all run on daemon threads and hand
their results back through Qt signals (queued onto the GUI thread). Every
optional tool is probed at startup and simply left out when it is missing, so a
session with no swaymsg, no manager or no playerctl still gets a working bar.
"""

import argparse
import ctypes
import datetime
import json
import logging
import os
import shutil
import signal
import subprocess
import sys
import threading
import time

from . import DESKTOP_DIR
from . import usage

LOG = logging.getLogger("jawnos.shell")

# One row; keep it thin. The exclusive zone asks Sway to keep windows below it.
BAR_HEIGHT = 30
# How often the worker wakes to look for work. This is a 2 Hz check, not a busy
# loop: a Sway event only sets a flag and the next tick does the query.
POLL_SECONDS = 0.5
# A safety-net re-read even when no event arrives, and the slower clocks.
SWAY_POLL_SECONDS = 10.0
USAGE_SECONDS = 60.0
MUSIC_SECONDS = 5.0


# --------------------------------------------------------------------------
# Optional imports
# --------------------------------------------------------------------------

_QT_ERROR = None
try:
    from PySide6.QtCore import QObject, Qt, QTimer, Signal
    from PySide6.QtGui import QFontMetrics, QGuiApplication, QIcon
    from PySide6.QtWidgets import (
        QApplication,
        QHBoxLayout,
        QInputDialog,
        QLabel,
        QPushButton,
        QStyle,
        QVBoxLayout,
        QWidget,
    )
except Exception as exc:  # ImportError, or a broken Qt installation
    _QT_ERROR = exc
    # Stand-ins so this module still imports and main() can report the reason.
    QObject = QWidget = object

    def Signal(*_args, **_kwargs):
        return None

    QApplication = QHBoxLayout = QInputDialog = QLabel = None
    QPushButton = QStyle = QVBoxLayout = None
    QFontMetrics = QGuiApplication = QIcon = None
    Qt = QTimer = None


# --------------------------------------------------------------------------
# layer-shell-qt: a ctypes shim over the C++ interface
# --------------------------------------------------------------------------

class _LayerShell:
    """Attach one QWindow to wlr-layer-shell through layer-shell-qt.

    layer-shell-qt (the ``layer-shell-qt`` package) exposes
    ``LayerShellQt::Window`` as C++ only, with no ``extern "C"`` wrapper. The
    library is designed so that ``Window::get(QWindow *)`` installs an event
    filter and, when the platform surface is created, replaces the window's
    shell integration with a layer surface; the setters below then define the
    layer, anchors, exclusive zone and keyboard mode. We resolve those exact
    symbols and pass the QWindow pointer PySide6 already owns, so the library
    does the Wayland work in-process, exactly as a C++ client would.

    Every entry point is optional: if the library, a symbol or a wayland QWindow
    is missing the caller falls back to an ordinary window. Only the integer
    setters are used, which keeps the ABI simple (``QFlags<Anchor>`` and the
    enums are all a C ``int`` on the wire); the scope keeps its default.
    """

    # LayerShellQt::Window::Anchor
    ANCHOR_TOP = 1
    ANCHOR_BOTTOM = 2
    ANCHOR_LEFT = 4
    ANCHOR_RIGHT = 8
    # LayerShellQt::Window::LayerTop
    LAYER_TOP = 2
    # LayerShellQt::Window::KeyboardInteractivityNone
    KEYBOARD_NONE = 0

    # The mangled names are the stable Qt-style symbols from layer-shell-qt
    # 6.x (checked on the 6.3 and 6.8 libraries).
    _SYMBOLS = {
        "get": "_ZN12LayerShellQt6Window3getEP7QWindow",
        "anchors": "_ZN12LayerShellQt6Window10setAnchorsE6QFlagsINS0_6AnchorEE",
        "zone": "_ZN12LayerShellQt6Window16setExclusiveZoneEi",
        "layer": "_ZN12LayerShellQt6Window8setLayerENS0_5LayerE",
        "keyboard": "_ZN12LayerShellQt6Window24setKeyboardInteractivityENS0_21KeyboardInteractivityE",
    }

    def __init__(self):
        self._lib = None
        self._funcs = {}
        self._tried = False

    def available(self):
        self._load()
        return self._lib is not None

    def _load(self):
        if self._lib is not None or self._tried:
            return self._lib is not None
        self._tried = True
        try:
            from ctypes.util import find_library
            candidates = [
                find_library("LayerShellQtInterface"),
                "libLayerShellQtInterface.so.6",
                "libLayerShellQtInterface.so",
            ]
        except Exception:
            candidates = []

        for name in candidates:
            if not name:
                continue
            try:
                lib = ctypes.CDLL(name)
            except OSError as exc:
                LOG.debug("layer-shell-qt %s would not load: %s", name, exc)
                continue
            funcs = {}
            for key, symbol in self._SYMBOLS.items():
                try:
                    funcs[key] = getattr(lib, symbol)
                except AttributeError:
                    funcs = {}
                    break
            if not funcs:
                LOG.debug("layer-shell-qt %s has no expected symbols", name)
                continue
            funcs["get"].restype = ctypes.c_void_p
            funcs["get"].argtypes = [ctypes.c_void_p]
            for key in ("anchors", "zone", "layer", "keyboard"):
                funcs[key].restype = None
                funcs[key].argtypes = [ctypes.c_void_p, ctypes.c_int]
            self._lib = lib
            self._funcs = funcs
            LOG.info("using layer-shell-qt (%s)", name)
            return True
        return False

    def claim(self, widget, height):
        """Make ``widget`` a top-layer panel; False means use the fallback."""
        if QGuiApplication is None:
            return False
        if QGuiApplication.platformName() != "wayland":
            return False
        if not self._load():
            return False
        try:
            import shiboken6

            # createWinId() gives us the QWindow but does not map it: the
            # layer surface is created on show(), after the setters below.
            widget.createWinId()
            handle = widget.windowHandle()
            if handle is None:
                return False
            pointer = shiboken6.getCppPointer(handle)
            if isinstance(pointer, (tuple, list)):
                pointer = pointer[0]
            else:
                pointer = int(pointer)

            window = self._funcs["get"](ctypes.c_void_p(pointer))
            if not window:
                return False
            ref = ctypes.c_void_p(window)
            anchors = self.ANCHOR_TOP | self.ANCHOR_LEFT | self.ANCHOR_RIGHT
            self._funcs["anchors"](ref, anchors)
            self._funcs["layer"](ref, self.LAYER_TOP)
            self._funcs["zone"](ref, int(height))
            self._funcs["keyboard"](ref, self.KEYBOARD_NONE)
            return True
        except Exception as exc:
            LOG.warning("layer-shell-qt could not claim the bar (%s); "
                        "using a normal window", exc)
            return False


_LAYER_SHELL = _LayerShell()


# --------------------------------------------------------------------------
# Presentation helpers
# --------------------------------------------------------------------------

# The bar is the desktop's own chrome, so it uses the same near-black ground and
# jawn yellow as the dashboard. The selectors are scoped to #bar so only the bar
# picks them up (the fallback launcher dialog keeps the desktop theme).
_QSS = """
QWidget#bar { background-color: #0d0d0d; }
QWidget#bar QLabel { color: #ededed; font-size: 12px; }
QWidget#bar QLabel[dim="true"] { color: #8e8e8e; }
QWidget#bar QLabel[offline="true"] { color: #6b6b6b; }
QWidget#bar QLabel#time { font-weight: bold; }
QWidget#bar QLabel#app-name { font-weight: bold; }
QWidget#bar QPushButton {
    background-color: transparent; border: none; padding: 0 7px;
    border-radius: 6px; color: #ededed;
}
QWidget#bar QPushButton:hover { background-color: #262626; }
QWidget#bar QPushButton[ws="true"] {
    color: #8e8e8e; min-width: 18px; padding: 0 5px;
}
QWidget#bar QPushButton[ws="true"][active="true"] {
    background-color: #ffcc00; color: #0a0a0a; font-weight: bold;
}
QWidget#bar QPushButton[ws="true"][urgent="true"] { color: #ff453a; }
QWidget#bar QPushButton#launcher {
    background-color: #ffcc00; color: #0a0a0a; font-weight: bold;
    padding: 0 10px;
}
QWidget#bar QPushButton#launcher:hover { background-color: #e6b800; }
"""

# Friendly names for the app ids the session actually sees. Anything else falls
# back to the last dotted segment, so an unfamiliar app still reads sensibly.
_PRETTY_APPS = {
    "foot": "Terminal",
    "dev.zed.zed": "Zed",
    "zed": "Zed",
    "org.gnome.nautilus": "Files",
    "org.gnome.console": "Console",
    "org.gnome.texteditor": "Text Editor",
    "org.gnome.calculator": "Calculator",
    "jawnos-desktop": "JawnOS",
    "firefox": "Firefox",
    "org.mozilla.firefox": "Firefox",
    "chromium": "Chromium",
    "org.chromium.chromium": "Chromium",
    "google-chrome": "Chrome",
    "code": "VS Code",
    "org.videolan.vlc": "VLC",
    "mpv": "mpv",
}

# Icon names to try before the raw app id. The theme is asked for each in turn;
# a miss just means the generic executable icon is used.
_APP_ICONS = {
    "foot": "utilities-terminal",
    "org.gnome.console": "utilities-terminal",
    "org.gnome.nautilus": "system-file-manager",
    "dev.zed.zed": "text-editor",
    "zed": "text-editor",
    "org.gnome.texteditor": "accessories-text-editor",
    "org.gnome.calculator": "accessories-calculator",
}


def _pretty_app_name(key):
    low = (key or "").strip().lower()
    if not low:
        return ""
    if low in _PRETTY_APPS:
        return _PRETTY_APPS[low]
    base = key.rsplit(".", 1)[-1].replace("_", " ").replace("-", " ").strip()
    return base[:1].upper() + base[1:] if base else key


def _icon_candidates(key):
    low = (key or "").lower()
    names = []
    mapped = _APP_ICONS.get(low)
    if mapped:
        names.append(mapped)
    names.extend((key, low, low.replace(".", "-"), low.rsplit(".", 1)[-1]))
    unique = []
    for name in names:
        if name and name not in unique:
            unique.append(name)
    return unique


def _sway_quote(text):
    """Quote one Sway command argument (names may contain spaces or quotes)."""
    return '"' + str(text).replace("\\", "\\\\").replace('"', '\\"') + '"'


def _sway_env():
    """Pass SWAYSOCK through when only I3SOCK was exported (mirrors usage)."""
    env = dict(os.environ)
    if not env.get("SWAYSOCK") and env.get("I3SOCK"):
        env["SWAYSOCK"] = env["I3SOCK"]
    return env


def _desktop_blocks_layer_shell():
    """True on a desktop that does not implement wlr-layer-shell.

    The library can be installed on a GNOME or KDE box where the compositor has
    no such protocol; attempting to map a layer surface there is worse than the
    plain-window fallback. Sway, Hyprland and labwc name themselves in
    XDG_CURRENT_DESKTOP and pass this check.
    """
    desktop = (os.environ.get("XDG_CURRENT_DESKTOP") or "").lower()
    return any(name in desktop for name in (
        "gnome", "kde", "plasma", "unity", "cinnamon", "mate", "xfce"))


def _tree_find_app(node, app_id):
    """The first Sway tree node whose app_id matches, or None."""
    if not isinstance(node, dict):
        return None
    if node.get("app_id") == app_id:
        return node
    for key in ("nodes", "floating_nodes"):
        for child in node.get(key) or []:
            hit = _tree_find_app(child, app_id)
            if hit is not None:
                return hit
    return None


def _prepare_wayland_env():
    """Point Qt at Wayland when the session is Wayland.

    Qt may still choose xcb (Sway exports DISPLAY for XWayland); the layer-shell
    integration needs a QWaylandWindow. An explicit QT_QPA_PLATFORM always wins.
    """
    if not os.environ.get("WAYLAND_DISPLAY"):
        return
    if not os.environ.get("QT_QPA_PLATFORM"):
        os.environ["QT_QPA_PLATFORM"] = "wayland"


# --------------------------------------------------------------------------
# The bar
# --------------------------------------------------------------------------

class _Signals(QObject):
    """Worker -> GUI hand-off (Qt queues these onto the GUI thread)."""

    sway = Signal(object, str, str)
    usage = Signal(str, bool)
    music = Signal(object)
    quit = Signal()


class Shell(QWidget):
    """The bar window and the widgets inside it."""

    def __init__(self, args):
        super().__init__()
        self.args = args
        self.height = max(18, min(64, int(args.height)))
        self.jawn_dir = args.jawn_dir
        self.music_enabled = not args.no_music
        self.worker = None
        self._ws_signature = None
        self._icon_cache = {}
        self.using_layer_shell = False
        self.clock_timer = None

        self.signals = _Signals(self)
        self.setObjectName("bar")
        self.setWindowTitle("JawnOS")
        self.setFixedHeight(self.height)
        self.setStyleSheet(_QSS)

        self._claim_surface()
        self._build()

        self.signals.sway.connect(self.apply_sway)
        self.signals.usage.connect(self.set_usage)
        self.signals.music.connect(self.set_music)
        self.signals.quit.connect(self.quit)

    # ---- window shape ----------------------------------------------------

    def _claim_surface(self):
        """Become a layer-shell panel, or the best ordinary window available."""
        if not self.args.no_layer_shell and not _desktop_blocks_layer_shell():
            if QGuiApplication.platformName() == "wayland":
                if _LAYER_SHELL.claim(self, self.height):
                    self.using_layer_shell = True
                    LOG.info("session bar is a layer-shell panel (%dpx)",
                             self.height)
                    return
                LOG.warning("layer-shell-qt is not available; using a "
                            "frameless window. On Sway the bar will float over "
                            "the workspace rather than reserve an edge.")
            else:
                LOG.info("not a Wayland session; using a frameless window")
        elif self.args.no_layer_shell:
            LOG.info("--no-layer-shell: using a frameless window")
        else:
            LOG.warning("%s does not implement wlr-layer-shell; using a "
                        "frameless window",
                        os.environ.get("XDG_CURRENT_DESKTOP"))

        # A dock on X11; on Wayland Sway treats it as an ordinary toplevel. It
        # never takes focus on show, matching the layer-shell keyboard mode.
        self.setWindowFlags(Qt.WindowType.FramelessWindowHint
                            | Qt.WindowType.WindowStaysOnTopHint
                            | Qt.WindowType.Tool)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating, True)

    # ---- widgets ---------------------------------------------------------

    def _build(self):
        outer = QHBoxLayout(self)
        outer.setContentsMargins(4, 2, 4, 2)
        outer.setSpacing(6)
        outer.setAlignment(Qt.AlignmentFlag.AlignVCenter)

        left = QWidget()
        left_box = QHBoxLayout(left)
        left_box.setContentsMargins(0, 0, 0, 0)
        left_box.setSpacing(6)
        left_box.setAlignment(Qt.AlignmentFlag.AlignVCenter)

        self.launcher = QPushButton("Jawn")
        self.launcher.setObjectName("launcher")
        self.launcher.setCursor(Qt.CursorShape.PointingHandCursor)
        self.launcher.setToolTip("Open the launcher")
        self.launcher.clicked.connect(self._on_launcher)
        left_box.addWidget(self.launcher)

        self.ws_box = QWidget()
        self.ws_layout = QHBoxLayout(self.ws_box)
        self.ws_layout.setContentsMargins(0, 0, 0, 0)
        self.ws_layout.setSpacing(2)
        self.ws_layout.setAlignment(Qt.AlignmentFlag.AlignVCenter)
        left_box.addWidget(self.ws_box)

        self.app_box = QWidget()
        app_layout = QHBoxLayout(self.app_box)
        app_layout.setContentsMargins(0, 0, 0, 0)
        app_layout.setSpacing(5)
        app_layout.setAlignment(Qt.AlignmentFlag.AlignVCenter)
        self.app_icon = QLabel()
        self.app_icon.setFixedSize(16, 16)
        app_layout.addWidget(self.app_icon)
        self.app_label = QLabel("")
        self.app_label.setObjectName("app-name")
        app_layout.addWidget(self.app_label)
        left_box.addWidget(self.app_box)

        outer.addWidget(left, 0, Qt.AlignmentFlag.AlignVCenter)

        right = QWidget()
        right_box = QHBoxLayout(right)
        right_box.setContentsMargins(0, 0, 0, 0)
        right_box.setSpacing(12)
        right_box.setAlignment(Qt.AlignmentFlag.AlignVCenter)

        self.usage_label = QLabel("Today \u2014")
        self.usage_label.setProperty("dim", True)
        self.usage_label.setToolTip("Recorded app time today")
        right_box.addWidget(self.usage_label)

        self.music_label = QLabel("")
        self.music_label.setProperty("dim", True)
        self.music_label.setVisible(False)
        right_box.addWidget(self.music_label)

        clock = QWidget()
        clock_layout = QVBoxLayout(clock)
        clock_layout.setContentsMargins(0, 0, 0, 0)
        clock_layout.setSpacing(0)
        clock_layout.setAlignment(Qt.AlignmentFlag.AlignVCenter)
        self.time_label = QLabel("")
        self.time_label.setObjectName("time")
        self.date_label = QLabel("")
        self.date_label.setProperty("dim", True)
        clock_layout.addWidget(self.time_label)
        clock_layout.addWidget(self.date_label)
        right_box.addWidget(clock)

        outer.addStretch(1)
        outer.addWidget(right, 0, Qt.AlignmentFlag.AlignVCenter)
        self._tick_clock()

    def _elide(self, label, text, chars=34):
        """Elide like GTK's max-width-chars, keeping the full text as a tooltip."""
        if not text:
            return ""
        metrics = QFontMetrics(label.font())
        width = max(60, metrics.averageCharWidth() * chars)
        return metrics.elidedText(text, Qt.TextElideMode.ElideRight, width)

    def _repolish(self, widget):
        style = widget.style()
        style.unpolish(widget)
        style.polish(widget)
        widget.update()

    # ---- clock -----------------------------------------------------------

    def _tick_clock(self):
        now = datetime.datetime.now()
        self.time_label.setText(now.strftime("%H:%M"))
        self.date_label.setText(now.strftime("%a %d %b"))

    # ---- Sway: workspaces and focus -------------------------------------

    def apply_sway(self, workspaces, key, title):
        """Called on the GUI thread with a completed Sway read."""
        # An empty list is how a failed query looks; keep the last indicators
        # rather than flickering them away (Sway always has one workspace).
        if workspaces:
            self._render_workspaces(workspaces)
        self._render_app(key, title)

    def _render_workspaces(self, workspaces):
        clean = [w for w in workspaces if isinstance(w, dict)]
        signature = tuple(
            (str(w.get("name") or w.get("num") or ""),
             bool(w.get("focused")), bool(w.get("urgent")),
             bool(w.get("visible")))
            for w in clean
        )
        if signature == self._ws_signature:
            return
        self._ws_signature = signature

        while self.ws_layout.count():
            item = self.ws_layout.takeAt(0)
            widget = item.widget()
            if widget is not None:
                widget.deleteLater()

        for workspace in clean:
            name = str(workspace.get("name") or workspace.get("num") or "?")
            button = QPushButton(name)
            button.setProperty("ws", True)
            button.setProperty("active", bool(workspace.get("focused")))
            button.setProperty("urgent", bool(workspace.get("urgent"))
                               and not workspace.get("focused"))
            button.setToolTip("Switch to workspace %s" % name)
            button.setCursor(Qt.CursorShape.PointingHandCursor)
            button.clicked.connect(
                lambda _checked=False, n=name: self._on_workspace(n))
            self.ws_layout.addWidget(button)
        self._repolish(self.ws_box)

    def _render_app(self, key, title):
        if not key:
            self.app_label.setText("")
            self.app_icon.clear()
            self.app_icon.setVisible(False)
            self.app_box.setToolTip("")
            return
        self.app_label.setText(self._elide(self.app_label, _pretty_app_name(key)))
        self.app_box.setToolTip(title or key)
        icon = self._icon_for(key)
        if icon is not None and not icon.isNull():
            self.app_icon.setPixmap(icon.pixmap(16, 16))
            self.app_icon.setVisible(True)
        else:
            self.app_icon.clear()
            self.app_icon.setVisible(False)

    def _icon_for(self, key):
        low = (key or "").lower()
        if low in self._icon_cache:
            return self._icon_cache[low]
        icon = None
        if low.startswith("jawnos"):
            path = os.path.join(DESKTOP_DIR, "icons", "jawnos.png")
            if os.path.exists(path):
                icon = QIcon(path)
                if icon.isNull():
                    icon = None
        if icon is None:
            for candidate in _icon_candidates(key):
                icon = QIcon.fromTheme(candidate)
                if not icon.isNull():
                    break
        if icon is None or icon.isNull():
            icon = QIcon.fromTheme("application-x-executable")
        if icon is None or icon.isNull():
            icon = self.style().standardIcon(QStyle.StandardPixmap.SP_FileIcon)
        self._icon_cache[low] = icon
        return icon

    def _on_workspace(self, name):
        def switch():
            try:
                usage.swaymsg(["-t", "command",
                               "workspace " + _sway_quote(name)])
            except Exception as exc:
                LOG.debug("workspace switch to %s failed: %s", name, exc)

        threading.Thread(target=switch, name="jawnos-shell-workspace",
                         daemon=True).start()

    # ---- launcher --------------------------------------------------------

    def _on_launcher(self):
        exe = shutil.which("fuzzel")
        if exe:
            try:
                subprocess.Popen([exe], env=_sway_env())
                return
            except OSError as exc:
                LOG.warning("fuzzel would not start (%s); using the built-in "
                            "prompt", exc)

        # No parent: a layer surface cannot parent an xdg_toplevel. The dialog
        # is its own window and takes the keyboard normally when opened.
        text, ok = QInputDialog.getText(None, "Run", "Command")
        text = (text or "").strip()
        if not ok or not text:
            return
        try:
            subprocess.Popen(["/bin/sh", "-c", text], env=_sway_env())
        except OSError as exc:
            LOG.warning("could not run %r: %s", text, exc)

    # ---- manager: today's app time --------------------------------------

    def set_usage(self, text, ok):
        self.usage_label.setText(text)
        self.usage_label.setProperty("offline", not ok)
        self._repolish(self.usage_label)

    # ---- playerctl: now playing -----------------------------------------

    def set_music(self, text):
        if text:
            elided = self._elide(self.music_label, text)
            self.music_label.setText(elided)
            self.music_label.setToolTip(text)
            self.music_label.setVisible(True)
        else:
            self.music_label.setVisible(False)

    # ---- lifecycle -------------------------------------------------------

    def start(self):
        self.show()
        LOG.debug("bar size hint %s, minimum %s, font height %d",
                  self.sizeHint(), self.minimumSizeHint(),
                  self.fontMetrics().height())
        self._tick_clock()
        self.clock_timer = QTimer(self)
        self.clock_timer.timeout.connect(self._tick_clock)
        self.clock_timer.start(1000)

        self.worker = _Worker(self)
        self.worker.start()

        if not self.using_layer_shell:
            if QGuiApplication.platformName().startswith("wayland"):
                # Wait for Sway to map the window, off the GUI thread.
                threading.Thread(target=self._place_sway_window,
                                 name="jawnos-shell-place", daemon=True).start()
            else:
                QTimer.singleShot(50, self._place_x11)

    def _place_x11(self):
        screen = QGuiApplication.primaryScreen()
        if screen is None:
            return
        geometry = screen.geometry()
        self.setGeometry(geometry.x(), geometry.y(),
                         geometry.width(), self.height)
        self.raise_()

    def _place_sway_window(self):
        """Float the fallback bar at the output's top edge (no layer role).

        A normal Wayland toplevel cannot reserve an exclusive zone, so this asks
        Sway to float it at 0,0, fill the output width, and stick it to every
        workspace. It then overlays windows: a fullscreen window covers it.

        The criteria command only sees windows Sway has already mapped, and
        ``show()`` returns before that commit, so wait (briefly, up to 5 s) for
        the app_id to appear in the tree. Runs on a daemon thread: swaymsg is a
        blocking subprocess and must never stall the bar.
        """
        if not usage.swaymsg_available():
            return
        try:
            outputs = [o for o in (usage.swaymsg(["-t", "get_outputs"]) or [])
                       if isinstance(o, dict)]
            width = 0
            for output in outputs:
                if output.get("focused") or output.get("active"):
                    width = int((output.get("rect") or {}).get("width") or 0)
                    if width:
                        break
            if not width:
                for output in outputs:
                    width = int((output.get("rect") or {}).get("width") or 0)
                    if width:
                        break
            if not width:
                width = 1024
            for _attempt in range(20):
                if _tree_find_app(usage.get_tree(), "jawnos-session"):
                    break
                time.sleep(0.25)
            # Sway refuses to make a floating window shorter than 50px
            # (floating_minimum_size, default 75x50). Lower the height floor --
            # only as far as the bar itself -- so a 30px bar is possible.
            if self.height < 50:
                usage.swaymsg(["-t", "command",
                               "floating_minimum_size 75 x %d" % self.height])
            # Resize before moving: Sway re-centres a floating window when its
            # size changes, so a move first would be undone.
            command = (
                '[app_id="jawnos-session"] floating enable, border none, '
                'resize set width %d px height %d px, move position 0 0, '
                'sticky enable' % (width, self.height))
            usage.swaymsg(["-t", "command", command])
        except Exception as exc:
            LOG.debug("could not place the fallback bar in Sway: %s", exc)

    def stop(self):
        if self.worker is not None:
            self.worker.stop_now()
            self.worker = None

    def quit(self):
        self.stop()
        if QApplication is not None:
            QApplication.quit()

    def closeEvent(self, event):
        self.stop()
        super().closeEvent(event)
        if QApplication is not None:
            QApplication.quit()


# --------------------------------------------------------------------------
# Background work
# --------------------------------------------------------------------------

class _Worker(threading.Thread):
    """Sway events plus the slow clocks, all off the GUI thread."""

    def __init__(self, shell):
        super().__init__(name="jawnos-shell-worker", daemon=True)
        self.shell = shell
        self.signals = shell.signals
        self.stop = threading.Event()
        self._want_sway = threading.Event()
        self._client = None
        self._last_sway = 0.0
        self._last_usage = 0.0
        self._last_music = 0.0
        self._sway_warned = False
        self._playerctl = (shutil.which("playerctl")
                           if shell.music_enabled else None)
        self._sway_reader = None
        self._proc = None
        self._proc_lock = threading.Lock()

    def stop_now(self):
        """Stop the loops and end the swaymsg subscription, if one is open."""
        self.stop.set()
        with self._proc_lock:
            proc = self._proc
        if proc is not None:
            try:
                proc.terminate()
            except OSError:
                pass

    def _emit(self, signal, *args):
        try:
            signal.emit(*args)
        except Exception:
            # The window can be gone while a refresh is in flight.
            pass

    # ---- main loop -------------------------------------------------------

    def run(self):
        if usage.swaymsg_available():
            self._sway_reader = threading.Thread(
                target=self._read_sway, name="jawnos-shell-sway", daemon=True)
            self._sway_reader.start()
        else:
            LOG.warning("swaymsg was not found; the workspace and focus "
                        "indicators stay empty")

        self._refresh_sway()
        while not self.stop.wait(POLL_SECONDS):
            now = time.monotonic()
            if self._want_sway.is_set() or \
                    now - self._last_sway >= SWAY_POLL_SECONDS:
                self._want_sway.clear()
                self._refresh_sway()
            if now - self._last_usage >= USAGE_SECONDS:
                self._refresh_usage()
            if self._playerctl and now - self._last_music >= MUSIC_SECONDS:
                self._refresh_music()

    # ---- Sway ------------------------------------------------------------

    def _read_sway(self):
        """Subscribe to window/workspace events; set a flag on each one."""
        while not self.stop.is_set():
            proc = None
            try:
                proc = subprocess.Popen(
                    ["swaymsg", "-t", "subscribe",
                     '["window","workspace","shutdown"]'],
                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                    text=True, bufsize=1, env=_sway_env())
                with self._proc_lock:
                    self._proc = proc
                for line in proc.stdout:
                    if self.stop.is_set():
                        break
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        event = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(event, dict):
                        continue
                    if event.get("change") == "exit" and \
                            "container" not in event and \
                            "current" not in event:
                        LOG.info("Sway is exiting; closing the session bar")
                        self._emit(self.signals.quit)
                        self.stop.set()
                        break
                    if "container" in event or "current" in event or \
                            event.get("change") in ("focus", "new", "close",
                                                    "move", "urgent",
                                                    "rename", "reload"):
                        self._want_sway.set()
            except OSError as exc:
                if not self._sway_warned:
                    self._sway_warned = True
                    LOG.warning("could not subscribe to Sway events: %s", exc)
            except Exception as exc:
                LOG.debug("Sway subscription ended: %s", exc)
            finally:
                with self._proc_lock:
                    if self._proc is proc:
                        self._proc = None
                if proc is not None:
                    try:
                        proc.terminate()
                        proc.wait(timeout=2)
                    except Exception:
                        try:
                            proc.kill()
                        except OSError:
                            pass
            if not self.stop.is_set():
                self.stop.wait(5)

    def _refresh_sway(self):
        self._last_sway = time.monotonic()
        if not usage.swaymsg_available():
            return
        try:
            workspaces = usage.get_workspaces()
            tree = usage.get_tree()
            key, ok = usage.focused_key_from_tree(tree)
            if not ok:
                # A transient IPC miss must not blank the current indicator.
                return
            title = ""
            if key:
                node = usage.focused_container(tree)
                if isinstance(node, dict):
                    title = (node.get("name") or "").strip()
            self._emit(self.signals.sway, workspaces, key or "", title)
        except Exception as exc:
            LOG.debug("Sway refresh failed: %s", exc)

    # ---- today's app time ------------------------------------------------

    def _refresh_usage(self):
        self._last_usage = time.monotonic()
        total = None
        try:
            if self._client is None:
                self._client = usage.ManagerClient(
                    jawn_dir=self.shell.jawn_dir, timeout=4.0)
            total = self._client.total_ms_today()
        except Exception as exc:
            LOG.debug("today's app time is unavailable: %s", exc)
            total = None
        if total is None:
            self._emit(self.signals.usage, "Today \u2014", False)
        else:
            self._emit(self.signals.usage,
                       "Today " + usage.format_duration(total), True)

    # ---- now playing -----------------------------------------------------

    def _refresh_music(self):
        self._last_music = time.monotonic()
        if not self._playerctl:
            return
        try:
            done = subprocess.run(
                [self._playerctl, "metadata", "--format",
                 "{{status}}\t{{artist}}\t{{title}}"],
                capture_output=True, text=True, timeout=2.0, env=_sway_env())
        except (OSError, subprocess.TimeoutExpired):
            return
        text = ""
        if done.returncode == 0:
            parts = done.stdout.rstrip("\n").split("\t")
            status = parts[0] if parts else ""
            artist = parts[1] if len(parts) > 1 else ""
            title = parts[2] if len(parts) > 2 else ""
            if status == "Playing" and (artist or title):
                text = "\u266a " + " \u2014 ".join(
                    piece for piece in (artist, title) if piece)
        self._emit(self.signals.music, text or None)


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="jawnos-shell",
        description="The JawnOS session bar: launcher, Sway workspaces, focused "
                    "app, today's app time, clock and optional now-playing.")
    parser.add_argument("--height", type=int, default=BAR_HEIGHT,
                        help="bar height in pixels (default: %d)" % BAR_HEIGHT)
    parser.add_argument("--jawn-dir", default=None,
                        help="the jawn tree for the usage summary (default: the "
                             "desktop setting, or $JAWNOS_DIR)")
    parser.add_argument("--no-layer-shell", action="store_true",
                        help="use an ordinary frameless window instead of a "
                             "layer-shell panel (debugging)")
    parser.add_argument("--no-music", action="store_true",
                        help="do not look for playerctl / now-playing")
    parser.add_argument("--verbose", action="store_true",
                        help="log debug detail (Sway IPC and manager errors)")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s jawnos-shell %(levelname)s %(message)s",
        stream=sys.stderr,
    )

    if _QT_ERROR is not None:
        LOG.error("PySide6 is not available (%s); the session bar cannot "
                  "start", _QT_ERROR)
        return 1
    if not os.environ.get("WAYLAND_DISPLAY") and not os.environ.get("DISPLAY"):
        LOG.error("no Wayland or X display; the session bar cannot start")
        return 1

    _prepare_wayland_env()

    app = QApplication([sys.argv[0]])
    app.setApplicationName("jawnos-session")
    app.setApplicationDisplayName("JawnOS")
    app.setOrganizationName("JawnOS")
    # Wayland derives app_id from this; Sway's fallback rule matches it.
    try:
        app.setDesktopFileName("jawnos-session")
    except Exception:
        pass

    shell = Shell(args)

    def _on_signal(signum, _frame):
        LOG.info("received signal %s; stopping the session bar", signum)
        app.quit()

    # The clock timer calls back into Python every second, which is also what
    # lets a SIGTERM/SIGINT handler run while Qt owns the event loop.
    for signum in (signal.SIGTERM, signal.SIGINT):
        try:
            signal.signal(signum, _on_signal)
        except Exception:
            pass

    shell.start()
    try:
        code = app.exec()
    except KeyboardInterrupt:
        code = 0
    finally:
        shell.stop()
    return code


if __name__ == "__main__":
    sys.exit(main())
