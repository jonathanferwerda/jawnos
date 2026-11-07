# tests-for: desktop/jawnos_desktop/qt_shell.py desktop/jawnos_desktop/qt_panel.py desktop/jawnos_desktop/bridge.py desktop/jawnos_desktop/keepawake.py desktop/jawnos_desktop/gpu.py desktop/jawnos_desktop/theme.py desktop/jawnos_desktop/core.py desktop/jawnos-desktop desktop/jawnos-qt desktop/wayland/jawnos-session
# covers:    the Qt WebEngine desktop shell is the default: the same Manager page
#           in Chromium, which is the engine with WebRTC (Debian's WebKitGTK is
#           built without RTCPeerConnection), the ticket cookie kept on disk,
#           microphone/camera grants, the house's own certificate accepted, the
#           page bridge, supervision, the GTK dashboard's look in the Qt panel
#           and tray, the GPU flags that keep the embedded card in use, and the
#           WebKitGTK fallback.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);

my $root = "$FindBin::Bin/..";
my $qt = read_file("$root/desktop/jawnos_desktop/qt_shell.py");
my $panel = read_file("$root/desktop/jawnos_desktop/qt_panel.py");
my $keepawake = read_file("$root/desktop/jawnos_desktop/keepawake.py");
my $bridge = read_file("$root/desktop/jawnos_desktop/bridge.py");
my $gpu = read_file("$root/desktop/jawnos_desktop/gpu.py");
my $theme = read_file("$root/desktop/jawnos_desktop/theme.py");
my $core = read_file("$root/desktop/jawnos_desktop/core.py");
my $webview = read_file("$root/desktop/jawnos_desktop/webview.py");
my $entry = read_file("$root/desktop/jawnos-desktop");
my $session = read_file("$root/desktop/wayland/jawnos-session");
my $launcher = "$root/desktop/jawnos-qt";

like($qt, qr/from PySide6\.QtWebEngineWidgets import QWebEngineView/,
	'the shell is Qt WebEngine');
