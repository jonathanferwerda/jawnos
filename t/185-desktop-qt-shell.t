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
