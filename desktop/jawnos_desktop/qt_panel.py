"""The Qt control panel: the desktop's supervisor in one window.

This replaces the GTK dashboard's panel. It reads the same ``core`` supervisor
and keeps the same controls: jawn start/stop/restart, the tailnet, the BLE
bridge, the login ticket, the app update and the settings, with the live
status line the GTK panel had. The Qt shell owns the window, the tray item and
the web view; the page's admin icon opens this panel.
"""

import os
import threading
import time

from PySide6.QtCore import QTimer, Qt, Signal, Slot
from PySide6.QtWidgets import (
    QCheckBox,
    QDialog,
    QFormLayout,
    QGroupBox,
    QHBoxLayout,
    QInputDialog,
    QLabel,
    QLineEdit,
    QPushButton,
    QScrollArea,
    QVBoxLayout,
    QWidget,
)

from . import core


class ControlPanel(QDialog):
    status_ready = Signal(object)
    note = Signal(str)
    refreshed = Signal()

    def __init__(self, settings, actions, parent=None):
        super().__init__(parent)
        self.settings = settings
        self.actions = actions
        self.setWindowTitle("JawnOS control panel")
        self.resize(780, 900)
        self._busy = False
        self._status_busy = False
        self._tail = {}
        self._tail_at = 0.0
        self._build()
        self.status_ready.connect(self._render)
        self.note.connect(self._say)
        self.refreshed.connect(self.refresh)
        self.timer = QTimer(self)
        self.timer.timeout.connect(self.refresh)
        self.timer.start(2000)

    # ---- layout ----------------------------------------------------------

    def _button(self, text, callback, primary=False):
        button = QPushButton(text)
        if primary:
            button.setDefault(True)
        button.clicked.connect(callback)
        return button

    def _group(self, title):
        box = QGroupBox(title)
        layout = QVBoxLayout(box)
        layout.setContentsMargins(10, 12, 10, 10)
        return box, layout

    def _row(self, *buttons):
        row = QWidget()
        layout = QHBoxLayout(row)
        layout.setContentsMargins(0, 0, 0, 0)
        for button in buttons:
            layout.addWidget(button)
        layout.addStretch(1)
        return row

    def _build(self):
        outer = QVBoxLayout(self)
        scroller = QScrollArea()
        scroller.setWidgetResizable(True)
        body = QWidget()
        column = QVBoxLayout(body)
        column.setSpacing(10)
        scroller.setWidget(body)
        outer.addWidget(scroller, 1)

        status, status_layout = self._group("Status")
        form = QFormLayout()
        self.jawn_state = QLabel("jawn - checking...")
        self.ble_state = QLabel("BLE bridge - checking...")
        self.tail_state = QLabel("Tailnet - checking...")
        self.ticket_state = QLabel("login ticket - checking...")
        form.addRow(self.jawn_state)
        form.addRow(self.ble_state)
        form.addRow(self.tail_state)
        form.addRow(self.ticket_state)
        status_layout.addLayout(form)
        self.env_state = QLabel("")
        self.env_state.setWordWrap(True)
        status_layout.addWidget(self.env_state)
        column.addWidget(status)

        jawn, jawn_layout = self._group("Jawn")
        jawn_layout.addWidget(self._row(
            self._button("Start", self._start, primary=True),
            self._button("Restart", self._restart),
            self._button("Stop", self._stop),
        ))
        column.addWidget(jawn)

        tailnet, tailnet_layout = self._group("Tailnet")
        tailnet_layout.addWidget(self._row(
            self._button("Start VPN", self._tailnet_up, primary=True),
            self._button("Stop VPN", self._tailnet_down),
        ))
        column.addWidget(tailnet)

        opn, open_layout = self._group("Open")
        open_layout.addWidget(self._row(
            self._button("JawnOS UI", self._show_view, primary=True),
            self._button("In browser", self._open_browser),
            self._button("Log", self._show_log),
            self._button("Console", self._open_console),
        ))
        column.addWidget(opn)

        login, login_layout = self._group("Login")
        login_layout.addWidget(self._row(
            self._button("Import ticket", self._import_ticket),
            self._button("Forget ticket", self._forget_ticket),
        ))
        column.addWidget(login)

        bluetooth, ble_layout = self._group("Bluetooth")
        ble_layout.addWidget(self._row(
            self._button("Start bridge", self._start_ble),
            self._button("Stop bridge", self._stop_ble),
        ))
        column.addWidget(bluetooth)

        settings, settings_layout = self._group("Settings")
        self.dir_entry = QLineEdit()
        self.dir_entry.setPlaceholderText("jawn folder (default ~/jawnos)")
        self.autostart = QCheckBox("Start the BLE bridge at login")
        self.ble_with_jawn = QCheckBox("Start/stop the BLE bridge with jawn")
        settings_layout.addWidget(self.dir_entry)
        settings_layout.addWidget(self.autostart)
        settings_layout.addWidget(self.ble_with_jawn)
        settings_layout.addWidget(self._row(
            self._button("Save settings", self._save, primary=True),
        ))
        column.addWidget(settings)

        app, app_layout = self._group("App")
        self.app_state = QLabel("")
        self.app_state.setWordWrap(True)
        app_layout.addWidget(self.app_state)
        self.update_button = self._button("Update app", self._update_app, primary=True)
        app_layout.addWidget(self._row(self.update_button))
        column.addWidget(app)

        column.addStretch(1)
        self.live = QLabel("")
        self.live.setWordWrap(True)
        outer.addWidget(self.live)
        hide = QPushButton("Hide")
        hide.clicked.connect(self.hide)
        outer.addWidget(hide, 1, Qt.AlignmentFlag.AlignRight)

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
                data["env"] = "folder: %s\nautostart: %s" % (
                    jawn_dir,
                    "enabled" if core.autostart_enabled() else "disabled")
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
        ble = bool(data.get("ble"))
        self.jawn_state.setText("jawn - " + ("running" if jawn else "not running"))
        self.jawn_state.setStyleSheet(
            "color: %s" % ("#4caf50" if jawn else "#e57373"))
        self.ble_state.setText(
            "BLE bridge - " + ("running" if ble else "stopped"))
        self.ble_state.setStyleSheet(
            "color: %s" % ("#4caf50" if ble else "#999999"))
        tail = data.get("tail") or {}
        state = tail.get("state") or ("Running" if tail.get("running") else "Stopped")
        label = {
            "Running": "running", "Stopped": "stopped",
            "Starting": "starting", "NeedsLogin": "needs login",
            "NoState": "not installed",
        }.get(state, state.lower() or "stopped")
        if tail.get("error") and not tail.get("available"):
            label = "unavailable"
        self.tail_state.setText("Tailnet - " + label)
        self.ticket_state.setText("login ticket - " + str(data.get("ticket") or "?"))
        self.env_state.setText(str(data.get("env") or ""))
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
