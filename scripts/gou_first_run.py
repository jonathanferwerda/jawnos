#!/usr/bin/env python3
"""First-run setup on a controller's panel.

A board arrives with no password anyone knows and, often, a card in the slot
nobody has answered for. This runs on the panel after X and before both the
root first-boot pass and the launcher, so the person answers two questions
while there is still nothing to damage:

  * the code that will be this machine's sudo password;
  * whether the card in the slot may be erased.

The answers go to ~/.presence/gou-first-run.json and the root pass applies
them; that pass also writes the .done marker, so a second boot never asks.
Nothing here needs root: the dialog runs as `jawn`, the account that owns the
display, and a password typed here is written by the pass that is already root.

Usage: gou_first_run.py [--probe]
  --probe  print what would be asked and exit (a boot-time smoke test)
"""
import json
import os
import sys

PRESENCE = os.path.join(os.path.expanduser("~"), ".presence")
ANSWERS = os.path.join(PRESENCE, "gou-first-run.json")
DONE = os.path.join(PRESENCE, "gou-first-run.done")
MIN_CODE = 4
MAX_CODE = 12


def card_present():
    """Is there a card in the slot that a wipe would reach?

    The planner's rule, kept in step with gou_first_boot.pl: the controller's
    slot reports itself as fixed (mmcblk0 rm=0), so the removable flag cannot
    find it - the device type can. The disk the system is running from is never
    a candidate.
    """
    try:
        blocks = sorted(
            name for name in os.listdir("/sys/block") if name.startswith("mmcblk")
        )
    except OSError:
        return False
    root_dev = ""
    try:
        with open("/proc/mounts") as fh:
            for line in fh:
                fields = line.split()
                if len(fields) > 1 and fields[1] == "/":
                    root_dev = os.path.basename(fields[0])
    except OSError:
        pass

    def is_root_disk(name):
        """Is this the disk the system runs from?

        Asked of sysfs rather than by trimming a device name: /sys/block/mmcblk1
        contains mmcblk1p2 and /sys/block/mmcblk0 does not, which is exactly the
        question, and no amount of string surgery gets "mmcblk1p2 -> mmcblk1,
        sda2 -> sda, mmcblk0 -> mmcblk0" right in one pass.
        """
        if not root_dev:
            return False
        if name == root_dev:
            return True
        return os.path.exists("/sys/block/%s/%s" % (name, root_dev))

    for name in blocks:
        if is_root_disk(name):
            continue
        try:
            with open("/sys/block/%s/device/type" % name) as fh:
                if fh.read().strip().upper() == "SD":
                    return True
        except OSError:
            continue
    for name in blocks:
        if is_root_disk(name):
            continue
        try:
            with open("/sys/block/%s/removable" % name) as fh:
                if fh.read().strip() == "1":
                    return True
        except OSError:
            continue
    return False


def write_answers(code, wipe):
    os.makedirs(PRESENCE, exist_ok=True)
    tmp = ANSWERS + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump({"code": code, "wipe": bool(wipe)}, fh)
        fh.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, ANSWERS)


def probe():
    print(json.dumps({"done": os.path.exists(DONE), "card": card_present()}))
    return 0


def main():
    if "--probe" in sys.argv:
        return probe()
    if os.path.exists(DONE):
        return 0
    try:
        from PySide6.QtCore import Qt
        from PySide6.QtWidgets import (
            QApplication, QCheckBox, QGridLayout, QHBoxLayout, QLabel,
            QPushButton, QVBoxLayout, QWidget,
        )
    except Exception as exc:  # noqa: BLE001
        sys.stderr.write("gou-first-run: Qt is not available: %r\n" % (exc,))
        return 0

    app = QApplication([sys.argv[0]])
    app.setApplicationName("JawnOS first run")

    ink, panel, line = "#f4f4f4", "#2e2e2e", "#4a4a4a"
    win = QWidget()
    win.setWindowTitle("JawnOS")
    win.setStyleSheet(
        "QWidget { background:#1a1a1a; color:%s; }"
        "QLabel { color:%s; }"
        "QPushButton { background:%s; border:1px solid %s; border-radius:10px;"
        " padding:6px; font-size:22px; color:%s; }"
        "QPushButton:disabled { color:#777; }"
        "QCheckBox { font-size:18px; color:%s; padding:7px; }"
        % (ink, ink, panel, line, ink, ink)
    )
    outer = QVBoxLayout(win)
    outer.setContentsMargins(14, 10, 14, 10)
    outer.setSpacing(6)

    title = QLabel("<b style='font-size:24px'>Set up this controller</b>")
    outer.addWidget(title)
    note = QLabel("Choose a code for this board. It is the sudo password.")
    note.setStyleSheet("color:#c8c8c8; font-size:15px;")
    outer.addWidget(note)

    body = QHBoxLayout()
    body.setSpacing(14)
    outer.addLayout(body, 1)

    keys = QWidget()
    grid = QGridLayout(keys)
    grid.setSpacing(6)
    entry = QLabel("")
    entry.setAlignment(Qt.AlignCenter)
    entry.setStyleSheet(
        "font-size:26px; letter-spacing:8px; background:#101010;"
        " border:1px solid %s; border-radius:10px; padding:6px;" % line
    )
    grid.addWidget(entry, 0, 0, 1, 3)
    state = {"code": ""}

    ok = QPushButton("Continue")
    ok.setEnabled(False)

    def refresh():
        entry.setText("*" * len(state["code"]) or "____")
        ok.setEnabled(len(state["code"]) >= MIN_CODE)

    def digits(text):
        if len(state["code"]) >= MAX_CODE:
            return
        state["code"] += text
        refresh()

    def back():
        state["code"] = state["code"][:-1]
        refresh()

    buttons = []
    for i, label in enumerate(["1", "2", "3", "4", "5", "6", "7", "8", "9"]):
        b = QPushButton(label)
        b.clicked.connect(lambda _=False, t=label: digits(t))
        grid.addWidget(b, 1 + i // 3, i % 3)
        buttons.append(b)
    zero = QPushButton("0")
    zero.clicked.connect(lambda: digits("0"))
    grid.addWidget(zero, 4, 1)
    wipe = QPushButton("Clear")
    wipe.clicked.connect(lambda: (state.update(code=""), refresh()))
    grid.addWidget(wipe, 4, 0)
    dele = QPushButton("\u232b")
    dele.clicked.connect(back)
    grid.addWidget(dele, 4, 2)
    body.addWidget(keys, 3)

    side = QVBoxLayout()
    side.setSpacing(10)
    erase = QCheckBox("Erase the card in the slot\n(everything on it is lost)")
    if not card_present():
        erase.setChecked(False)
        erase.setEnabled(False)
        erase.setText("No card in the slot")
    side.addWidget(erase)
    side.addStretch(1)
    side.addWidget(ok)
    body.addLayout(side, 2)

    def finish():
        write_answers(state["code"], erase.isChecked() and erase.isEnabled())
        app.quit()

    ok.clicked.connect(finish)
    refresh()
    # No window manager runs on this panel, so a fullscreen request goes to
    # nobody: size to the screen first, exactly as the shell does.
    screen = app.primaryScreen()
    if screen is not None:
        win.resize(screen.size())
    win.showFullScreen()
    win.show()
    buttons[0].setFocus()
    sys.stderr.write("gou-first-run: asked (card=%s)\n" % card_present())
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
