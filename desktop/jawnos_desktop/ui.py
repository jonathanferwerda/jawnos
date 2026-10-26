"""``jawnos-desktop`` -- the GTK dashboard.

A desktop port of the Android app's ``JawnDashboardActivity``: the same groups
(Jawn, Open, BLE bridge), a live status line, the jawn-folder setting, and the
autostart / "BLE with jawn" checkboxes. Every action goes through
:mod:`jawnos_desktop.core`, so it behaves exactly like ``jawnosctl``.

The UI is GTK 3 on purpose: it is the one toolkit that is packaged on every
distribution, and it can host the optional status-tray icon in the same
process.
"""

import os
import sys
import threading
import time

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gdk, GdkPixbuf, GLib, Gtk  # noqa: E402

from . import DESKTOP_DIR, core  # noqa: E402

LOGO = os.path.join(DESKTOP_DIR, "icons", "jawnos.png")

# The panel's look: a near-black ground, rounded cards above it, the jawn yellow
# as the accent - the same language as the Android dashboard's cards.
_CSS = """
.jawnos, .jawnos notebook, .jawnos scrolledwindow, .jawnos viewport { background-color: #000000; }
/* Scope this to the app's own windows (a `window label` selector still caught
   the tray menu: GTK hosts a popup menu in an internal GtkWindow). A bare
   `label` rule painted the menu's items near-white on the desktop theme's light
   menu, so the menu was unreadable. */
.jawnos label { color: #ededed; }
.jawnos label.title { font-size: 24px; font-weight: bold; }
.jawnos label.dim { color: #8e8e8e; font-size: 12px; }
.jawnos label.h { color: #8e8e8e; font-size: 11px; font-weight: bold; }
.jawnos label.state { font-size: 16px; }
.jawnos box.card { background-color: #1b1b1b; border: 1px solid #2c2c2c; border-radius: 18px; padding: 14px; }
.jawnos button { background-image: none; background-color: #262626; color: #ededed;
         border: 1px solid #2c2c2c; border-radius: 13px; padding: 12px 14px; box-shadow: none; }
.jawnos button:hover { background-color: #303030; }
.jawnos button.primary { background-color: #ffcc00; color: #0a0a0a; border: 1px solid #ffcc00; font-weight: bold; }
.jawnos button.primary:hover { background-color: #e6b800; }
.jawnos entry { background-color: #262626; color: #ededed; border: 1px solid #2c2c2c;
        border-radius: 10px; padding: 9px; }
.jawnos checkbutton { color: #ededed; }
"""

# The live status dots, the same greens/ambers/reds the manager and the Android
# dashboard use.
GREEN_RGB = (0x34 / 255.0, 0xC7 / 255.0, 0x59 / 255.0)
AMBER_RGB = (0xFF / 255.0, 0xB0 / 255.0, 0x20 / 255.0)
RED_RGB = (0xFF / 255.0, 0x45 / 255.0, 0x3A / 255.0)
DIM_RGB = (0x8E / 255.0, 0x8E / 255.0, 0x8E / 255.0)

_CSS_APPLIED = False

# The tray badge is drawn at this size; the pixbufs are cached per colour.
_TRAY_PX = 64
_TRAY_PIXBUFS = {}


def _apply_css():
    global _CSS_APPLIED
    if _CSS_APPLIED:
        return
    _CSS_APPLIED = True
    provider = Gtk.CssProvider()
    provider.load_from_data(_CSS.encode("utf-8"))
    Gtk.StyleContext.add_provider_for_screen(
        Gdk.Screen.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)


def _primary_workarea():
    """The primary monitor's work area, or None when there is no screen."""
    screen = Gdk.Screen.get_default()
    if screen is None:
        return None
    monitor = screen.get_primary_monitor()
    if monitor is None or monitor < 0:
        monitor = 0
    try:
        return screen.get_monitor_workarea(monitor)
    except Exception:
        return screen.get_monitor_geometry(monitor)


def _initial_size():
    """Two-thirds of the work area of the primary monitor.

    Scaling both dimensions by two-thirds keeps the window in the screen's
    orientation: a wide monitor gets a wide window, a tall one a tall window.
    The work area (not the raw geometry) is used so panels are not covered."""
    geom = _primary_workarea()
    if geom is None:
        return 640, 860
    width = max(480, int(geom.width * 2 / 3))
    height = max(480, int(geom.height * 2 / 3))
    return width, height


def _workarea_at(x, y):
    """The work area of the monitor under a point, or the primary monitor's."""
    screen = Gdk.Screen.get_default()
    if screen is None:
        return None
    if x is not None and y is not None:
        monitor = screen.get_monitor_at_point(x, y)
        if monitor is not None and monitor >= 0:
            try:
                return screen.get_monitor_workarea(monitor)
            except Exception:
                return screen.get_monitor_geometry(monitor)
    return _primary_workarea()


def _can_position_window():
    """Whether this display lets a client place its own toplevel.

    Wayland gives the compositor the last word, so Gtk.Window.move() is a no-op
    there; only X11 is asked to remember and restore a position."""
    display = Gdk.Display.get_default()
    if display is None:
        return False
    try:
        kind = display.__gtype__.name
    except AttributeError:
        kind = type(display).__name__
    return "Wayland" not in kind


