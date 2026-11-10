# tests-for: lib/JawnOS/Domain/Format.pm lib/JawnOS/Domain/Crypto.pm lib/JawnOS/Domain/Crypt.pm lib/JawnOS/Domain/Sent.pm lib/JawnOS/Manager/Part04.pm lib/JawnOS/Manager/Part05.pm lib/JawnOS/Manager/Part13.pm lib/JawnOS/Manager/Part17.pm lib/JawnOS/Controller/manager_configure.pm lib/JawnOS/Controller/manager_configure3.pm lib/JawnOS/Controller/manager_configure4.pm lib/JawnOS/Controller/manager_configure5.pm lib/JawnOS/Controller/manager_embedded.pm lib/JawnOS/Controller/manager_misc.pm lib/JawnOS/Controller/manager_misc5.pm lib/JawnOS/Controller/manager_misc6.pm lib/JawnOS/Controller/manager_misc12.pm lib/JawnOS/Controller/manager_misc14.pm lib/JawnOS/Controller/manager_mail.pm lib/JawnOS/Controller/mail_ws.pm qa/coding_night/run.pl qa/systemd/jawnos-qa-coding.service desktop/install-wallet.sh jp/alarmclock/alarmclock_02_ble_handlers_wifi_setup.ino jp/alarmclock/alarmclock_03_loop_house_inputs_jobs.ino jt/jt_01_globals_ble_house.ino jt/jt_02_lorawan_radio_gps.ino jt/jt_03_setup.ino jw/jw_01_globals.ino jw/jw_03_setup.ino public/js/manager/embedded/01_ota_nowme.js templates/embedded/body.html.ep lib/JawnOS/Controller/manager_mail2.pm lib/JawnOS/Controller/manager_misc2.pm lib/JawnOS/Controller/manager_misc7.pm lib/JawnOS/Controller/manager_misc9.pm lib/JawnOS/Controller/manager_misc10.pm lib/JawnOS/Controller/manager_misc13.pm lib/JawnOS/Controller/sesh_check.pm lib/JawnOS/Domain/Generate.pm lib/JawnOS/Domain/Weather.pm lib/JawnOS/Manager/Part30.pm lib/JawnOS/Manager/Part32.pm
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

# The exchange-rate fetch talks to two public hosts with real certificates, so
# turning verification off there bought nothing and hid a tampered rate.
my $crypto = source('lib/JawnOS/Domain/Crypto.pm');
my ($rates_sub) = $crypto =~ /(sub crypto_rates_refresh \{.*?\n\}\n)/s;
like($rates_sub, qr{https://api\.coinbase\.com}, 'the rates come from Coinbase over TLS');
unlike($rates_sub, qr/insecure/, 'and that fetch verifies the certificate');

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

# --- the second audit pass: request text and data never reach a shell -------
my $conf5_qr = source('lib/JawnOS/Controller/manager_configure5.pm');
like($conf5_qr, qr/&quote\(\$pos\)/, 'the environment QR quotes the position it is given');
unlike($conf5_qr, qr/`qrencode -o - \$pos`/, 'no raw position reaches qrencode');

my $misc5 = source('lib/JawnOS/Controller/manager_misc5.pm');
like($misc5, qr/&subs::path_name\(\$upload->\{'filename'\}\)/, 'an uploaded name is one filesystem component');
like($misc5, qr/system\('mkdir', '-p', \$location\)/, 'the upload folder is made in list form');
like($misc5, qr/`file ` \. &quote\(\$filename\)/, 'the file probe quotes its path');
like($misc5, qr/system\('shred', '-u', \$tn_o\)/, 'shred runs in list form');
unlike($misc5, qr/`file \$filename`/, 'no raw upload path reaches the shell');

my $misc7 = source('lib/JawnOS/Controller/manager_misc7.pm');
like($misc7, qr/my \$cp = 'cp -v ' \. &quote\(\$f\)/, 'a copy builds its command with quoted paths');
like($misc7, qr/my \$mv = 'mv -v ' \. &quote\(\$file\)/, 'a move builds its command with quoted paths');
like($misc7, qr/system\('shred', '-u', \$thumb\)/, 'a thumbnail shred runs in list form');
unlike($misc7, qr/`cp -v \$f \$nf`/, 'no raw copy path reaches the shell');

my $generated = source('lib/JawnOS/Domain/Generate.pm');
like($generated, qr/File::Path::make_path\(\$public_dir\)/, 'the media folder is made in Perl');
like($generated, qr/&quote\(\$file_path\)/, 'the media pipeline quotes its paths');
unlike($generated, qr/`mkdir \$public_dir`/, 'no raw media folder reaches the shell');

my $mail2 = source('lib/JawnOS/Controller/manager_mail2.pm');
like($mail2, qr/&quote\(\$qr\)/, 'the mail QR quotes its payload');
unlike($mail2, qr/`qrencode -o - \$qr`/, 'no raw QR payload reaches the shell');

# A pinned key proves the machine; the grant says what it may ask for.
like(source('lib/JawnOS/Controller/manager_misc10.pm'), qr/peer_allows\(\$c, \$rm, 'command'\)/,
	'remote_command needs the command grant, not just a pinned key');

my $backup = source('lib/JawnOS/Controller/manager_misc2.pm');
like($backup, qr/path_is_within\(\$path, \$_/, 'backup_serve confines the requested archive');
like($backup, qr/backups_dir\(\)/, 'and names the backup directory as a root');

like(source('lib/JawnOS/Controller/manager_misc13.pm'), qr/path_name\(\$key/,
	'the keyboard alias becomes a filesystem-safe name');

like(source('lib/JawnOS/Controller/manager_misc9.pm'), qr/html_text\(\$file->\{'ocr'\}\)/,
	'OCR text is escaped before the template prints it raw');

my $weather = source('lib/JawnOS/Domain/Weather.pm');
my ($wrev) = $weather =~ /(sub weather_reverse_geocode \{.*?\n\})/s;
my ($wfetch) = $weather =~ /(sub weather_fetch \{.*?\n\})/s;
unlike($wrev, qr/insecure/, 'the reverse geocode verifies the public certificate');
unlike($wfetch, qr/insecure/, 'the weather fetch verifies the public certificate');

my $sesh = source('lib/JawnOS/Controller/sesh_check.pm');
like($sesh, qr/samesite\('Lax'\)/, 'the session cookie is SameSite Lax');
unlike($sesh, qr/samesite\(undef\)/, 'no login removes the SameSite attribute');

my $part30 = source('lib/JawnOS/Manager/Part30.pm');
like($part30, qr/return 0 unless length \$ssig/, 'a peer session needs a proved name');
unlike($part30, qr/return 1 if \$ssig eq ''/, 'a nameless session is no longer a peer');

like(source('lib/JawnOS/Manager/Part04.pm'), qr{=\~ /\\Q\$file\\E/},
	'the public magazine matches the request path literally');

my $part32 = source('lib/JawnOS/Manager/Part32.pm');
ok(index($part32, 'next if $pre_number =~ /[^0-9.+-]/;') >= 0,
	'the quantity substituted into a measure formula is numeric-only');
ok(index($part32, 'request text is data, not source') >= 0,
	'the arithmetic eval is guarded');
like(source('qa/security/allowlist.json'), qr/restricted to digits/,
	'the allowlist records why the calculator eval remains');

done_testing();
