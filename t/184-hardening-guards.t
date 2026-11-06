# tests-for: lib/JawnOS/Domain/Format.pm lib/JawnOS/Domain/Crypt.pm lib/JawnOS/Domain/Sent.pm lib/JawnOS/Manager/Part04.pm lib/JawnOS/Manager/Part05.pm lib/JawnOS/Manager/Part13.pm lib/JawnOS/Manager/Part17.pm lib/JawnOS/Controller/manager_configure.pm lib/JawnOS/Controller/manager_configure3.pm lib/JawnOS/Controller/manager_configure4.pm lib/JawnOS/Controller/manager_configure5.pm lib/JawnOS/Controller/manager_embedded.pm lib/JawnOS/Controller/manager_misc.pm lib/JawnOS/Controller/manager_misc5.pm lib/JawnOS/Controller/manager_misc6.pm lib/JawnOS/Controller/manager_misc12.pm lib/JawnOS/Controller/manager_misc14.pm lib/JawnOS/Controller/manager_mail.pm lib/JawnOS/Controller/mail_ws.pm qa/coding_night/run.pl qa/systemd/jawnos-qa-coding.service desktop/install-wallet.sh jp/alarmclock/alarmclock_02_ble_handlers_wifi_setup.ino jp/alarmclock/alarmclock_03_loop_house_inputs_jobs.ino jt/jt_01_globals_ble_house.ino jt/jt_02_lorawan_radio_gps.ino jt/jt_03_setup.ino jw/jw_01_globals.ino jw/jw_03_setup.ino public/js/manager/embedded/01_ota_nowme.js templates/embedded/body.html.ep
# covers:    The second audit pass: file reads stay inside a root, peer proof is
#           signed, the console channel escapes its data, and OTA needs a token.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use Cwd qw(abs_path);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Slurp qw(write_file read_file);
use JawnOSTest;

my $root = abs_path("$FindBin::Bin/..");

sub source {
	my ($rel) = @_;
	open(my $fh, '<', "$root/$rel") or die "open $rel: $!";
	local $/;
	my $text = <$fh>;
	close $fh;
	return $text;
}

# --- path containment -------------------------------------------------------
my $dir = tempdir(CLEANUP => 1);
make_path("$dir/in", "$dir/out");
write_file("$dir/in/x", 'x');
write_file("$dir/out/y", 'y');
symlink("$dir/out", "$dir/in/link") or die "symlink: $!";

ok(subs::path_is_within("$dir/in/x", "$dir/in"), 'a file inside the root is accepted');
ok(!subs::path_is_within("$dir/out/y", "$dir/in"), 'a sibling is refused');
ok(!subs::path_is_within("$dir/in/link/y", "$dir/in"), 'a symlink out of the root is refused');
ok(!subs::path_is_within("$dir/in/missing", "$dir/in"), 'a missing path is refused');

# --- peer proof -------------------------------------------------------------
{
	package FakeHeaders;
	sub new { bless {}, shift }
	sub header { undef }

	package FakeReq;
	sub new { bless {}, shift }
	sub headers { FakeHeaders->new }
	sub method { 'GET' }
	sub url { Mojo::URL->new('/manager/x') }

	package FakeC;
	sub new { bless {}, shift }
	sub req { FakeReq->new }
	sub stash { undef }

	package main;
}

my $rm = { signatorial => 'sig', uuid => 'row' };
is(subs::peer_verify(FakeC->new, $rm), 0,
	'an unsigned request is refused even while the row has no pubkey');

# --- the call sites keep the safe shape -------------------------------------
my $part04 = source('lib/JawnOS/Manager/Part04.pm');
like($part04, qr/path_is_within\(\$file/, '/file_open as_is confines the path to a root');

my $conf5 = source('lib/JawnOS/Controller/manager_configure5.pm');
my $guards = () = $conf5 =~ /path_is_within/g;
cmp_ok($guards, '>=', 3, 'restore, merge and delete each validate the backup path');
like($conf5, qr/`tail ` \. quote\(\$path\)/, 'the restore tail quotes its path');
unlike($conf5, qr/`tail \$path`/, 'no raw restore path reaches the shell');

my $conf = source('lib/JawnOS/Controller/manager_configure.pm');
like($conf, qr/path_name\(\$upload->\{'filename'\}\)/, 'an upload name is one filesystem component');
like($conf, qr/system\('ffmpeg'/, 'the video converter runs ffmpeg in list form');

my $crypt = source('lib/JawnOS/Domain/Crypt.pm');
unlike($crypt, qr/return \(\$stored \? 0 : 1\)/, 'peer_verify has no unsigned first-contact branch');

my $embedded = source('lib/JawnOS/Controller/manager_embedded.pm');
like($embedded, qr{/update\?authorization=}, 'the ESP32 OTA sends its token');
like($embedded, qr/authorization => \$auth/, 'the ESP32 OTA sends the token as a header');

my $sent = source('lib/JawnOS/Domain/Sent.pm');
like($sent, qr/html_text\(\$text\)/, 'streamed assistant text is HTML-escaped');
like($sent, qr/console_command\('setHtml', \$data->\{'uuid'\}, \$response_text\)/, 'and travels as a command argument, not JS source');

my $misc14 = source('lib/JawnOS/Controller/manager_misc14.pm');
like($misc14, qr/html_text\(\$transcription\)/, 'a transcription is HTML-escaped before .html()');

my $night = source('qa/coding_night/run.pl');
like($night, qr/JAWNOS_QA_AUTO_MERGE/, 'the nightly lands on main only when opted in');

my $wallet = source('desktop/install-wallet.sh');
like($wallet, qr/refusing to install/, 'a missing wallet checksum is a hard failure');

my $jt = source('jt/jt_02_lorawan_radio_gps.ino') . source('jt/jt_03_setup.ino');
like($jt, qr/ota_refused = true/, 'the ESP32 OTA refuses an unauthorized upload');
like($jt, qr/collectHeaders\(jawn_ota_headers, 1\)/, 'and collects the authorization header');

my $jw = source('jw/jw_03_setup.ino');
like($jw, qr/ota_refused = true/, 'the second ESP32 sketch refuses an unauthorized upload');

my $jp = source('jp/alarmclock/alarmclock_03_loop_house_inputs_jobs.ino')
	. source('jp/alarmclock/alarmclock_02_ble_handlers_wifi_setup.ino');
like($jp, qr/authorization\.length\(\) > 0 && rauth == authorization/,
	'the Pico OTA needs a non-empty token');
like($jp, qr/server\.on\("\/led", \[\]\(\) \{\n    homebaseChecked\(\);\n    String rauth/,
	'the Pico LED route checks the token');

my $ota_js = source('public/js/manager/embedded/01_ota_nowme.js');
like($ota_js, qr/data\.append\('chip_id', chip_id\)/, 'the OTA form carries the board chip id');

my $body = source('templates/embedded/body.html.ep');
like($body, qr/id="embedded_ota_uploader_wifi".*chip_id=/, 'the OTA button carries the chip id');

done_testing();
