# tests-for: desktop/jawnos_desktop/qt_shell.py desktop/jawnos_desktop/bridge.py desktop/jawnos-desktop desktop/jawnos-qt desktop/wayland/jawnos-session
# covers:    the Qt WebEngine desktop shell is the default: the same Manager page
#           in Chromium, which is the engine with WebRTC (Debian's WebKitGTK is
#           built without RTCPeerConnection), the ticket cookie kept on disk,
#           microphone/camera grants, the house's own certificate accepted, the
#           page bridge, supervision, and the WebKitGTK fallback.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Slurp qw(read_file);

my $root = "$FindBin::Bin/..";
my $qt = read_file("$root/desktop/jawnos_desktop/qt_shell.py");
my $bridge = read_file("$root/desktop/jawnos_desktop/bridge.py");
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

like($qt, qr/def webkit_localstorage/, 'the shell can read the GTK localStorage store');
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
for key, value in (("layout", "desk"), ("background_images", '["one"]'), ("device_uuid", "not-a-preference")):
    c.execute("insert into ItemTable (key, value) values (?, ?)", (key, value.encode("utf-16-le")))
c.commit()
PYINNER
	close $fh;
	system("python3", $fixture, $db) == 0 or die "fixture failed";
	my $out = `cd "$root" && PYTHONPATH=desktop python3 -c 'import json,sys; from jawnos_desktop.qt_shell import webkit_localstorage; p,d = webkit_localstorage("127.0.0.1", 45545, base=sys.argv[1]); print(json.dumps(d))' "$tmp/base" 2>&1`;
	like($out, qr/"layout": "desk"/, 'the reader returns the GTK layout key');
	like($out, qr/background_images/, 'and the background list');
	unlike($out, qr/device_uuid/, 'but not the padlock device identity');
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
	skip 'the Qt WebEngine package is not installed here', 5
		if $probe =~ /needs PySide6|No module named .PySide6/ || $probe !~ /qt-probe /;
	my ($line) = $probe =~ /^(qt-probe .*)$/m;
	like($line, qr/"rtc":"function"/, 'the real engine has RTCPeerConnection');
	like($line, qr/"offer":"offer"/, 'and it completes an offer on the spot');
	like($line, qr/"bridge":true/, 'the QWebChannel bridge connects');
	like($line, qr/"ping":true/, 'a message round-trips through the bridge');
	like($line, qr/"desktop":true/, 'and the page sees the desktop marker');
}

done_testing();