like($qt, qr/QWebEngineProfile\("jawnos"/, 'a named, on-disk profile');
like($qt, qr/ForcePersistentCookies/, 'so the login cookie survives a restart');
like($qt, qr/MediaAudioCapture/, 'the microphone permission is granted');
like($qt, qr/MediaAudioVideoCapture/, 'and the camera/audio pair');
like($qt, qr/certificateError/, 'the house self-signed certificate is accepted');
like($qt, qr/typeof RTCPeerConnection/, 'the probe asks the engine for WebRTC');
like($qt, qr/createOffer\(\)/, 'and proves it with a real offer');
like($qt, qr/UNMASKED_RENDERER_WEBGL/,
	'and reports which renderer paints (software, or the Intel card)');
like($qt, qr/--probe/, 'the probe is a command-line mode');
like($qt, qr/def ticket_url/, 'it reads the same stored ticket as the WebKit shell');
like($qt, qr/def _probe_url/, 'the probe uses a real origin for the bridge');
like($qt, qr/def manager_url/, 'and derives the manager URL from it');

like($entry, qr/JAWNOS_DESKTOP_ENGINE/, 'the engine can be chosen by environment');
like($entry, qr/--engine/, 'and by flag');
like($entry, qr/return "qt" if _qt_available\(\) else "webkit"/,
	'Qt is the default, WebKitGTK the fallback');
like($entry, qr/from jawnos_desktop\.qt_shell import main/, 'Qt is the primary branch');
like($entry, qr/from jawnos_desktop\.ui import main/, 'WebKitGTK stays reachable');
like($entry, qr/import PySide6\.QtWebEngineWidgets/,
	'and the choice is made by whether the engine imports');
ok(-x $launcher, 'jawnos-qt is directly runnable');

# The engine resolver, without starting a GUI. qt and webkit are deterministic;
# auto depends on the machine's packages (pinned above in the source).
my $choose = `cd "$root" && python3 -c 'import runpy; m=runpy.run_path("desktop/jawnos-desktop"); print(m["choose_engine"]("qt"), m["choose_engine"]("webkit"))' 2>&1`;
like($choose, qr/^qt webkit$/m, 'the resolver honours an explicit engine');

# The page bridge: the shim the Qt shell installs gives the page the same
# handlers WebKitGTK registers, and the shared module holds the key and scripts.
like($qt, qr/__jawnQtBridge/, 'the page is given a Qt bridge object');
like($qt, qr/QWebChannel/, 'over QWebChannel');
like($qt, qr/messageHandlers\[name\]/, 'and the WebKit handler names the page checks');
like($qt, qr/window\.JawnDesktop/, 'the desktop marker universal.js keys app login off');
like($qt, qr/def handle_message\([^)]*allowed_host/,
	'the handler receives the window\'s manager host');
like($qt, qr/def _qurl_host/, 'and reads a QUrl host with the right API');
unlike($qt, qr/\.url\(\)\.hostname\(\)/, 'not the urlparse spelling');
like($qt, qr/handle_message\(name, raw, page_obj, view_obj, allowed_host\)/,
	'and the bridge passes it through');
like($qt, qr/bridge\.app_public_pem|bridge\.app_sign_b64/,
	'the app key is answered through the shared bridge');
like($bridge, qr/def app_public_pem/, 'the app key lives in the toolkit-neutral module');
like($bridge, qr/def app_sign_b64/, 'with its signer');
like($bridge, qr/def browse_launcher/, 'and the Browse launcher');
like($bridge, qr/BROWSE_BRIDGE_JS/, 'the Browse shim');
like($bridge, qr/MEDIA_MONITOR_JS/, 'and the media monitor the keep-awake uses');
like($webview, qr/from \.bridge import/, 'the WebKitGTK shell uses the same bridge');
unlike($webview, qr/^def _app_public_pem/m,
	'so the key is not defined twice');

like($qt, qr/def prepare_wayland_env/, 'a Wayland session sets the Qt platform');
like($qt, qr/--ozone-platform-hint=auto/,
	'Chromium gets the Ozone hint (the Wayland platform is not in every build)');
unlike($qt, qr/flags \+ " --ozone-platform=wayland"/,
	'and never the explicit platform Arch\'s QtWebEngine lacks');

# The embedded card stays in use: a GPU environment, then Chromium flags that
# keep rasterisation off the CPU (the GTK Skylake fallback was a WebKit bug and
# is deliberately not ported).
like($gpu, qr/--ignore-gpu-blocklist/, 'the GPU blocklist does not strand an older Intel card');
like($gpu, qr/--enable-gpu-rasterization/, 'raster work stays on the card');
like($gpu, qr/LIBVA_DRIVER_NAME.*iHD|iHD.*LIBVA_DRIVER_NAME/s,
	'hardware video decode gets the iHD driver');
like($gpu, qr/startswith\("WEBKIT_"\)/,
	'webkit.env\'s WebKit-only switches are not copied into Chromium');
like($gpu, qr/qt\.env/, 'qt.env is the Qt escape hatch');
like($gpu, qr/--disable-gpu/, 'and JAWNOS_GPU=0 can ask for software rendering');
like($qt, qr/gpu\.prepare_env\(\)/, 'the shell applies it');
my $gpu_at = index($qt, 'gpu.prepare_env()');
my $app_at = index($qt, 'app = QApplication');
ok($gpu_at >= 0 && $app_at > $gpu_at,
	'before QApplication, because Qt WebEngine reads it at init');

# The tray: no browser item, and a badge that carries jawn's state.
unlike($qt, qr/"Open in browser"/, 'the tray menu does not offer a browser');
like($qt, qr/def tray_icon/, 'the tray badge is painted with a state dot');
like($qt, qr/core\.jawn_status\(jawn_up\)/, 'and follows the shared status rule');
like($theme, qr/GREEN = \(0x34, 0xC7, 0x59\)/, 'the green is the dashboard\'s green');
like($theme, qr/AMBER = \(0xFF, 0xB0, 0x20\)/, 'the amber is the same amber');
like($theme, qr/RED = \(0xFF, 0x45, 0x3A\)/, 'and the red is the same red');

like($qt, qr/setDesktopFileName\("jawnos"\)/,
	'the Wayland app id is the desktop entry, not python3');
like($qt, qr/QSystemTrayIcon/, 'the shell keeps a tray');
like($qt, qr/class Supervisor/, 'and supervises jawn');
like($qt, qr/auto_update_available/, 'including the desktop self-update');
like($qt, qr/version_mismatch/, 'and the version restart');
like($qt, qr/permissionRequested/, 'the newer permission signal is handled');
like($qt, qr/PermissionType/, 'through QWebEnginePermission');
like($qt, qr/featurePermissionRequested/, 'with the older signal kept as a fallback');
like($session, qr/--engine webkit/,
	'the Sway session falls back to WebKitGTK if the Qt shell cannot start');
like($qt, qr/from \.qt_panel import ControlPanel/, 'the shell loads the Qt panel');
like($qt, qr/\("Control panel", show_panel\)/, 'the tray opens it');
like($qt, qr/admin_opener\["open"\] = show_panel/, 'and the page admin icon does too');
like($panel, qr/class ControlPanel/, 'the panel is a Qt dialog');
like($panel, qr/theme\.PANEL_CSS/, 'it carries the GTK dashboard\'s look');
like($panel, qr/class StatusDot/, 'with painted status dots, not just coloured text');
like($panel, qr/core\.jawn_status/, 'and the shared starting/running/stopped rule');
like($theme, qr/QFrame#card/, 'the cards are rounded on the black ground');
like($theme, qr/#ffcc00/, 'with the jawn yellow as the primary accent');
like($panel, qr/Import ticket/, 'with the login ticket controls');
like($panel, qr/Start VPN/, 'the tailnet');
like($panel, qr/Start bridge/, 'the BLE bridge');
like($panel, qr/Start the BLE bridge at login/, 'the autostart setting');
like($panel, qr/update_available/, 'and the app update');
unlike($keepawake, qr/import gi|from gi\.repository/, 'the Qt keep-awake does not need PyGObject');
like($keepawake, qr/systemd-inhibit/, 'it uses logind\'s idle inhibitor');

like($qt, qr/def webkit_localstorage/, 'the shell can read the GTK localStorage store');
like($qt, qr/def device_seed_js/, 'and carries the desktop device identity across');
like($qt, qr/__jawn_device_seeded/, 'seeding it once per profile');
like($qt, qr/__jawn_qt_migrated/, 'the migration is marked, so later Qt changes are kept');
like($qt, qr/background_images/, 'the layout family it copies is the one the page reads');
like($qt, qr/window_width/, 'the window geometry is restored from desktop.json');
like($qt, qr/showMaximized/, 'including maximized');
like($qt, qr/core\.save_settings/, 'and saved back on close');

# The reader, against a fixture in WebKit's shape: an ItemTable whose values
# are UTF-16LE blobs, under <base>/<app>/localstorage/https_<host>_<port>.
{
	my $tmp = tempdir(CLEANUP => 1);
	my $dir = "$tmp/base/jawnos-desktop/localstorage";
	make_path($dir);
	my $db = "$dir/https_127.0.0.1_45545.localstorage";
	my $fixture = "$tmp/fixture.py";
	open(my $fh, '>', $fixture) or die "$fixture: $!";
	print {$fh} <<'PYINNER';
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("create table ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB NOT NULL ON CONFLICT FAIL)")
for key, value in (("layout", "desk"), ("background_images", '["one"]'), ("device_uuid", "keep-me"), ("browser_tab", "tab-1")):
    c.execute("insert into ItemTable (key, value) values (?, ?)", (key, value.encode("utf-16-le")))
c.commit()
PYINNER
	close $fh;
	system("python3", $fixture, $db) == 0 or die "fixture failed";
	my $out = `cd "$root" && PYTHONPATH=desktop python3 -c 'import json,sys; from jawnos_desktop.qt_shell import webkit_localstorage; p,d = webkit_localstorage("127.0.0.1", 45545, base=sys.argv[1]); print(json.dumps(d))' "$tmp/base" 2>&1`;
	like($out, qr/"layout": "desk"/, 'the reader returns the GTK layout key');
	like($out, qr/background_images/, 'and the background list');
	like($out, qr/"device_uuid": "keep-me"/, 'and the desktop device identity');
	unlike($out, qr/browser_tab/, 'but not the live tab id');
	my $seed = `cd "$root" && PYTHONPATH=desktop python3 -c 'import sys; from jawnos_desktop.qt_shell import device_seed_js; print(device_seed_js("127.0.0.1", 45545, base=sys.argv[1]))' "$tmp/base" 2>&1`;
	like($seed, qr/__jawn_device_seeded/, 'the seed runs only once');
	like($seed, qr/keep-me/, 'and writes the WebKit device identity');
}

# The real engine, when this machine has it. A machine without the PySide6
# QtWebEngine package skips: the source pins above still run everywhere. The
# probe page is a file:// URL: a data: page is an opaque origin, so the
# QWebChannel transport is absent and bridge/ping would report false.
my $probe_dir = tempdir(CLEANUP => 1);
my $blank = "$probe_dir/blank.html";
open(my $bfh, '>', $blank) or die "$blank: $!";
print {$bfh} "<!doctype html><html><body>probe</body></html>\n";
close $bfh;
my $probe = `cd "$root" && timeout 45 xvfb-run -a env QTWEBENGINE_CHROMIUM_FLAGS='--disable-gpu --no-sandbox' python3 desktop/jawnos-qt --probe --url 'file://$blank' 2>&1`;
SKIP: {
	skip 'the Qt WebEngine package is not installed here', 7
		if $probe =~ /needs PySide6|No module named .PySide6/ || $probe !~ /qt-probe /;
	my ($line) = $probe =~ /^(qt-probe .*)$/m;
	like($line, qr/"rtc":"function"/, 'the real engine has RTCPeerConnection');
	like($line, qr/"offer":"offer"/, 'and it completes an offer on the spot');
	like($line, qr/"bridge":true/, 'the QWebChannel bridge connects');
	like($line, qr/"ping":true/, 'a message round-trips through the bridge');
	like($line, qr/"desktop":true/, 'and the page sees the desktop marker');
	like($line, qr/"gpu":"[^"]+"/,
		'and the probe names the renderer it is using');
	unlike($probe, qr/NameError|Traceback/,
		'a real (origin-checked) action does not crash the handler');
}

# The panel itself, built without a display. It reads the same core as the
# GTK dashboard; the controls are the panel's own.
my $panel_run = `cd "$root" && QT_QPA_PLATFORM=offscreen PYTHONPATH=desktop python3 -c 'from PySide6.QtWidgets import QApplication; from jawnos_desktop.qt_panel import ControlPanel; app=QApplication([]); p=ControlPanel({"jawn_dir":"/tmp","ble_with_jawn":True},{"show_view":lambda:None,"show_log":lambda:None,"restart":lambda:None}); print("panel-ok", p.windowTitle())' 2>&1`;
SKIP: {
	skip 'the PySide6 panel cannot be built here', 1
		if $panel_run =~ /No module named .PySide6|ModuleNotFoundError/;
	like($panel_run, qr/panel-ok JawnOS\n/, 'the panel builds offscreen');
}

# The status rule the panel and the tray share: red when down, amber while a
# start this process asked for is young, green once it answers.
my $states = `cd "$root" && PYTHONPATH=desktop python3 -c 'import time; from jawnos_desktop import core; core.clear_start_requested(); a=core.jawn_status(False); core.mark_start_requested(now=time.monotonic()-5); b=core.jawn_status(False); core.mark_start_requested(now=time.monotonic()-151); c=core.jawn_status(False); print(a, b, c, core.jawn_status(True))' 2>&1`;
like($states, qr/\('not running', 'red'\) \('starting\.\.\. \(\d+s\)', 'amber'\) \('not running', 'red'\) \('running', 'green'\)/,
	'start-up reads red -> amber (with its age) -> green');
like($core, qr/STARTING_WINDOW = 150\.0/, 'the amber window is the dashboard\'s 150 s');
like($core, qr/mark_start_requested\(\)/, 'a start marks the clock');
like($core, qr/def restart_jawn[^\n]*\n(?:.*\n)*?\s+mark_start_requested\(\)/,
	'and a restart marks it before the stop, so it never flashes red');
like($core, qr/clear_start_requested\(\)/, 'a deliberate stop clears it');

# The tray badge: one icon per tone, built and cached, distinct by colour.
my $icons = `cd "$root" && QT_QPA_PLATFORM=offscreen PYTHONPATH=desktop python3 -c 'from PySide6.QtWidgets import QApplication; from jawnos_desktop.qt_shell import tray_icon; from jawnos_desktop import theme; app=QApplication([]); xs=[tray_icon("desktop/icons/jawnos.png", c) for c in (theme.GREEN, theme.AMBER, theme.RED)]; print("icons-ok", len(xs), xs[0] is tray_icon("desktop/icons/jawnos.png", theme.GREEN), all(not x.isNull() for x in xs))' 2>&1`;
SKIP: {
	skip 'PySide6 is not installed here', 1
		if $icons =~ /No module named .PySide6|ModuleNotFoundError/;
	like($icons, qr/^icons-ok 3 True True$/m,
		'the three state badges build and are cached per colour');
}

my $hostkit = `cd "$root" && QT_QPA_PLATFORM=offscreen PYTHONPATH=desktop python3 -c 'from PySide6.QtCore import QUrl; from jawnos_desktop.qt_shell import _qurl_host; print(_qurl_host(QUrl("https://Example.COM:45545/x")), _qurl_host(QUrl("https://[::1]:1/")))' 2>&1`;
SKIP: {
	skip 'PySide6 is not installed here', 1
		if $hostkit =~ /No module named .PySide6|ModuleNotFoundError/;
	like($hostkit, qr/^example\.com ::1$/m,
		'the QUrl host is lower-cased and IPv6 brackets are stripped');
}

# The graphics environment: a WebKit-only switch is not copied into Chromium,
# qt.env wins over it, and the real environment always wins over both.
{
	my $tmp = tempdir(CLEANUP => 1);
	write_file("$tmp/webkit.env", "WEBKIT_DMABUF_RENDERER_FORCE_SHM=1\nLIBVA_DRIVER_NAME=i965\n");
	write_file("$tmp/qt.env", "QTWEBENGINE_CHROMIUM_FLAGS=--from-qt-env\n");
	my $out = `cd "$root" && PYTHONPATH=desktop python3 -c 'import json; from jawnos_desktop import gpu; e={"QTWEBENGINE_CHROMIUM_FLAGS":"--from-real"}; a=gpu.prepare_env(e, config_dir="$tmp"); print(json.dumps([a, e]))' 2>&1`;
	like($out, qr/"--from-real --ignore-gpu-blocklist --enable-gpu-rasterization"/,
		'the real flags are kept and the GPU flags appended');
	like($out, qr/"LIBVA_DRIVER_NAME": "i965"/,
		'webkit.env\'s non-WebKit keys still reach Chromium');
	unlike($out, qr/WEBKIT_DMABUF_RENDERER_FORCE_SHM|--from-qt-env/,
		'but WebKit-only switches and a shadowed qt.env value do not');
}

done_testing();
