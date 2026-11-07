# tests-for: desktop/jawnos_desktop/shell.py desktop/jawnos-shell
# covers:    the session bar is Qt (PySide6), with no GTK import; on Wayland it
#           attaches the window to wlr-layer-shell through a ctypes shim over
#           layer-shell-qt's C++ symbols (top layer, top/left/right anchors, the
#           same exclusive zone and keyboard mode as the GTK bar), and on X11 or
#           when the package is missing it falls back to a frameless always-on-top
#           window. The same widgets and Sway/manager/playerctl reads are still
#           there, and the bar constructs offscreen without a display server.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file write_file);

my $root = "$FindBin::Bin/..";
my $src = read_file("$root/desktop/jawnos_desktop/shell.py");
my $entry = read_file("$root/desktop/jawnos-shell");
my $readme = read_file("$root/desktop/README.md");
my $mkosi = read_file("$root/desktop/mkosi/mkosi.conf");

# --- no GTK ---------------------------------------------------------------
unlike($src, qr/^\s*import\s+gi\b/m, 'the bar does not import gi');
unlike($src, qr/gi\.require_version/, 'nor ask gi for a typelib version');
unlike($src, qr/from\s+gi\.repository/, 'nor import a gi repository');
unlike($src, qr/GtkLayerShell|Gtk\.|Gdk\.|GLib\.|Pango\./,
	'no GTK, GDK, GLib or Pango calls remain');

# --- Qt toolkit -----------------------------------------------------------
like($src, qr/from PySide6\.QtCore import/, 'the bar is a Qt program');
like($src, qr/from PySide6\.QtWidgets import/, 'with Qt widgets');
like($src, qr/class Shell\(QWidget\)/, 'the bar is a QWidget');
like($src, qr/setApplicationName\("jawnos-session"\)/,
	'the session app id is jawnos-session');
like($src, qr/setDesktopFileName\("jawnos-session"\)/,
	'Wayland derives app_id from the desktop file name');
like($src, qr/_prepare_wayland_env/, 'a Sway session is pointed at Wayland');
like($src, qr/QT_QPA_PLATFORM.*wayland|wayland.*QT_QPA_PLATFORM/s,
	'unless QT_QPA_PLATFORM was chosen explicitly');

# --- the layer-shell shim -------------------------------------------------
like($src, qr/libLayerShellQtInterface/, 'layer-shell-qt is loaded by soname');
like($src, qr/ctypes\.CDLL/, 'through ctypes: the package exposes C++, not C');
like($src, qr/_ZN12LayerShellQt6Window3getEP7QWindow/,
	'LayerShellQt::Window::get(QWindow*) is resolved');
like($src, qr/_ZN12LayerShellQt6Window10setAnchorsE6QFlagsINS0_6AnchorEE/,
	'and setAnchors (QFlags<Anchor> is an int on the wire)');
like($src, qr/_ZN12LayerShellQt6Window16setExclusiveZoneEi/,
	'and setExclusiveZone(int)');
like($src, qr/_ZN12LayerShellQt6Window8setLayerENS0_5LayerE/,
	'and setLayer(Layer)');
like($src,
	qr/_ZN12LayerShellQt6Window24setKeyboardInteractivityENS0_21KeyboardInteractivityE/,
	'and setKeyboardInteractivity');
like($src, qr/shiboken6\.getCppPointer/, 'the QWindow PySide6 owns is passed through');
like($src, qr/ANCHOR_TOP \| self\.ANCHOR_LEFT \| self\.ANCHOR_RIGHT/,
	'top, left and right anchors');
like($src, qr/LAYER_TOP/, 'the top layer');
like($src, qr/KEYBOARD_NONE/, 'and no keyboard focus, as the GTK bar had');
like($src, qr/_funcs\["zone"\]\(ref, int\(height\)\)/,
	'the exclusive zone is the bar height');

# --- fallback -------------------------------------------------------------
like($src, qr/Qt\.WindowType\.FramelessWindowHint/, 'the fallback has no decorations');
like($src, qr/Qt\.WindowType\.WindowStaysOnTopHint/, 'and stays above normal windows');
like($src, qr/WA_ShowWithoutActivating/, 'without stealing focus when shown');
like($src, qr/app_id="jawnos-session"\].*floating enable/s,
	'the Sway fallback floats the bar');
like($src, qr/move position 0 0/, 'moves it to the output edge');
like($src, qr/resize set width %d px height %d px/, 'sizes it to the output');
like($src, qr/resize set width %d px height %d px, move position 0 0/s,
	'resizing precedes the move (Sway re-centres a resized float)');
like($src, qr/floating_minimum_size 75 x %d/,
	'and lowers Sway\'s 50px floating floor for a thin bar');
