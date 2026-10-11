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
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf, GLib, Gtk  # noqa: E402

from . import DESKTOP_DIR, core  # noqa: E402

LOGO = os.path.join(DESKTOP_DIR, "icons", "jawnos.png")


class Dashboard(Gtk.Window):
    def __init__(self, settings, start_requested=False, show_web=False):
        super().__init__(title="JawnOS")
        self.settings = settings
        self.start_requested_at = 0.0
        self._web_panel = None
        self._web_failed = False
        self.set_default_size(1080, 820)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        box.set_border_width(18)
        box.set_halign(Gtk.Align.START)
        scroller = Gtk.ScrolledWindow()
        scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroller.add(box)

        # One app: the control panel and the embedded JawnOS view as tabs. The
        # view is built on first use -- WebKit is heavy and it logs in.
        self.notebook = Gtk.Notebook()
        self.notebook.append_page(scroller, Gtk.Label(label="Dashboard"))
        self.web_page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.notebook.append_page(self.web_page, Gtk.Label(label="JawnOS"))
        self.notebook.connect("switch-page", self._on_switch_page)
        self.add(self.notebook)

        if os.path.exists(LOGO):
            # Scale the pixbuf explicitly: set_pixel_size() does not reliably
            # resize an image loaded from a file in GTK3, so a 358x526 logo
            # rendered at full size and pushed the buttons off the panel.
            pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_scale(LOGO, -1, 56, True)
            box.pack_start(Gtk.Image.new_from_pixbuf(pixbuf), False, False, 2)

        title = Gtk.Label()
        title.set_markup("<span size='large' weight='bold'>JawnOS</span>")
        title.set_xalign(0)
        box.pack_start(title, False, False, 0)

        self.live = Gtk.Label(xalign=0)
        box.pack_start(self.live, False, False, 4)

        self.env = Gtk.Label(xalign=0)
        self.env.set_line_wrap(True)
        box.pack_start(self.env, False, False, 0)

        self.dir_entry = Gtk.Entry()
        self.dir_entry.set_text(settings.get("jawn_dir", ""))
        self.dir_entry.set_placeholder_text("jawn folder (default ~/jawnos)")
        box.pack_start(self.dir_entry, False, False, 4)

        self.autostart = Gtk.CheckButton(label="Start the BLE bridge at login")
        self.autostart.set_active(core.autostart_enabled())
        box.pack_start(self.autostart, False, False, 0)

        self.ble_with_jawn = Gtk.CheckButton(label="Start/stop the BLE bridge with jawn")
        self.ble_with_jawn.set_active(bool(settings.get("ble_with_jawn", True)))
        box.pack_start(self.ble_with_jawn, False, False, 0)

        self._header(box, "Jawn")
        self._button(box, "Start jawn", self.action_start)
        self._button(box, "Stop jawn", self.action_stop)
        self._button(box, "Restart jawn", self.action_restart)

        self._header(box, "Open")
        self._button(box, "Open JawnOS UI", self.action_open_ui)
        self._button(box, "Open JawnOS view", self.action_open_embedded)
        self._button(box, "Show jawn log", self.action_show_log)
        self._button(box, "Open console", self.action_open_console)

        self._header(box, "Login")
        self._button(box, "Import login ticket", self.action_import_ticket)
        self._button(box, "Forget stored ticket", self.action_forget_ticket)

        self._header(box, "BLE bridge")
        self._button(box, "Start BLE bridge", lambda: self._async(core.start_ble))
        self._button(box, "Stop BLE bridge", lambda: self._async(core.stop_ble))

        self._button(box, "Save settings", self.action_save)

        self.connect("destroy", Gtk.main_quit)
        self.refresh()
        GLib.timeout_add_seconds(2, self._tick)
        if show_web:
            self.notebook.set_current_page(1)

    # ---- widgets ----

    def _header(self, box, text):
        label = Gtk.Label(xalign=0)
        label.set_markup("<b>%s</b>" % GLib.markup_escape_text(text))
        label.set_margin_top(10)
        box.pack_start(label, False, False, 0)

    def _button(self, box, text, handler):
        button = Gtk.Button(label=text)
        button.connect("clicked", lambda _b: handler())
        box.pack_start(button, False, False, 0)

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
        self.env.set_text(
            "folder: %s\nautostart: %s\nlogin ticket: %s" % (
                self.settings.get("jawn_dir", ""),
                "enabled" if core.autostart_enabled() else "disabled",
                ticket))

    def _render(self, jawn_up, ble_up):
        if jawn_up:
            self.start_requested_at = 0.0
            js = "running"
        elif self.start_requested_at:
            age = int(GLib.get_monotonic_time() / 1e6 - self.start_requested_at)
            js = "starting... (%ds)" % age if age < 150 else "not running"
        else:
            js = "not running"
        self.live.set_text("jawn: %s\nBLE bridge: %s" % (js, "running" if ble_up else "stopped"))
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


def _make_tray(window):
    """Optional status-tray icon, the analogue of the phone's overlay dot."""
    try:
        gi.require_version("AppIndicator3", "0.1")
        from gi.repository import AppIndicator3
    except Exception:
        return None
    indicator = AppIndicator3.Indicator.new(
        "jawnos", "jawnos", AppIndicator3.IndicatorCategory.APPLICATION_STATUS)
    indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
    menu = Gtk.Menu()
    for label, callback in (
        ("Dashboard", lambda _i: window.present()),
        ("Start jawn", lambda _i: window.action_start()),
        ("Stop jawn", lambda _i: window.action_stop()),
        ("Restart jawn", lambda _i: window.action_restart()),
        ("Open UI", lambda _i: window.action_open_ui()),
        ("Quit", lambda _i: Gtk.main_quit()),
    ):
        item = Gtk.MenuItem(label=label)
        item.connect("activate", callback)
        menu.append(item)
    menu.show_all()
    indicator.set_menu(menu)
    return indicator


def run_dashboard(settings=None, tray=False, show_web=False):
    settings = settings or core.load_settings()
    window = Dashboard(settings, show_web=show_web)
    indicator = _make_tray(window) if tray else None
    window.show_all()
    Gtk.main()
    return indicator


def main(argv=None):
    import argparse
    parser = argparse.ArgumentParser(prog="jawnos-desktop", description="JawnOS desktop dashboard")
    parser.add_argument("--tray", action="store_true", help="also show a status-tray icon")
    parser.add_argument("--webview", action="store_true",
                        help="open the app on the embedded JawnOS view")
    args = parser.parse_args(argv)
    return run_dashboard(tray=args.tray, show_web=args.webview)


if __name__ == "__main__":
    raise SystemExit(main())
