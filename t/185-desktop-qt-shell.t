# tests-for: desktop/jawnos_desktop/qt_shell.py desktop/jawnos-desktop desktop/jawnos-qt
# covers:    the Qt WebEngine desktop shell behind a flag: the same Manager page
#           in Chromium, which is the engine with WebRTC (Debian's WebKitGTK is
#           built without RTCPeerConnection), the ticket cookie kept on disk,
#           microphone/camera grants, and the house's own certificate accepted.

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
my $entry = read_file("$root/desktop/jawnos-desktop");
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
like($qt, qr/def manager_url/, 'and derives the manager URL from it');

like($entry, qr/JAWNOS_DESKTOP_ENGINE/, 'the engine can be chosen by environment');
like($entry, qr/--engine/, 'and by flag');
like($entry, qr/from jawnos_desktop\.ui import main/, 'WebKitGTK stays the default');
like($entry, qr/from jawnos_desktop\.qt_shell import main/, 'Qt is the opt-in branch');
ok(-x $launcher, 'jawnos-qt is directly runnable');

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
# QtWebEngine package skips: the source pins above still run everywhere.
my $probe = `cd "$root" && timeout 45 xvfb-run -a env QTWEBENGINE_CHROMIUM_FLAGS='--disable-gpu --no-sandbox' python3 desktop/jawnos-qt --probe --url 'data:text/html,<html></html>' 2>&1`;
SKIP: {
	skip 'the Qt WebEngine package is not installed here', 2
		if $probe =~ /needs PySide6|No module named .PySide6/ || $probe !~ /qt-probe /;
	my ($line) = $probe =~ /^(qt-probe .*)$/m;
	like($line, qr/"rtc":"function"/, 'the real engine has RTCPeerConnection');
	like($line, qr/"offer":"offer"/, 'and it completes an offer on the spot');
}

done_testing();
