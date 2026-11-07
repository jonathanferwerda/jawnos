"""The Qt control panel: the desktop's supervisor in one window.

This replaces the GTK dashboard's panel and keeps its look: a black ground, a
column of rounded cards with upper-case section headers, the jawn yellow for the
primary action, and a coloured dot beside each live status line. The card order
and the words are the GTK panel's (which mirror the Android dashboard), so the
two panels read the same.

It reads the same ``core`` supervisor and keeps the same controls: jawn
start/stop/restart, the tailnet, the BLE bridge, the login ticket, the app
update and the settings, with the live status line the GTK panel had. The Qt
shell owns the window, the tray item and the web view; the page's admin icon
opens this panel.
"""

import os
import threading
import time

from PySide6.QtCore import QSize, QTimer, Qt, Signal, Slot
from PySide6.QtGui import QColor, QIcon, QPainter
from PySide6.QtWidgets import (
    QCheckBox,
    QDialog,
    QFrame,
    QHBoxLayout,
    QInputDialog,
    QLabel,
    QLineEdit,
    QPushButton,
    QScrollArea,
    QVBoxLayout,
    QWidget,
)

from . import DESKTOP_DIR, core, theme

LOGO = os.path.join(DESKTOP_DIR, "icons", "jawnos.png")


class StatusDot(QWidget):
    """The small filled circle beside a status line, recoloured in place."""

    def __init__(self, rgb=theme.DIM, parent=None):
        super().__init__(parent)
        self._rgb = tuple(rgb)
        self.setFixedSize(13, 13)

    def set_colour(self, rgb):
        rgb = tuple(rgb)
        if rgb != self._rgb:
            self._rgb = rgb
            self.update()

    def paintEvent(self, _event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing, True)
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(QColor(*self._rgb))
        painter.drawEllipse(1, 1, self.width() - 2, self.height() - 2)
        painter.end()