def _position_on_screen(x, y, width, height):
    """Whether a remembered top-left still lands on a connected monitor.

    A window saved on a monitor that has since been unplugged must not be
    restored off-screen, where it cannot be reached."""
    screen = Gdk.Screen.get_default()
    if screen is None:
        return False
    for index in range(screen.get_n_monitors()):
        geom = screen.get_monitor_geometry(index)
        if (x + width > geom.x and x < geom.x + geom.width
                and y + height > geom.y and y < geom.y + geom.height):
            return True
    return False


def _restore_geometry(settings):
    """The remembered (width, height, x, y); x and y are None when unplaceable.

    Falls back to the two-thirds box, clamps a remembered size to the work area
    so a window from a larger monitor still fits, and drops a position that is
    no longer on any monitor."""
    width, height = _initial_size()
    try:
        saved_w = int(settings.get("window_width") or 0)
        saved_h = int(settings.get("window_height") or 0)
    except (TypeError, ValueError):
        saved_w = saved_h = 0
    if saved_w > 0 and saved_h > 0:
        width, height = saved_w, saved_h
    x = y = None
    if _can_position_window():
        try:
            saved_x = int(settings.get("window_x"))
            saved_y = int(settings.get("window_y"))
        except (TypeError, ValueError):
            saved_x = saved_y = None
        if (saved_x is not None and saved_y is not None
                and _position_on_screen(saved_x, saved_y, width, height)):
            x, y = saved_x, saved_y
    # Clamp to the work area of the monitor the window will open on, so a box
    # from a larger screen still fits but one on a big second monitor is kept.
    area = _workarea_at(x, y)
    if area is not None:
        width = min(width, area.width)
        height = min(height, area.height)
    return width, height, x, y