like($src, qr/sticky enable/, 'and pins it to every workspace');
like($src, qr/def _tree_find_app/, 'waiting for Sway to map the app_id');
like($src, qr/_place_x11/, 'X11 places it at 0,0 across the screen');
like($src, qr/def _place_sway_window/, 'Sway gets a runtime rule, not just a config line');

# --- the same content and reads ------------------------------------------
like($src, qr/QPushButton\("Jawn"\)/, 'the launcher is still there');
like($src, qr/setToolTip\("Open the launcher"\)/, 'with its tooltip');
like($src, qr/workspace " \+ _sway_quote\(name\)/, 'workspace buttons still switch');
like($src, qr/_pretty_app_name/, 'the focused app is named');
like($src, qr/_icon_candidates/, 'and given a themed icon');
like($src, qr/playerctl/, 'now-playing still comes from playerctl');
like($src, qr/ManagerClient/, 'today\'s app time still comes from the manager');
like($src, qr/"Today " \+ usage\.format_duration/, 'and is formatted the same way');
like($src, qr/strftime\("%H:%M"\)/, 'the clock still ticks');
like($src, qr/strftime\("%a %d %b"\)/, 'with the date');
like($src, qr/fuzzel/, 'fuzzel is still preferred when installed');
like($src, qr/QInputDialog\.getText/, 'with a Qt command prompt as the fallback');
like($src, qr/swaymsg/, 'Sway IPC is still used');

# --- entry point and docs -------------------------------------------------
like($entry, qr/from jawnos_desktop\.shell import main/,
	'jawnos-shell still starts the same main()');
ok(-x "$root/desktop/jawnos-shell", 'jawnos-shell is executable');
like($readme, qr/session bar.*?is Qt/is,
	'the desktop README says the session bar is Qt');
like($readme, qr/layer-shell-qt/, 'and names the layer-shell package');
like($mkosi, qr/^\s*layer-shell-qt\s*$/m,
	'the live image installs layer-shell-qt');

# --- runtime construction, offscreen -------------------------------------
my $probe = tempdir(CLEANUP => 1);
write_file("$probe/probe.py", <<'PROBE_PY');
import argparse
import sys

from PySide6.QtWidgets import QApplication

from jawnos_desktop.shell import BAR_HEIGHT, Shell, _LayerShell

app = QApplication(["probe"])
args = argparse.Namespace(height=BAR_HEIGHT, jawn_dir=None, no_music=True,
                          no_layer_shell=False)
shell = Shell(args)
shell._tick_clock()

assert app.platformName() == "offscreen", app.platformName()
assert "gi" not in sys.modules, "GTK was imported"
assert shell.using_layer_shell is False, "the shim claimed an offscreen window"
assert shell.height == BAR_HEIGHT
assert shell.launcher.text() == "Jawn"
assert shell.usage_label.text().startswith("Today")
assert shell.time_label.text(), "the clock is empty"
assert shell.date_label.text(), "the date is empty"
assert "ffcc00" in shell.styleSheet(), "the bar's stylesheet was not applied"

shell.apply_sway([{"name": "1", "focused": True},
                  {"name": "2", "urgent": True}], "foot", "~/jawnos")
assert shell.ws_layout.count() == 2, shell.ws_layout.count()
assert shell.app_label.text() == "Terminal", shell.app_label.text()

shell.set_usage("Today 1h", True)
assert shell.usage_label.text() == "Today 1h"
assert shell.usage_label.property("offline") is False
shell.set_usage("Today \u2014", False)
assert shell.usage_label.property("offline") is True

shell.set_music("\u266a A \u2014 B")
assert shell.music_label.isHidden() is False
shell.set_music(None)
assert shell.music_label.isHidden() is True

shim = _LayerShell()
assert set(shim._SYMBOLS) == {"get", "anchors", "zone", "layer", "keyboard"}
assert shim._SYMBOLS["get"] == "_ZN12LayerShellQt6Window3getEP7QWindow"

shell.stop()
app.quit()
print("probe-ok")
PROBE_PY

my $pyside = qx{python3 -c "import PySide6.QtWidgets" 2>/dev/null};
my $pyside_ok = $? == 0;

SKIP: {
	skip 'PySide6 is not installed', 3 unless $pyside_ok;
	my $ran = qx{cd "$root/desktop" && QT_QPA_PLATFORM=offscreen PYTHONPATH=. python3 "$probe/probe.py" 2>&1};
	my $status = $?;
	is($status, 0, 'the Qt bar constructs on the offscreen platform');
	like($ran, qr/^probe-ok$/m, 'and keeps its widgets, reads and shim table');
	unlike($ran, qr/Traceback|AssertionError/, 'with no traceback');
}

done_testing();
