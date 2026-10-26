"""``jawnos-shell`` -- the JawnOS session bar for Sway.

A thin GTK 3 panel along the top of the screen, in the wlr-layer-shell
"top" layer with an exclusive zone, so windows tile below it instead of under
it. Left to right it shows:

* a launcher (fuzzel, or a plain GTK entry when fuzzel is not installed),
* one button per Sway workspace (click switches; ``swaymsg workspace <name>``),
* the focused app's icon and name (read from Sway's tree),
* today's recorded app time (the manager's usage summary, every minute),
* an optional now-playing line (``playerctl``, when present),
* the clock and date.

Nothing here blocks the GTK main loop: the Sway event subscription, the periodic
Sway poll, the manager request and playerctl all run on daemon threads and hand
their results back through ``GLib.idle_add``. Every optional tool is probed at
startup and simply left out when it is missing, so a session with no swaymsg, no
manager or no playerctl still gets a working bar.

If the ``GtkLayerShell`` typelib is unavailable the bar falls back to an
undecorated window (a dock on X11) and logs exactly why: an incorrect bar is
better than a session that cannot start.
"""

import argparse
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

_GTK_ERROR = None
Gtk = Gdk = GLib = Pango = GdkPixbuf = None
try:
    import gi

    gi.require_version("Gtk", "3.0")
    gi.require_version("Gdk", "3.0")
    gi.require_version("Pango", "1.0")
    gi.require_version("GdkPixbuf", "2.0")
    from gi.repository import Gdk, GdkPixbuf, GLib, Gtk, Pango  # noqa: E402
except Exception as exc:  # ImportError, ValueError from require_version
    _GTK_ERROR = exc

_LAYER_ERROR = None
GtkLayerShell = None
if _GTK_ERROR is None:
    try:
        gi.require_version("GtkLayerShell", "0.1")
        from gi.repository import GtkLayerShell  # noqa: E402
    except Exception as exc:
        _LAYER_ERROR = exc


# --------------------------------------------------------------------------
# Presentation helpers
# --------------------------------------------------------------------------

# The bar is the desktop's own chrome, so it uses the same near-black ground and
# jawn yellow as the dashboard. All rules are scoped to `.jawnos-bar` so the
# fallback launcher window keeps the desktop theme.
_CSS = """
.jawnos-bar { background-color: #0d0d0d; }
.jawnos-bar label { color: #ededed; font-size: 12px; }
.jawnos-bar label.dim { color: #8e8e8e; }
.jawnos-bar label.offline { color: #6b6b6b; }
.jawnos-bar label.time { font-weight: bold; }
.jawnos-bar label.app-name { font-weight: bold; }
.jawnos-bar button { background-image: none; background-color: transparent;
         border: none; box-shadow: none; padding: 0 7px; border-radius: 6px;
         color: #ededed; }
.jawnos-bar button:hover { background-color: #262626; }
.jawnos-bar button.ws { color: #8e8e8e; min-width: 18px; padding: 0 5px; }
.jawnos-bar button.ws.active { background-color: #ffcc00; color: #0a0a0a;
         font-weight: bold; }
.jawnos-bar button.ws.urgent { color: #ff453a; }
.jawnos-bar button.launcher { background-color: #ffcc00; color: #0a0a0a;
         font-weight: bold; padding: 0 10px; }
.jawnos-bar button.launcher:hover { background-color: #e6b800; }
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


def _apply_css():
    if Gtk is None:
        return
    provider = Gtk.CssProvider()
    provider.load_from_data(_CSS.encode("utf-8"))
    screen = Gdk.Screen.get_default()
    if screen is not None:
        Gtk.StyleContext.add_provider_for_screen(
            screen, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)


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


def _theme_pixbuf(name, size):
    """A themed icon pixbuf, or None. Never raises."""
    try:
        theme = Gtk.IconTheme.get_default()
        if theme is None:
            return None
        info = theme.lookup_icon(name, size, Gtk.IconLookupFlags.FORCE_SIZE)
        return info.load_icon() if info is not None else None
    except Exception:
        return None


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

    The typelib can be installed on a GNOME or KDE box where the compositor has
    no such protocol; attempting to map a layer surface there is worse than the
    plain-window fallback. Sway, Hyprland and labwc name themselves in
    XDG_CURRENT_DESKTOP and pass this check.
    """
    desktop = (os.environ.get("XDG_CURRENT_DESKTOP") or "").lower()
    return any(name in desktop for name in (
        "gnome", "kde", "plasma", "unity", "cinnamon", "mate", "xfce"))