class Dashboard(Gtk.Window):
    def __init__(self, settings, start_requested=False, show_web=False, tray=True):
        super().__init__(title="JawnOS")
        self.settings = settings
        self.start_requested_at = 0.0
        self._web_panel = None
        self._view_version = ''
        self._web_failed = False
        self._quitting = False
        self._guard_lock = threading.Lock()
        self._version_check_at = 0.0
        self._version_restart_at = 0.0
        self._update_pending = None
        self._update_pending_at = 0.0
        self._updating = False
        self._tailnet = {}
        self._tailnet_at = 0.0
        self._geometry_timer = 0
        # Geometry and state are recorded only once the launch's own state has
        # been applied, so the events from mapping cannot overwrite it.
        self._ready = False
        width, height, x, y = _restore_geometry(settings)
        self.set_default_size(width, height)
        if x is not None:
            # Before the window is shown, GTK hands the position to the WM.
            self.move(x, y)
        # The CSS is scoped to this class so it cannot leak into GTK's popup
        # menus (which live in their own internal toplevel window).
        self.get_style_context().add_class("jawnos")
        _apply_css()

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        box.set_border_width(20)
        # Cards fill the column; their buttons are centred inside, so the panel
        # reads as a single tidy column on any window width.
        scroller = Gtk.ScrolledWindow()
        scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroller.add(box)

        # One app: the control panel and the embedded JawnOS view as tabs. The
        # view is built on first use -- WebKit is heavy and it logs in.
        self.notebook = Gtk.Notebook()
        self.notebook.append_page(scroller, Gtk.Label(label="Dashboard"))
        self.web_page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.notebook.append_page(self.web_page, Gtk.Label(label="JawnOS"))
        # No tab strip: the Dashboard's button and the view's start-menu admin
        # icon are the two ways across (Ctrl+Shift+D is the keyboard backstop).
        # The notebook's frame is off too -- with the tabs gone it is just a
        # bevel, and it showed as a silver border around a fullscreen view.
        self.notebook.set_show_tabs(False)
        self.notebook.set_show_border(False)
        self.notebook.connect("switch-page", self._on_switch_page)
        self.add(self.notebook)

        if os.path.exists(LOGO):
            # Scale the pixbuf explicitly: set_pixel_size() does not reliably
            # resize an image loaded from a file in GTK3, so a 358x526 logo
            # rendered at full size and pushed the buttons off the panel.
            pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_scale(LOGO, -1, 56, True)
            image = Gtk.Image.new_from_pixbuf(pixbuf)
            # A Gtk.Image cannot take a click on its own, so the logo rides in an
            # EventBox with no visible window: clicking it opens the JawnOS view.
            logo = Gtk.EventBox()
            logo.set_visible_window(False)
            logo.add(image)
            logo.set_tooltip_text("Open the JawnOS view")
            try:
                logo.set_cursor(Gdk.Cursor.new_from_name(Gdk.Display.get_default(), "pointer"))
            except Exception:
                pass
            logo.connect("button-press-event", self._on_logo_clicked)
            box.pack_start(self._centre(logo), False, False, 2)

        title = Gtk.Label(label="JawnOS", xalign=0.5)
        title.get_style_context().add_class("title")
        box.pack_start(self._centre(title), False, False, 0)

        status = self._card(box, "Status")
        _jrow, self.jawn_dot, self.jawn_state = self._status_line(status)
        _brow, self.ble_dot, self.ble_state = self._status_line(status)

        self.env = Gtk.Label(xalign=0)
        self.env.set_line_wrap(True)
        self.env.get_style_context().add_class("dim")
        status.pack_start(self.env, False, False, 0)

        self.live = Gtk.Label(xalign=0)
        self.live.set_line_wrap(True)
        self.live.get_style_context().add_class("dim")
        status.pack_start(self.live, False, False, 0)

        self.dir_entry = Gtk.Entry()
        self.dir_entry.set_text(settings.get("jawn_dir", ""))
        self.dir_entry.set_placeholder_text("jawn folder (default ~/jawnos)")
        self.dir_entry.set_width_chars(46)

        self.autostart = Gtk.CheckButton(label="Start the BLE bridge at login")
        self.autostart.set_active(core.autostart_enabled())

        self.ble_with_jawn = Gtk.CheckButton(label="Start/stop the BLE bridge with jawn")
        self.ble_with_jawn.set_active(bool(settings.get("ble_with_jawn", True)))

        jawn = self._card(box, "Jawn")
        self._card_row(jawn, [
            ("Start", self.action_start, True),
            ("Restart", self.action_restart, False),
            ("Stop", self.action_stop, False),
        ])

        # The tailnet lives beside jawn: the desktop's tunnel is the machine's
        # own tailscaled, so the dashboard can bring it up or down the way the
        # phone's dashboard does.
        tailnet = self._card(box, "Tailnet")
        _trow, self.tail_dot, self.tail_state = self._status_line(tailnet)
        self._card_row(tailnet, [
            ("Start VPN", lambda: self._async(core.tailnet_up), True),
            ("Stop VPN", lambda: self._async(core.tailnet_down), False),
        ])

        opn = self._card(box, "Open")
        # The view is the everyday destination, so it is the primary action.
        self._card_button(opn, "JawnOS UI", self.action_open_embedded, primary=True)
        self._card_row(opn, [
            ("In browser", self.action_open_ui, False),
            ("Log", self.action_show_log, False),
            ("Console", self.action_open_console, False),
        ])

        login = self._card(box, "Login")
        self._card_row(login, [
            ("Import ticket", self.action_import_ticket, False),
            ("Forget ticket", self.action_forget_ticket, False),
        ])

        ble = self._card(box, "Bluetooth")
        self._card_row(ble, [
            ("Start bridge", lambda: self._async(core.start_ble), False),
            ("Stop bridge", lambda: self._async(core.stop_ble), False),
        ])

        settings_card = self._card(box, "Settings")
        settings_card.pack_start(self.dir_entry, False, True, 0)
        settings_card.pack_start(self.autostart, False, True, 0)
        settings_card.pack_start(self.ble_with_jawn, False, True, 0)
        self._card_button(settings_card, "Save settings", self.action_save, primary=True)

        app_card = self._card(box, "App")
        self.app_note = Gtk.Label(xalign=0)
        self.app_note.set_line_wrap(True)
        self.app_note.get_style_context().add_class("dim")
        app_card.pack_start(self.app_note, False, True, 0)
        self.update_button = self._card_button(app_card, "Update app", self.action_update, primary=True)

        self.connect("destroy", Gtk.main_quit)
        self.connect("key-press-event", self._on_key)
        # Track fullscreen/maximized and the normal size and position so they are
        # remembered across launches.
        self.connect("window-state-event", self._on_window_state)
        self.connect("configure-event", self._on_configure)
        # The tray icon keeps the app alive when its window is closed -- closing
        # is how it was being lost. With no tray available, closing quits.
        self._tray = _make_tray(self) if tray else None
        self.connect("delete-event", self._on_delete)
        self.refresh()
        GLib.timeout_add_seconds(2, self._tick)
        if show_web:
            self.notebook.set_current_page(1)

    # ---- widgets ----

    @staticmethod
    def _centre(widget):
        """Give a widget the full row width but draw it centred in that width."""
        widget.set_halign(Gtk.Align.CENTER)
        widget.set_hexpand(True)
        return widget

    # ---- cards (the panel's look) ----

    def _card(self, box, title=None):
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        card.get_style_context().add_class("card")
        if title:
            label = Gtk.Label(label=title.upper(), xalign=0)
            label.get_style_context().add_class("h")
            card.pack_start(label, False, False, 0)
        box.pack_start(card, False, True, 0)
        return card

    def _status_line(self, card):
        """A coloured dot + a live label, returning both so the dot can recolour."""
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        dot = self._dot(DIM_RGB)
        label = Gtk.Label(xalign=0)
        label.get_style_context().add_class("state")
        row.pack_start(dot, False, False, 0)
        row.pack_start(label, False, False, 0)
        card.pack_start(row, False, False, 0)
        return row, dot, label

    def _dot(self, rgb):
        """A small filled circle, drawn so it can be recoloured in place."""
        area = Gtk.DrawingArea()
        area.set_size_request(13, 13)
        area._rgb = rgb

        def draw(widget, cr):
            w = widget.get_allocated_width()
            h = widget.get_allocated_height()
            cr.set_source_rgb(*widget._rgb)
            cr.arc(w / 2.0, h / 2.0, min(w, h) / 2.0 - 1.0, 0.0, 6.283185307)
            cr.fill()

        area.connect("draw", draw)
        return area

    @staticmethod
    def _set_dot(dot, rgb):
        dot._rgb = rgb
        dot.queue_draw()

    def _card_button(self, card, text, handler, primary=False):
        button = Gtk.Button(label=text)
        if primary:
            button.get_style_context().add_class("primary")
        button.connect("clicked", lambda _b, h=handler: h())
        card.pack_start(button, False, False, 0)
        return button

    def _card_row(self, card, buttons):
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8, homogeneous=True)
        for text, handler, primary in buttons:
            button = Gtk.Button(label=text)
            if primary:
                button.get_style_context().add_class("primary")
            button.connect("clicked", lambda _b, h=handler: h())
            row.pack_start(button, True, True, 0)
        card.pack_start(row, False, False, 0)
        return row

    # ---- settings ----

    def _save(self):
        self.settings["jawn_dir"] = os.path.expanduser(self.dir_entry.get_text().strip() or core.default_jawn_dir())
        self.settings["ble_with_jawn"] = self.ble_with_jawn.get_active()
        core.save_settings(self.settings)
        core.set_autostart(self.autostart.get_active())
        self.settings["autostart"] = self.autostart.get_active()

    def action_save(self):
        self._save()
        self.refresh()

    # ---- actions ----

    def action_start(self):
        self._save()
        self.start_requested_at = GLib.get_monotonic_time() / 1e6
        # jawn *and* the bridge: the checkbox promises they move together, and
        # starting jawn alone left the watch with nothing to talk to.
        self._async(lambda: core.start_all(
            self.settings["jawn_dir"], self.settings.get("ble_with_jawn", True)))

    def action_stop(self):
        self.start_requested_at = 0.0
        self._async(lambda: core.stop_all(
            self.settings["jawn_dir"], self.settings.get("ble_with_jawn", True)))

    def action_restart(self):
        self._save()
        self.start_requested_at = GLib.get_monotonic_time() / 1e6
        self._async(lambda: core.restart_all(
            self.settings["jawn_dir"], self.settings.get("ble_with_jawn", True)))

    def action_open_ui(self):
        if not core.open_ui(self.settings["jawn_dir"]):
            self._say("could not open a browser")

    def action_open_embedded(self):
        # The embedded view is the app's JawnOS tab now, not a separate window.
        self._ensure_web_view()
        self.notebook.set_current_page(self.notebook.page_num(self.web_page))

    def action_open_console(self):
        ok, message = core.open_console(self.settings["jawn_dir"])
        self._say(message)

    def action_import_ticket(self):
        dialog = Gtk.Dialog(title="Import login ticket", transient_for=self)
        dialog.get_style_context().add_class("jawnos")
        dialog.add_buttons("Cancel", Gtk.ResponseType.CANCEL, "Save", Gtk.ResponseType.OK)
        entry = Gtk.Entry()
        entry.set_placeholder_text("https://host:3000/box_office/<uuid>?s=<token>")
        entry.set_width_chars(64)
        dialog.get_content_area().add(entry)
        dialog.show_all()
        response = dialog.run()
        url = entry.get_text().strip()
        dialog.destroy()
        if response == Gtk.ResponseType.OK and url:
            from . import secrets
            ok, message = secrets.store(url)
            self._say(message)
            self.refresh()

    def action_forget_ticket(self):
        from . import secrets
        secrets.clear()
        self._say("stored ticket cleared")
        self.refresh()

    def action_show_log(self):
        LogWindow(core.jawn_log_path(self.settings["jawn_dir"]))

    # ---- quit (takes jawn down with it) ----

    def action_quit(self):
        """Quit the app, taking jawn down first.

        Exiting from the tray must not leave a master, a worker, or the BLE
        bridge behind, so run the full stop (the same path as the Stop button)
        before the main loop ends. Stopping can take a few seconds, so it runs
        off the UI thread and the loop ends when it is done."""
        if self._quitting:
            return
        self._quitting = True
        self._say("stopping jawn...")

        def runner():
            try:
                _ok, message = core.stop_all(
                    self.settings["jawn_dir"], self.settings.get("ble_with_jawn", True))
            except Exception as exc:  # never let a thread die silently
                message = "stop failed: %s" % exc
            GLib.idle_add(self._finish_quit, message)

        threading.Thread(target=runner, daemon=True).start()

    def _finish_quit(self, message):
        self._say(message)
        self._flush_geometry()
        Gtk.main_quit()
        return False

    def action_quit_only(self):
        """Quit the desktop app, leaving jawn (and the BLE bridge) running.

        The tray's other quit item is "Quit and stop jawn"; this is the plain
        "Quit" -- closing the window/dashboard process only. The supervisor is
        a separate process tree (or a systemd unit), so ending this process does
        not touch it."""
        if self._quitting:
            return
        self._quitting = True
        self._flush_geometry()
        Gtk.main_quit()

    # ---- update the app itself ----

    def action_update(self):
        # a fresh check on tap: the dashboard note reflects the last refresh, so
        # look at the repo's desktop/ tree now rather than trusting that note.
        if not core.update_available(self.settings):
            self._say("already up to date")
            self.refresh()
            return
        ok, name, code = core.apply_update(self.settings)
        if not ok:
            self._say("already up to date")
            self.refresh()
            return
        self._say("updated to v%s - restarting..." % name)
        # A running process cannot swap its own modules, so restart on the new
        # code (the window closes and reopens on the fresh copy).
        GLib.timeout_add(400, self._restart_self)

    def _auto_update(self, newer):
        """Apply a newer desktop release and restart onto it (no button press).

        The check runs on the tick thread and calls this through the GTK loop;
        `_updating` stops a second apply while the first is copying, and the
        installed stamp `apply_update` writes means the next tick sees nothing
        new. auto_update_available only offers a *release* (a VERSION bump), so
        a working-tree edit cannot restart the app.
        """
        if self._updating:
            return False
        self._updating = True
        ok, name, code = core.apply_update(self.settings)
        if not ok:
            self._updating = False
            self._say("app update could not be applied")
            return False
        self._say("updated to v%s - restarting..." % (name or (newer[0] if newer else "?")))
        GLib.timeout_add(400, self._restart_self)
        return False

    def _restart_self(self):
        try:
            os.execv(sys.executable, [sys.executable, os.path.realpath(sys.argv[0])] + sys.argv[1:])
        except Exception as exc:
            # Let a later tick try again; leaving _updating set would silence
            # every future auto-update for this process.
            self._updating = False
            self._say("updated - close and reopen to run it (%s)" % exc)
        return False

    # ---- the embedded JawnOS view tab ----

    def _on_switch_page(self, _notebook, page, _index):
        if page is self.web_page:
            self._ensure_web_view()

    def _ensure_web_view(self):
        """Build the embedded view the first time its tab is shown."""
        if self._web_panel is not None or self._web_failed:
            return self._web_panel
        try:
            from . import webview
            panel = webview.WebViewPanel(self.settings)
        except Exception as exc:  # WebKitGTK missing
            self._web_failed = True
            self.web_page.pack_start(
                Gtk.Label(label="embedded view unavailable: %s" % exc), True, True, 0)
            self.web_page.show_all()
            return None
        panel.on_admin = self._show_dashboard
        panel.attach_keys(self)
        # Record the panel *before* packing and showing it. show_all() re-emits
        # the notebook's switch-page for the current page, and that handler calls
        # straight back into _ensure_web_view(); with the guard assigned last the
        # re-entrant call saw None and packed a second WebView, which split the
        # viewport in two and painted the manager twice.
        self._web_panel = panel
        self.web_page.pack_start(panel, True, True, 0)
        self.web_page.show_all()
        self._view_version = self._manager_version()
        return panel

    def _manager_version(self):
        try:
            with open(os.path.join(self.settings["jawn_dir"], "VERSION"), encoding="utf-8") as fh:
                return fh.read().strip()
        except OSError:
            return ""

    def _reload_web_view(self):
        """Reload the embedded manager after the tree restarted onto new code."""
        if self._web_panel is not None:
            try:
                self._web_panel.view.reload()
            except Exception:
                pass
        return False

    def _show_dashboard(self):
        self.notebook.set_current_page(0)

    def present_dashboard(self):
        # The tray menu's "Show Dashboard". Closing to the tray hides the window;
        # on Xfce a bare present() could leave it hidden or iconified, so show,
        # deiconify, return to the Dashboard tab, and only then present (which
        # raises and focuses).
        self.show_all()
        self.deiconify()
        self._show_dashboard()
        self.present()

    def present_window(self):
        # A left click on the tray returns to whatever was last showing (the
        # dashboard or the JawnOS view), so raise the window without touching the
        # tab -- the same show/deiconify/present dance as present_dashboard.
        self.show_all()
        self.deiconify()
        self.present()

    def _on_logo_clicked(self, _widget, event):
        if event.button == 1:
            self.action_open_embedded()
            return True
        return False

    def _on_delete(self, *_args):
        # Close to the tray, not to death: hide the window and keep the tray
        # (and the supervisor's status timer) running. With no tray there is
        # nothing to return to, so closing exits -- and now takes jawn down.
        if self._tray is not None:
            self.hide()
            return True
        self.action_quit()
        return True

    def finish_restore(self):
        """Begin recording the window state once the launch's state is applied."""
        self._ready = True
        # Capture the geometry the window actually opened with: a first run has
        # no remembered position, and the WM chose one.
        self._schedule_geometry_save()

    def _schedule_geometry_save(self):
        if self._geometry_timer:
            GLib.source_remove(self._geometry_timer)
        self._geometry_timer = GLib.timeout_add(500, self._save_geometry)

    def _on_window_state(self, _widget, event):
        # Remember fullscreen and maximized (whether F11, a double-click or the
        # compositor put us there) so the next launch restores it instead of
        # dropping to the default box.
        if not self._ready:
            return False
        changes = {
            "fullscreen": bool(event.new_window_state & Gdk.WindowState.FULLSCREEN),
            "maximized": bool(event.new_window_state & Gdk.WindowState.MAXIMIZED),
        }
        if any(value != bool(self.settings.get(key)) for key, value in changes.items()):
            self.settings.update(changes)
            core.save_settings(self.settings)
        return False

    def _on_configure(self, _widget, event):
        # Size and position change on every step of a drag or resize; settle for
        # half a second so a drag does not rewrite the settings file constantly.
        # Child windows' configure events bubble up here too; only the toplevel's
        # geometry is ours to keep.
        if not self._ready or self._quitting or event.window != self.get_window():
            return False
        self._schedule_geometry_save()
        return False

    def _save_geometry(self):
        self._geometry_timer = 0
        self._record_geometry()
        return False

    def _flush_geometry(self):
        """Write a geometry change that is still waiting out its settle time."""
        if self._geometry_timer:
            GLib.source_remove(self._geometry_timer)
            self._geometry_timer = 0
        self._record_geometry()

    def _record_geometry(self):
        """Store the last normal size and position.

        While fullscreen or maximized the reported geometry is the screen's, and
        keeping that as the "normal" box would leave the window unable to come
        back where it was."""
        win = self.get_window()
        if win is None:
            return
        if win.get_state() & (Gdk.WindowState.FULLSCREEN | Gdk.WindowState.MAXIMIZED):
            return
        width, height = self.get_size()
        if width < 1 or height < 1:
            return
        x, y = self.get_position() if _can_position_window() else (None, None)
        changes = {}
        if width != self.settings.get("window_width"):
            changes["window_width"] = width
        if height != self.settings.get("window_height"):
            changes["window_height"] = height
        if x is not None and x != self.settings.get("window_x"):
            changes["window_x"] = x
        if y is not None and y != self.settings.get("window_y"):
            changes["window_y"] = y
        if changes:
            self.settings.update(changes)
            core.save_settings(self.settings)

    def _on_key(self, _widget, event):
        # F11 toggles the whole app, including when the embedded view has focus.
        # The view's own handler is also attached to this window; taking F11
        # here returns True so the event is not toggled twice.
        if event.keyval == Gdk.KEY_F11:
            win = self.get_window()
            fullscreen = bool(win and (win.get_state() & Gdk.WindowState.FULLSCREEN))
            if fullscreen:
                self.unfullscreen()
            else:
                self.fullscreen()
            return True
        # With the tab strip hidden, Ctrl+Shift+D is the keyboard way back to the
        # control panel (e.g. if the view ever lands somewhere without its
        # start-menu admin icon).
        if (event.keyval == Gdk.KEY_d
                and (event.state & Gdk.ModifierType.CONTROL_MASK)
                and (event.state & Gdk.ModifierType.SHIFT_MASK)):
            self._show_dashboard()
            return True
        return False

    # ---- async plumbing ----

    def _async(self, work):
        self._say("working...")
        def runner():
            try:
                ok, message = work()
            except Exception as exc:  # never let a thread die silently
                ok, message = False, str(exc)
            GLib.idle_add(self._say, message)
            GLib.idle_add(self.refresh)
        threading.Thread(target=runner, daemon=True).start()

    def _say(self, message):
        self.live.set_text(message)
        return False

    # ---- status ----

    def _tick(self):
        def probe():
            settings = self.settings
            jawn = core.jawn_up(settings["jawn_dir"])
            ble = core.ble_up()
            now = time.monotonic()
            # The tunnel's own state is a CLI call, so read it every few
            # seconds; the network watcher (a cheap `ip` read) still runs on
            # every tick so a switch is caught promptly.
            if now - self._tailnet_at >= 5:
                self._tailnet_at = now
                self._tailnet = core.tailnet_state()
            tail = core.tailnet_network_tick(self._tailnet)
            if now - self._version_check_at >= 60 and self._guard_lock.acquire(blocking=False):
                try:
                    self._version_check_at = now
                    # The tree on disk can move without the process noticing (a
                    # git update or a peer code sync). Restart it onto the new
                    # files; the cooldown keeps a tree that is still booting
                    # from being killed by an old health answer.
                    if jawn and now - self._version_restart_at >= 300:
                        stale = core.version_mismatch(settings["jawn_dir"])
                        if stale:
                            							running, disk = stale
                            							self._version_restart_at = now
                            							ok, message = core.restart_all(
                            								settings["jawn_dir"], settings.get("ble_with_jawn", True))
                            							GLib.idle_add(self._say, ("restarted %s -> %s" % (running, disk))
                            										  if ok else ("restart failed: %s" % message))
                            							jawn = core.jawn_up(settings["jawn_dir"])
                            							# The embedded view keeps the bundle it loaded; a manager
                            							# restart for new code does not touch it. Reload it once the
                            							# tree is answering, so a page is never left on old JS.
                            							GLib.timeout_add_seconds(6, self._reload_web_view)
                    # The dashboard's own copy follows the repo's desktop tree,
                    # but only a VERSION bump may restart it: a working-tree
                    # edit changes the stamp without shipping anything, and
                    # watching the stamp alone restarted the app every minute
                    # or two while desktop/ was being edited. The Update app
                    # button still applies any edit on demand.
                    newer = core.auto_update_available(settings)
                    if newer:
                        if self._update_pending == newer and now - self._update_pending_at >= 55:
                            GLib.idle_add(self._auto_update, newer)
                        else:
                            self._update_pending = newer
                            self._update_pending_at = now
                    else:
                        self._update_pending = None
                    # The page loads the bundle once. When the manager's version
                    # changes (a push plus a restart, ours or another agent's),
                    # reload the view so it is never left on old JS.
                    disk_version = self._manager_version()
                    if self._web_panel is not None and disk_version and disk_version != self._view_version:
                        self._view_version = disk_version
                        GLib.idle_add(self._reload_web_view)
                finally:
                    self._guard_lock.release()
            GLib.idle_add(self._render, jawn, ble, tail)
        threading.Thread(target=probe, daemon=True).start()
        return True

    def refresh(self):
        self._tick()
        try:
            from . import secrets
            ticket = secrets.describe()
        except Exception:
            ticket = "?"
        self.env.set_text(
            "folder: %s\nautostart: %s\nlogin ticket: %s" % (
                self.settings.get("jawn_dir", ""),
                "enabled" if core.autostart_enabled() else "disabled",
                ticket))
        info = core.installed_info()
        iname = info.get("versionName") or "?"
        icode = info.get("versionCode") or 0
        newer = core.update_available(self.settings)
        if newer:
            self.app_note.set_text("desktop v%s (%s)\nan update to v%s is ready." % (iname, icode, newer[0] or "newer"))
        else:
            self.app_note.set_text("desktop v%s (%s)\nup to date - tap Update app to check again." % (iname, icode))
        self.update_button.set_sensitive(True)

    def _render(self, jawn_up, ble_up, tail=None):
        if jawn_up:
            self.start_requested_at = 0.0
            js, colour = "running", GREEN_RGB
        elif self.start_requested_at:
            age = int(GLib.get_monotonic_time() / 1e6 - self.start_requested_at)
            if age < 150:
                js, colour = "starting... (%ds)" % age, AMBER_RGB
            else:
                js, colour = "not running", RED_RGB
        else:
            js, colour = "not running", RED_RGB
        self.jawn_state.set_text("jawn  —  " + js)
        self._set_dot(self.jawn_dot, colour)
        # The tray mirrors jawn's colour, so its state reads without the window.
        _safe_tray_apply(self, colour)
        self.ble_state.set_text("BLE bridge  —  " + ("running" if ble_up else "stopped"))
        self._set_dot(self.ble_dot, GREEN_RGB if ble_up else DIM_RGB)

        tail = tail or {}
        tstate = tail.get("state") or ("Running" if tail.get("running") else "Stopped")
        tlabel = {
            "Running": "running",
            "Stopped": "stopped",
            "Starting": "starting",
            "NeedsLogin": "needs login",
            "NoState": "not installed",
        }.get(tstate, tstate.lower() or "stopped")
        if tail.get("error") and not tail.get("available"):
            tlabel = "unavailable"
        if tail.get("network_restart"):
            tlabel += " · " + tail.get("network_restart")
        self.tail_state.set_text("Tailnet  —  " + tlabel)
        if tail.get("running"):
            tcolour = GREEN_RGB
        elif tstate in ("Starting", "NeedsLogin"):
            tcolour = AMBER_RGB
        else:
            tcolour = DIM_RGB
        self._set_dot(self.tail_dot, tcolour)
        return False


