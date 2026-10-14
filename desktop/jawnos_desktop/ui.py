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
import threading

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
window { background-color: #101010; }
label { color: #ededed; }
label.title { font-size: 24px; font-weight: bold; }
label.dim { color: #8e8e8e; font-size: 12px; }
label.h { color: #8e8e8e; font-size: 11px; font-weight: bold; }
label.state { font-size: 16px; }
box.card { background-color: #1b1b1b; border: 1px solid #2c2c2c; border-radius: 18px; padding: 14px; }
button { background-image: none; background-color: #262626; color: #ededed;
         border: 1px solid #2c2c2c; border-radius: 13px; padding: 12px 14px; box-shadow: none; }
button:hover { background-color: #303030; }
button.primary { background-color: #ffcc00; color: #0a0a0a; border: 1px solid #ffcc00; font-weight: bold; }
button.primary:hover { background-color: #e6b800; }
entry { background-color: #262626; color: #ededed; border: 1px solid #2c2c2c;
        border-radius: 10px; padding: 9px; }
checkbutton { color: #ededed; }
"""

# The live status dots, the same greens/ambers/reds the manager and the Android
# dashboard use.
GREEN_RGB = (0x34 / 255.0, 0xC7 / 255.0, 0x59 / 255.0)
AMBER_RGB = (0xFF / 255.0, 0xB0 / 255.0, 0x20 / 255.0)
RED_RGB = (0xFF / 255.0, 0x45 / 255.0, 0x3A / 255.0)
DIM_RGB = (0x8E / 255.0, 0x8E / 255.0, 0x8E / 255.0)

_CSS_APPLIED = False


def _apply_css():
    global _CSS_APPLIED
    if _CSS_APPLIED:
        return
    _CSS_APPLIED = True
    provider = Gtk.CssProvider()
    provider.load_from_data(_CSS.encode("utf-8"))
    Gtk.StyleContext.add_provider_for_screen(
        Gdk.Screen.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)


class Dashboard(Gtk.Window):
    def __init__(self, settings, start_requested=False, show_web=False, tray=True):
        super().__init__(title="JawnOS")
        self.settings = settings
        self.start_requested_at = 0.0
        self._web_panel = None
        self._web_failed = False
        self.set_default_size(640, 860)
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

        self.connect("destroy", Gtk.main_quit)
        self.connect("key-press-event", self._on_key)
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
        self.web_page.pack_start(panel, True, True, 0)
        self.web_page.show_all()
        self._web_panel = panel
        return panel

    def _show_dashboard(self):
        self.notebook.set_current_page(0)

    def present_dashboard(self):
        # Closing to the tray hides the window. On Xfce a bare present() could
        # leave it hidden or iconified, which made the tray's "Show Dashboard"
        # look dead, so show, deiconify, return to the Dashboard tab, and only
        # then present (which raises and focuses).
        self.show_all()
        self.deiconify()
        self._show_dashboard()
        self.present()

    def _on_logo_clicked(self, _widget, event):
        if event.button == 1:
            self.action_open_embedded()
            return True
        return False

    def _on_delete(self, *_args):
        # Close to the tray, not to death: hide the window and keep the tray
        # (and the supervisor's status timer) running.
        if self._tray is not None:
            self.hide()
            return True
        return False

    def _on_key(self, _widget, event):
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
            GLib.idle_add(self._render, jawn, ble)
        threading.Thread(target=probe, daemon=True).start()
        return True

    def refresh(self):
        self._tick()
        try:
            from . import secrets
            ticket = secrets.describe()
        except Exception:
            ticket = "?"
        version = core.jawn_version(self.settings.get("jawn_dir", "")) or "unknown"
        self.env.set_text(
            "folder: %s\nversion: %s\nautostart: %s\nlogin ticket: %s" % (
                self.settings.get("jawn_dir", ""),
                version,
                "enabled" if core.autostart_enabled() else "disabled",
                ticket))

    def _render(self, jawn_up, ble_up):
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
        self.ble_state.set_text("BLE bridge  —  " + ("running" if ble_up else "stopped"))
        self._set_dot(self.ble_dot, GREEN_RGB if ble_up else DIM_RGB)
        return False


class LogWindow(Gtk.Window):
    """A small tail of jawn's manager.log, refreshing every two seconds."""

    def __init__(self, path):
        super().__init__(title="jawn log - %s" % path)
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


def _tray_menu(window):
    menu = Gtk.Menu()
    for label, callback in (
        ("Show Dashboard", lambda _i: window.present_dashboard()),
        ("Start jawn", lambda _i: window.action_start()),
        ("Stop jawn", lambda _i: window.action_stop()),
        ("Restart jawn", lambda _i: window.action_restart()),
        ("Quit", lambda _i: Gtk.main_quit()),
    ):
        item = Gtk.MenuItem(label=label)
        item.connect("activate", callback)
        menu.append(item)
    menu.show_all()
    return menu


def _make_tray(window):
    """A status-tray icon, on any desktop.

    Prefers the StatusNotifier/AppIndicator protocol (KDE, GNOME with an
    extension, Xfce 4.16+, Cinnamon); falls back to the legacy system tray
    (Gtk.StatusIcon), which Xfce's notification area still shows. Returns None if
    neither is available, in which case closing the window quits as before."""
    menu = _tray_menu(window)
    # AppIndicator and Gtk.StatusIcon do not hold a reference to the menu, so if
    # nothing else does PyGObject collects it and every tray command goes
    # silently dead. Keep the menu (and the indicator/status icon) on the window.
    window._tray_menu = menu
    try:
        gi.require_version("AppIndicator3", "0.1")
        from gi.repository import AppIndicator3
        indicator = AppIndicator3.Indicator.new(
            "jawnos", "jawnos", AppIndicator3.IndicatorCategory.APPLICATION_STATUS)
        indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
        indicator.set_menu(menu)
        window._tray_indicator = indicator
        return indicator
    except Exception:
        pass
    try:
        icon = Gtk.StatusIcon.new_from_icon_name("jawnos")
        icon.set_tooltip_text("JawnOS")
        icon.set_visible(True)
        icon.connect("activate", lambda _i: window.present_dashboard())
        icon.connect("popup-menu",
                     lambda i, button, activate_time: menu.popup(
                         None, None, None, None, button, activate_time))
        window._tray_statusicon = icon
        return icon
    except Exception:
        return None


def run_dashboard(settings=None, tray=True, show_web=False):
    settings = settings or core.load_settings()
    window = Dashboard(settings, show_web=show_web, tray=tray)
    window.show_all()
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