# --------------------------------------------------------------------------
# The bar
# --------------------------------------------------------------------------

class Shell:
    """One layer-shell (or plain) window and the widgets inside it."""

    def __init__(self, args):
        self.args = args
        self.height = max(18, min(64, int(args.height)))
        self.jawn_dir = args.jawn_dir
        self.music_enabled = not args.no_music
        self.worker = None
        self._ws_signature = None
        self._icon_cache = {}
        self._launcher_window = None
        self.using_layer_shell = False

        self.window = Gtk.Window()
        self.window.set_title("JawnOS")
        self.window.set_size_request(-1, self.height)
        self.window.get_style_context().add_class("jawnos-bar")
        self._claim_surface()
        self._build()

    # ---- window shape ----------------------------------------------------

    def _claim_surface(self):
        """Become a layer-shell panel, or the best ordinary window available."""
        if GtkLayerShell is not None and not self.args.no_layer_shell:
            if _desktop_blocks_layer_shell():
                LOG.warning("%s does not implement wlr-layer-shell; using an "
                            "undecorated window",
                            os.environ.get("XDG_CURRENT_DESKTOP"))
            elif not os.environ.get("WAYLAND_DISPLAY"):
                LOG.warning("gtk-layer-shell needs a Wayland display; "
                            "using an undecorated window")
            else:
                try:
                    GtkLayerShell.init_for_window(self.window)
                    GtkLayerShell.set_namespace(self.window, "jawnos-shell")
                    GtkLayerShell.set_layer(self.window, GtkLayerShell.Layer.TOP)
                    for edge in (GtkLayerShell.Edge.TOP,
                                 GtkLayerShell.Edge.LEFT,
                                 GtkLayerShell.Edge.RIGHT):
                        GtkLayerShell.set_anchor(self.window, edge, True)
                    GtkLayerShell.set_exclusive_zone(self.window, self.height)
                    # The bar itself never wants typing; the launcher entry is a
                    # separate toplevel and gets focus normally when opened.
                    GtkLayerShell.set_keyboard_mode(
                        self.window, GtkLayerShell.KeyboardMode.NONE)
                    self.using_layer_shell = True
                    LOG.info("session bar is a layer-shell panel (%dpx)",
                             self.height)
                    return
                except Exception as exc:
                    LOG.warning("gtk-layer-shell could not claim the panel (%s); "
                                "using an undecorated window", exc)
        elif GtkLayerShell is None:
            LOG.warning("gtk-layer-shell is not available (%s); using an "
                        "undecorated window. On Wayland a normal window cannot "
                        "reserve space, so Sway tiles it rather than placing it "
                        "above the windows.", _LAYER_ERROR)
        else:
            LOG.info("--no-layer-shell: using an undecorated window")

        # Fallback: a dock on X11; on Wayland Sway treats it as an ordinary
        # toplevel (the bar is usable, but it does not reserve an exclusive zone).
        self.window.set_decorated(False)
        self.window.set_skip_taskbar_hint(True)
        self.window.set_skip_pager_hint(True)
        try:
            self.window.set_type_hint(Gdk.WindowTypeHint.DOCK)
        except Exception:
            pass
        try:
            self.window.set_keep_above(True)
        except Exception:
            pass
        screen = Gdk.Screen.get_default()
        self.window.set_default_size(screen.get_width() if screen else 1024,
                                     self.height)

    # ---- widgets ---------------------------------------------------------

    def _build(self):
        outer = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        outer.set_margin_start(4)
        outer.set_margin_end(4)
        outer.set_size_request(-1, self.height)
        self.window.add(outer)

        left = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        left.set_valign(Gtk.Align.CENTER)

        self.launcher = Gtk.Button(label="Jawn")
        self.launcher.set_relief(Gtk.ReliefStyle.NONE)
        self.launcher.get_style_context().add_class("launcher")
        self.launcher.set_tooltip_text("Open the launcher")
        self.launcher.connect("clicked", self._on_launcher)
        left.pack_start(self.launcher, False, False, 0)

        self.ws_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=2)
        self.ws_box.set_valign(Gtk.Align.CENTER)
        left.pack_start(self.ws_box, False, False, 0)

        self.app_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        self.app_box.set_valign(Gtk.Align.CENTER)
        self.app_icon = Gtk.Image()
        self.app_icon.set_pixel_size(16)
        self.app_box.pack_start(self.app_icon, False, False, 0)
        self.app_label = Gtk.Label(label="")
        self.app_label.set_ellipsize(Pango.EllipsizeMode.END)
        self.app_label.set_max_width_chars(34)
        self.app_label.get_style_context().add_class("app-name")
        self.app_box.pack_start(self.app_label, False, False, 0)
        left.pack_start(self.app_box, False, False, 0)

        outer.pack_start(left, False, False, 0)

        right = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        right.set_valign(Gtk.Align.CENTER)

        self.usage_label = Gtk.Label(label="Today —")
        self.usage_label.get_style_context().add_class("dim")
        self.usage_label.set_tooltip_text("Recorded app time today")
        right.pack_start(self.usage_label, False, False, 0)

        self.music_label = Gtk.Label(label="")
        self.music_label.get_style_context().add_class("dim")
        self.music_label.set_ellipsize(Pango.EllipsizeMode.END)
        self.music_label.set_max_width_chars(34)
        self.music_label.set_no_show_all(True)
        right.pack_start(self.music_label, False, False, 0)

        clock = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        clock.set_valign(Gtk.Align.CENTER)
        self.time_label = Gtk.Label(label="")
        self.time_label.get_style_context().add_class("time")
        self.date_label = Gtk.Label(label="")
        self.date_label.get_style_context().add_class("dim")
        clock.pack_start(self.time_label, False, False, 0)
        clock.pack_start(self.date_label, False, False, 0)
        right.pack_start(clock, False, False, 0)

        outer.pack_end(right, False, False, 0)
        self._tick_clock()

    # ---- clock -----------------------------------------------------------

    def _tick_clock(self):
        now = datetime.datetime.now()
        self.time_label.set_text(now.strftime("%H:%M"))
        self.date_label.set_text(now.strftime("%a %d %b"))
        return True

    # ---- Sway: workspaces and focus -------------------------------------

    def apply_sway(self, workspaces, key, title):
        """Called on the GTK thread with a completed Sway read."""
        # An empty list is how a failed query looks; keep the last indicators
        # rather than flickering them away (Sway always has one workspace).
        if workspaces:
            self._render_workspaces(workspaces)
        self._render_app(key, title)
        return False

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

        for child in self.ws_box.get_children():
            self.ws_box.remove(child)

        for workspace in clean:
            name = str(workspace.get("name") or workspace.get("num") or "?")
            button = Gtk.Button(label=name)
            button.set_relief(Gtk.ReliefStyle.NONE)
            context = button.get_style_context()
            context.add_class("ws")
            if workspace.get("focused"):
                context.add_class("active")
            elif workspace.get("urgent"):
                context.add_class("urgent")
            button.set_tooltip_text("Switch to workspace %s" % name)
            button.connect("clicked", self._on_workspace, name)
            button.show()
            self.ws_box.pack_start(button, False, False, 0)

    def _render_app(self, key, title):
        if not key:
            self.app_label.set_text("")
            self.app_icon.hide()
            self.app_box.set_tooltip_text(None)
            return
        self.app_label.set_text(_pretty_app_name(key))
        self.app_box.set_tooltip_text(title or key)
        pixbuf = self._app_pixbuf(key, 16)
        if pixbuf is not None:
            self.app_icon.set_from_pixbuf(pixbuf)
        else:
            self.app_icon.set_from_icon_name("application-x-executable",
                                             Gtk.IconSize.MENU)
        self.app_icon.show()

    def _app_pixbuf(self, key, size):
        low = (key or "").lower()
        if low in self._icon_cache:
            return self._icon_cache[low]
        pixbuf = None
        if low.startswith("jawnos"):
            try:
                pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_size(
                    os.path.join(DESKTOP_DIR, "icons", "jawnos.png"),
                    size, size)
            except Exception:
                pixbuf = None
        if pixbuf is None:
            for candidate in _icon_candidates(key):
                pixbuf = _theme_pixbuf(candidate, size)
                if pixbuf is not None:
                    break
        self._icon_cache[low] = pixbuf
        return pixbuf

    def _on_workspace(self, _button, name):
        def switch():
            try:
                usage.swaymsg(["-t", "command",
                               "workspace " + _sway_quote(name)])
            except Exception as exc:
                LOG.debug("workspace switch to %s failed: %s", name, exc)
        threading.Thread(target=switch, name="jawnos-shell-workspace",
                         daemon=True).start()

    # ---- launcher --------------------------------------------------------

    def _on_launcher(self, _button):
        exe = shutil.which("fuzzel")
        if exe:
            try:
                subprocess.Popen([exe], env=_sway_env())
                return
            except OSError as exc:
                LOG.warning("fuzzel would not start (%s); using the built-in "
                            "entry", exc)
        self._show_launcher_entry()

    def _show_launcher_entry(self):
        """A plain GTK command entry, used when fuzzel is not installed."""
        if self._launcher_window is not None:
            self._launcher_window.present()
            return
        window = Gtk.Window(title="Run")
        window.set_default_size(520, -1)
        window.set_keep_above(True)
        entry = Gtk.Entry()
        entry.set_placeholder_text("Command")
        entry.set_margin_top(10)
        entry.set_margin_bottom(10)
        entry.set_margin_start(10)
        entry.set_margin_end(10)
        window.add(entry)

        def run(_entry=None):
            text = entry.get_text().strip()
            window.destroy()
            if text:
                try:
                    subprocess.Popen(["/bin/sh", "-c", text], env=_sway_env())
                except OSError as exc:
                    LOG.warning("could not run %r: %s", text, exc)

        def closed(_window=None):
            self._launcher_window = None

        entry.connect("activate", run)
        entry.connect("key-press-event", self._launcher_key)
        window.connect("destroy", closed)
        self._launcher_window = window
        window.show_all()

        def focus():
            entry.grab_focus()
            return False

        # An idle callback (not a direct call) so the entry is realized first;
        # the callback returns False so GLib does not call it again.
        GLib.idle_add(focus)

    def _launcher_key(self, _widget, event):
        if Gdk is not None and event.keyval == Gdk.KEY_Escape:
            if self._launcher_window is not None:
                self._launcher_window.destroy()
            return True
        return False

    # ---- manager: today's app time --------------------------------------

    def set_usage(self, text, ok):
        self.usage_label.set_text(text)
        context = self.usage_label.get_style_context()
        if ok:
            context.remove_class("offline")
        else:
            context.add_class("offline")
        return False

    # ---- playerctl: now playing -----------------------------------------

    def set_music(self, text):
        if text:
            self.music_label.set_text(text)
            self.music_label.set_tooltip_text(text)
            self.music_label.show()
        else:
            self.music_label.hide()
        return False

    # ---- lifecycle -------------------------------------------------------

    def start(self):
        _apply_css()
        self.window.connect("destroy", self._on_destroy)
        self.window.show_all()
        # set_no_show_all leaves it hidden until there is something playing.
        self.music_label.hide()
        self._tick_clock()
        GLib.timeout_add_seconds(1, self._tick_clock)
        self.worker = _Worker(self)
        self.worker.start()
        for signum in (signal.SIGTERM, signal.SIGINT):
            try:
                GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signum,
                                     self._on_signal, signum)
            except Exception:
                pass

    def _on_signal(self, signum):
        LOG.info("received signal %s; stopping the session bar", signum)
        self.quit()
        return GLib.SOURCE_REMOVE

    def _on_destroy(self, _window):
        if self.worker is not None:
            self.worker.stop_now()
        Gtk.main_quit()

    def quit(self):
        if self.worker is not None:
            self.worker.stop_now()
        try:
            Gtk.main_quit()
        except Exception:
            pass
        return False