class LogWindow(Gtk.Window):
    """A small tail of jawn's manager.log, refreshing every two seconds."""

    def __init__(self, path):
        super().__init__(title="jawn log - %s" % path)
        self.get_style_context().add_class("jawnos")
        self.path = path
        self.set_default_size(760, 520)
        view = Gtk.TextView(editable=False, monospace=True)
        self.buffer = view.get_buffer()
        scroller = Gtk.ScrolledWindow()
        scroller.add(view)
        self.add(scroller)
        self._reload()
        GLib.timeout_add_seconds(2, self._reload)
        self.show_all()

    def _reload(self):
        self.buffer.set_text(core.tail_log(self.path, 400))
        end = self.buffer.get_end_iter()
        self.buffer.place_cursor(end)
        return True


def _tray_pixbuf(rgb):
    """The jawnos mark scaled for the tray, with a status dot in its corner.

    The status card carries separate jawn/BLE dots, but a tray icon has no room
    for that, so it gets one: green running, amber starting/restarting, red
    stopped. Built once per colour and cached."""
    key = tuple(rgb)
    cached = _TRAY_PIXBUFS.get(key)
    if cached is None:
        cached = _build_tray_pixbuf(rgb)
        _TRAY_PIXBUFS[key] = cached
    return cached


def _build_tray_pixbuf(rgb):
    import cairo
    base = GdkPixbuf.Pixbuf.new_from_file_at_scale(LOGO, _TRAY_PX, _TRAY_PX, True)
    width, height = base.get_width(), base.get_height()
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, width, height)
    cr = cairo.Context(surface)
    Gdk.cairo_set_source_pixbuf(cr, base, 0.0, 0.0)
    cr.paint()
    # The dot sits in the corner, sized to the icon, with a dark rim so it reads
    # against a light or a dark panel.
    radius = max(3.0, width * 0.19)
    cx, cy = width - radius - 1.0, height - radius - 1.0
    cr.arc(cx, cy, radius + 1.5, 0.0, 6.283185307)
    cr.set_source_rgba(0.0, 0.0, 0.0, 0.85)
    cr.fill()
    cr.arc(cx, cy, radius, 0.0, 6.283185307)
    cr.set_source_rgb(*rgb)
    cr.fill()
    return Gdk.pixbuf_get_from_surface(surface, 0, 0, width, height)


