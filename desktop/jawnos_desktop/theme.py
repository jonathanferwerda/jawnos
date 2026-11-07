"""The desktop's shared look: the status colours and the panel's stylesheet.

These are the values the WebKitGTK dashboard carries in ``ui.py`` (``_CSS`` and
the ``*_RGB`` tuples) -- black ground, rounded cards, the jawn yellow accent and
the green/amber/red status dots. Keeping them in one toolkit-neutral module lets
the Qt control panel, its status dots and the tray badge use the same palette
without either importing the other.

Nothing here imports a GUI toolkit.
"""

# The live status dots: the same greens/ambers/reds the manager and the Android
# dashboard use.
GREEN = (0x34, 0xC7, 0x59)
AMBER = (0xFF, 0xB0, 0x20)
RED = (0xFF, 0x45, 0x3A)
DIM = (0x8E, 0x8E, 0x8E)

# core.jawn_status() and the tailnet's state both name a tone; the dots and the
# tray badge look it up here.
TONES = {
    "green": GREEN,
    "amber": AMBER,
    "red": RED,
    "dim": DIM,
}

# The panel's stylesheet (Qt style sheets, which use these selectors). Object
# names, not classes, identify the parts: `card`, `title`, `h` (a section
# header), `dim` and `state` mirror the GTK widget classes of the same name.
PANEL_CSS = """
QDialog#panel, QWidget#body, QScrollArea,
QScrollArea > QWidget > QWidget {
    background-color: #000000;
}
QScrollArea { border: none; }
QFrame#card {
    background-color: #1b1b1b;
    border: 1px solid #2c2c2c;
    border-radius: 18px;
}
QLabel { color: #ededed; }
QLabel#title { font-size: 24px; font-weight: bold; }
QLabel#dim { color: #8e8e8e; font-size: 12px; }
QLabel#h { color: #8e8e8e; font-size: 11px; font-weight: bold; }
QLabel#state { font-size: 16px; }
QPushButton {
    background-color: #262626;
    color: #ededed;
    border: 1px solid #2c2c2c;
    border-radius: 13px;
    padding: 12px 14px;
}
QPushButton:hover { background-color: #303030; }
QPushButton[primary="true"] {
    background-color: #ffcc00;
    color: #0a0a0a;
    border: 1px solid #ffcc00;
    font-weight: bold;
}
QPushButton[primary="true"]:hover { background-color: #e6b800; }
QPushButton#logo {
    background: transparent;
    border: none;
    padding: 0;
}
QLineEdit {
    background-color: #262626;
    color: #ededed;
    border: 1px solid #2c2c2c;
    border-radius: 10px;
    padding: 9px;
}
QCheckBox { color: #ededed; }
QScrollBar:vertical { background: #000000; width: 10px; margin: 0; }
QScrollBar::handle:vertical { background: #2c2c2c; border-radius: 5px; min-height: 24px; }
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height: 0; }
"""