# --------------------------------------------------------------------------
# Background work
# --------------------------------------------------------------------------

class _Worker(threading.Thread):
    """Sway events plus the slow clocks, all off the GTK thread."""

    def __init__(self, shell):
        super().__init__(name="jawnos-shell-worker", daemon=True)
        self.shell = shell
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
                        GLib.idle_add(self.shell.quit)
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
            GLib.idle_add(self.shell.apply_sway, workspaces, key or "", title)
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
            GLib.idle_add(self.shell.set_usage, "Today —", False)
        else:
            GLib.idle_add(self.shell.set_usage,
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
                text = "♪ " + " — ".join(
                    piece for piece in (artist, title) if piece)
        GLib.idle_add(self.shell.set_music, text or None)


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
                        help="use an ordinary undecorated window instead of a "
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

    if _GTK_ERROR is not None:
        LOG.error("GTK 3 / PyGObject is not available (%s); the session bar "
                  "cannot start", _GTK_ERROR)
        return 1
    if not os.environ.get("WAYLAND_DISPLAY") and not os.environ.get("DISPLAY"):
        LOG.error("no Wayland or X display; the session bar cannot start")
        return 1

    shell = Shell(args)
    shell.start()
    try:
        Gtk.main()
    except KeyboardInterrupt:
        pass
    finally:
        if shell.worker is not None:
            shell.worker.stop_now()
    return 0


if __name__ == "__main__":
    sys.exit(main())