def _tray_icon_path(rgb):
    """A PNG of the badged icon, for the indicator backend, which sets its icon
    by name or path. Written once per colour under the state dir."""
    directory = os.path.join(core.state_dir(), "tray")
    os.makedirs(directory, exist_ok=True)
    name = "%02x%02x%02x.png" % tuple(int(round(c * 255.0)) for c in rgb)
    path = os.path.join(directory, name)
    if not os.path.exists(path):
        _tray_pixbuf(rgb).savev(path, "png", [], [])
    return path


def _safe_tray_apply(window, rgb):
    """Recolour the tray badge, if a tray is present and the icon builds."""
    apply = getattr(window, "_tray_apply", None)
    if apply is None:
        return
    try:
        apply(rgb)
    except Exception:
        pass


def _tray_menu(window):
    menu = Gtk.Menu()
    for label, callback in (
        ("Show Dashboard", lambda _i: window.present_dashboard()),
        ("Start jawn", lambda _i: window.action_start()),
        ("Stop jawn", lambda _i: window.action_stop()),
        ("Restart jawn", lambda _i: window.action_restart()),
        # Quitting stops jawn too, so the label says so.
        ("Quit and stop jawn", lambda _i: window.action_quit()),
        # Plain Quit leaves the jawn tree alone -- the app is only the window.
        ("Quit", lambda _i: window.action_quit_only()),
    ):
        item = Gtk.MenuItem(label=label)
        item.connect("activate", callback)
        menu.append(item)
    menu.show_all()
    # AppIndicator's secondary (middle) activation can only reach a menu item, so
    # point it at Show Dashboard -- the only "open the window" it can offer.
    window._tray_show_item = menu.get_children()[0]
    return menu