class ControlPanel(QDialog):
    status_ready = Signal(object)
    note = Signal(str)
    refreshed = Signal()

    def __init__(self, settings, actions, parent=None):
        super().__init__(parent)
        self.settings = settings
        self.actions = actions
        self.setWindowTitle("JawnOS")
        self._busy = False
        self._status_busy = False
        self._tail = {}
        self._tail_at = 0.0
        self._build()
        self.resize(*self._initial_size())
        self.status_ready.connect(self._render)
        self.note.connect(self._say)
        self.refreshed.connect(self.refresh)
        self.timer = QTimer(self)
        self.timer.timeout.connect(self.refresh)
        self.timer.start(2000)

    # ---- layout ----------------------------------------------------------

    def _initial_size(self):
        """Two-thirds of the screen, like the GTK dashboard's window."""
        screen = self.screen()
        if screen is None:
            return 640, 860
        geom = screen.availableGeometry()
        return (max(480, int(geom.width() * 2 / 3)),
                max(480, int(geom.height() * 2 / 3)))

    def _button(self, text, callback, primary=False):
        button = QPushButton(text)
        if primary:
            button.setProperty("primary", True)
        button.setCursor(Qt.CursorShape.PointingHandCursor)
        button.clicked.connect(callback)
        return button

    def _card(self, column, title):
        """A rounded card with a section header; returns its layout."""
        card = QFrame()
        card.setObjectName("card")
        layout = QVBoxLayout(card)
        layout.setContentsMargins(14, 14, 14, 14)
        layout.setSpacing(8)
        header = QLabel(title.upper())
        header.setObjectName("h")
        layout.addWidget(header)
        column.addWidget(card)
        return layout

    def _dim_label(self):
        label = QLabel("")
        label.setObjectName("dim")
        label.setWordWrap(True)
        return label

    def _status_row(self, card):
        """A coloured dot and a live label; returns both so the dot recolours."""
        row = QWidget()
        box = QHBoxLayout(row)
        box.setContentsMargins(0, 0, 0, 0)
        box.setSpacing(10)
        dot = StatusDot()
        label = QLabel("")
        label.setObjectName("state")
        box.addWidget(dot)
        box.addWidget(label, 1)
        card.addWidget(row)
        return dot, label

    def _row(self, card, *buttons):
        """Buttons side by side, each taking an equal share of the width."""
        row = QWidget()
        box = QHBoxLayout(row)
        box.setContentsMargins(0, 0, 0, 0)
        box.setSpacing(8)
        for button in buttons:
            box.addWidget(button, 1)
        card.addWidget(row)
        return row

    def _build(self):
        self.setObjectName("panel")
        self.setStyleSheet(theme.PANEL_CSS)

        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        scroller = QScrollArea()
        scroller.setWidgetResizable(True)
        scroller.setFrameShape(QFrame.Shape.NoFrame)
        body = QWidget()
        body.setObjectName("body")
        column = QVBoxLayout(body)
        column.setContentsMargins(20, 20, 20, 20)
        column.setSpacing(12)
        scroller.setWidget(body)
        outer.addWidget(scroller)

        logo = QPushButton()
        logo.setObjectName("logo")
        logo.setFlat(True)
        logo.setCursor(Qt.CursorShape.PointingHandCursor)
        logo.setToolTip("Open the JawnOS view")
        if os.path.exists(LOGO):
            logo.setIcon(QIcon(LOGO))
            logo.setIconSize(QSize(64, 64))
            logo.setFixedSize(70, 70)
        logo.clicked.connect(self._show_view)
        column.addWidget(logo, 0, Qt.AlignmentFlag.AlignHCenter)

        title = QLabel("JawnOS")
        title.setObjectName("title")
        title.setAlignment(Qt.AlignmentFlag.AlignHCenter)
        column.addWidget(title)

        status = self._card(column, "Status")
        self.jawn_dot, self.jawn_state = self._status_row(status)
        self.ble_dot, self.ble_state = self._status_row(status)
        self.env_state = self._dim_label()
        status.addWidget(self.env_state)
        self.live = self._dim_label()
        status.addWidget(self.live)

        jawn = self._card(column, "Jawn")
        self._row(jawn,
                  self._button("Start", self._start, primary=True),
                  self._button("Restart", self._restart),
                  self._button("Stop", self._stop))

        tailnet = self._card(column, "Tailnet")
        self.tail_dot, self.tail_state = self._status_row(tailnet)
        self._row(tailnet,
                  self._button("Start VPN", self._tailnet_up, primary=True),
                  self._button("Stop VPN", self._tailnet_down))

        opn = self._card(column, "Open")
        opn.addWidget(self._button("JawnOS UI", self._show_view, primary=True))
        self._row(opn,
                  self._button("In browser", self._open_browser),
                  self._button("Log", self._show_log),
                  self._button("Console", self._open_console))

        login = self._card(column, "Login")
        self._row(login,
                  self._button("Import ticket", self._import_ticket),
                  self._button("Forget ticket", self._forget_ticket))

        bluetooth = self._card(column, "Bluetooth")
        self._row(bluetooth,
                  self._button("Start bridge", self._start_ble),
                  self._button("Stop bridge", self._stop_ble))

        settings = self._card(column, "Settings")
        self.dir_entry = QLineEdit()
        self.dir_entry.setPlaceholderText("jawn folder (default ~/jawnos)")
        self.autostart = QCheckBox("Start the BLE bridge at login")
        self.ble_with_jawn = QCheckBox("Start/stop the BLE bridge with jawn")
        settings.addWidget(self.dir_entry)
        settings.addWidget(self.autostart)
        settings.addWidget(self.ble_with_jawn)
        settings.addWidget(self._button("Save settings", self._save, primary=True))

        app = self._card(column, "App")
        self.app_state = self._dim_label()
        app.addWidget(self.app_state)
        self.update_button = self._button("Update app", self._update_app, primary=True)
        app.addWidget(self.update_button)

        column.addStretch(1)

    # ---- settings --------------------------------------------------------

    def showEvent(self, event):
        self._load_settings()
        self.refresh()
        super().showEvent(event)

    def closeEvent(self, event):
        self.hide()
        event.ignore()

    def _load_settings(self):
        if not self._busy:
            self.dir_entry.setText(self.settings.get("jawn_dir", ""))
            self.autostart.setChecked(core.autostart_enabled())
            self.ble_with_jawn.setChecked(bool(self.settings.get("ble_with_jawn", True)))

    def _save(self):
        self.settings["jawn_dir"] = os.path.expanduser(
            self.dir_entry.text().strip() or core.default_jawn_dir())
        self.settings["ble_with_jawn"] = self.ble_with_jawn.isChecked()
        core.save_settings(self.settings)
        core.set_autostart(self.autostart.isChecked())
        self.settings["autostart"] = self.autostart.isChecked()
        self._say("settings saved")
        self.refresh()

    def _with_ble(self):
        return bool(self.settings.get("ble_with_jawn", True))

    def _dir(self):
        return self.settings.get("jawn_dir") or core.default_jawn_dir()

    # ---- actions ---------------------------------------------------------

    def _run(self, work):
        if self._busy:
            return
        self._busy = True
        self._say("working...")

        def runner():
            message = ""
            try:
                result = work()
                if isinstance(result, tuple) and len(result) > 1:
                    message = str(result[1])
            except Exception as exc:
                message = str(exc)
            self._busy = False
            self.note.emit(message or "done")
            self.refreshed.emit()

        threading.Thread(target=runner, daemon=True).start()

    def _start(self):
        self._save()
        self._run(lambda: core.start_all(self._dir(), self._with_ble()))

    def _stop(self):
        self._run(lambda: core.stop_all(self._dir(), self._with_ble()))

    def _restart(self):
        self._save()
        self._run(lambda: core.restart_all(self._dir(), self._with_ble()))

    def _tailnet_up(self):
        self._run(core.tailnet_up)

    def _tailnet_down(self):
        self._run(core.tailnet_down)

    def _start_ble(self):
        self._run(core.start_ble)

    def _stop_ble(self):
        self._run(core.stop_ble)

    def _show_view(self):
        self.actions.get("show_view", lambda: None)()

    def _show_log(self):
        self.actions.get("show_log", lambda: None)()

    def _open_browser(self):
        if not core.open_ui(self._dir()):
            self._say("could not open a browser")

    def _open_console(self):
        ok, message = core.open_console(self._dir())
        self._say(message)

    def _import_ticket(self):
        url, ok = QInputDialog.getText(
            self, "Import login ticket",
            "Ticket URL:",
            QLineEdit.EchoMode.Normal,
            "https://host:3000/box_office/<uuid>?s=<token>")
        if not ok or not url.strip():
            return
        try:
            from . import secrets
            ok, message = secrets.store(url.strip())
        except Exception as exc:
            ok, message = False, str(exc)
        self._say(message)
        self.refresh()

    def _forget_ticket(self):
        try:
            from . import secrets
            secrets.clear()
            self._say("stored ticket cleared")
        except Exception as exc:
            self._say(str(exc))
        self.refresh()

    def _update_app(self):
        if not core.update_available(self.settings):
            self._say("already up to date")
            self.refresh()
            return
        ok, name, _code = core.apply_update(self.settings)
        if not ok:
            self._say("already up to date")
            self.refresh()
            return
        self._say("updated to v%s - restarting..." % name)
        self.actions.get("restart", lambda: None)()

    # ---- status ----------------------------------------------------------

    def refresh(self):
        if self._status_busy:
            return
        self._status_busy = True
        settings = self.settings
        now = time.monotonic()
        want_tail = now - self._tail_at >= 5

        def runner():
            data = {}
            try:
                jawn_dir = self._dir()
                data["folder"] = jawn_dir
                data["jawn"] = core.jawn_up(jawn_dir)
                data["ble"] = core.ble_up()
                if want_tail:
                    self._tail_at = now
                    self._tail = core.tailnet_state()
                data["tail"] = self._tail
                try:
                    from . import secrets
                    data["ticket"] = secrets.describe()
                except Exception:
                    data["ticket"] = "?"
                data["autostart"] = core.autostart_enabled()
                info = core.installed_info()
                data["app"] = (info.get("versionName") or "?",
                               info.get("versionCode") or 0)
                data["newer"] = core.update_available(settings)
            except Exception as exc:
                data["error"] = str(exc)
            finally:
                self._status_busy = False
            self.status_ready.emit(data)

        threading.Thread(target=runner, daemon=True).start()

    @Slot(object)
    def _render(self, data):
        if not isinstance(data, dict):
            return
        if data.get("error"):
            self._say(data["error"])
            return
        jawn = bool(data.get("jawn"))
        label, tone = core.jawn_status(jawn)
        self.jawn_state.setText("jawn  \u2014  " + label)
        self.jawn_dot.set_colour(theme.TONES[tone])

        ble = bool(data.get("ble"))
        self.ble_state.setText(
            "BLE bridge  \u2014  " + ("running" if ble else "stopped"))
        self.ble_dot.set_colour(theme.GREEN if ble else theme.DIM)

        tail = data.get("tail") or {}
        state = tail.get("state") or ("Running" if tail.get("running") else "Stopped")
        tlabel = {
            "Running": "running", "Stopped": "stopped",
            "Starting": "starting", "NeedsLogin": "needs login",
            "NoState": "not installed",
        }.get(state, state.lower() or "stopped")
        if tail.get("error") and not tail.get("available"):
            tlabel = "unavailable"
        if tail.get("network_restart"):
            tlabel += " \u00b7 " + tail.get("network_restart")
        self.tail_state.setText("Tailnet  \u2014  " + tlabel)
        if tail.get("running"):
            ttone = "green"
        elif state in ("Starting", "NeedsLogin"):
            ttone = "amber"
        else:
            ttone = "dim"
        self.tail_dot.set_colour(theme.TONES[ttone])

        self.env_state.setText(
            "folder: %s\nautostart: %s\nlogin ticket: %s" % (
                data.get("folder", ""),
                "enabled" if data.get("autostart") else "disabled",
                str(data.get("ticket") or "?")))

        name, code = data.get("app") or ("?", 0)
        newer = data.get("newer")
        if newer:
            self.app_state.setText(
                "desktop v%s (%s)\nan update to v%s is ready." % (
                    name, code, newer[0] or "newer"))
        else:
            self.app_state.setText(
                "desktop v%s (%s)\nup to date - tap Update app to check again."
                % (name, code))
        self.update_button.setEnabled(True)

    @Slot(str)
    def _say(self, text):
        self.live.setText(str(text or ""))