def _make_tray(window):
    """A status-tray icon, on any desktop.

    Prefers the legacy system tray (Gtk.StatusIcon), because it is the only
    backend that tells a left click from a right click -- left opens the window,
    right shows the menu. Where there is no legacy tray (GNOME, Cinnamon, a bare
    compositor) it falls back to the StatusNotifier/AppIndicator protocol, whose
    own left click shows the menu (a middle click opens the window there).
    Returns None if neither is available, in which case closing the window
    quits."""
    menu = _tray_menu(window)
    # AppIndicator and Gtk.StatusIcon do not hold a reference to the menu, so if
    # nothing else does PyGObject collects it and every tray command goes
    # silently dead. Keep the menu (and the icon/indicator) on the window.
    window._tray_menu = menu
    # The backend is only settled once the loop is running, because a status icon
    # has to be given a beat to dock. Until then, hold the last colour asked for
    # and paint it once a backend is chosen.
    window._tray_rgb = DIM_RGB
    window._tray_paint = None

    def apply(rgb):
        window._tray_rgb = rgb
        if window._tray_paint is not None:
            window._tray_paint(rgb)
    window._tray_apply = apply

    try:
        icon = Gtk.StatusIcon.new_from_icon_name("jawnos")
        icon.set_tooltip_text("JawnOS")
        icon.set_visible(True)
        # Left click brings the window back as it was; right click pops the menu
        # (which offers "Show Dashboard" when the control panel is wanted).
        icon.connect("activate", lambda _i: window.present_window())
        icon.connect("popup-menu",
                     lambda i, button, activate_time: menu.popup(
                         None, None, None, None, button, activate_time))
        window._tray_statusicon = icon
    except Exception:
        # No status icon at all: use the indicator (if it is available).
        _start_indicator(window, menu)
        _safe_tray_apply(window, DIM_RGB)
        return window._tray_indicator

    tries = [0]

    def choose():
        if icon.is_embedded():
            # A systray docked us: keep it -- it has the left/right click split.
            window._tray_paint = lambda rgb: icon.set_from_pixbuf(_tray_pixbuf(rgb))
        elif tries[0] < 3:
            tries[0] += 1
            return True  # give the panel another beat to dock us
        else:
            # No legacy tray here, so fall back to the status-notifier indicator.
            icon.set_visible(False)
            window._tray_statusicon = None
            _start_indicator(window, menu)
            window._tray = window._tray_indicator
        if window._tray_paint is not None:
            window._tray_paint(window._tray_rgb)
        return False

    GLib.timeout_add(400, choose)
    return icon


def _start_indicator(window, menu):
    """The StatusNotifier/AppIndicator backend, for desktops with no legacy
    system tray."""
    try:
        gi.require_version("AppIndicator3", "0.1")
        from gi.repository import AppIndicator3
        indicator = AppIndicator3.Indicator.new(
            "jawnos", "jawnos", AppIndicator3.IndicatorCategory.APPLICATION_STATUS)
        indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
        indicator.set_menu(menu)
        window._tray_indicator = indicator
        # Its own left and right clicks both show the menu; the closest it offers
        # to "click to open" is a middle click, which activates this menu item.
        try:
            indicator.set_secondary_activate_target(window._tray_show_item)
        except Exception:
            pass
        # The indicator sets its icon by name or path, so hand it the badged PNG.
        window._tray_paint = lambda rgb: indicator.set_icon_full(_tray_icon_path(rgb), "JawnOS")
        return indicator
    except Exception:
        window._tray_indicator = None
        window._tray_paint = None
        return None


def run_dashboard(settings=None, tray=True, show_web=False):
    settings = settings or core.load_settings()
    window = Dashboard(settings, show_web=show_web, tray=tray)
    # Read the remembered state before the window is mapped: the state events
    # from showing it would otherwise overwrite what is being restored.
    want_fullscreen = bool(settings.get("fullscreen"))
    want_maximized = bool(settings.get("maximized"))
    window.show_all()
    # The remembered state is applied once the window is on screen.
    if want_maximized:
        window.maximize()
    if want_fullscreen:
        window.fullscreen()
    window.finish_restore()
    Gtk.main()
    return window


def main(argv=None):
    import argparse
    parser = argparse.ArgumentParser(prog="jawnos-desktop", description="JawnOS desktop dashboard")
    parser.add_argument("--tray", action="store_true",
                        help="(default) keep a status-tray icon")
    parser.add_argument("--no-tray", action="store_true",
                        help="no status-tray icon; closing the window quits")
    parser.add_argument("--webview", action="store_true",
                        help="open the app on the embedded JawnOS view")
    args = parser.parse_args(argv)
    return run_dashboard(tray=not args.no_tray, show_web=args.webview)


if __name__ == "__main__":
    raise SystemExit(main())
