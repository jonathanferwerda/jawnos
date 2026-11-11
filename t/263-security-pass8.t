# tests-for: lib/JawnOS/Domain/Records2.pm lib/JawnOS/Domain/Misc.pm lib/JawnOS/Domain/Coding.pm lib/JawnOS/Manager/Part29.pm lib/JawnOS/Domain/Sent.pm lib/JawnOS/Domain/Generate.pm lib/JawnOS/Controller/mail_ws.pm lib/JawnOS/Domain/Evaluation.pm lib/JawnOS/Controller/manager_watch.pm lib/JawnOS/Controller/manager_misc8.pm perl/hooks.pl lib/JawnOS/Manager/Part35.pm lib/JawnOS/Domain/Archive.pm lib/JawnOS/Controller/manager_folders2.pm lib/JawnOS/Controller/manager_configure5.pm lib/JawnOS/Manager/Part08.pm lib/JawnOS/Controller/manager_misc10.pm lib/JawnOS/Domain/Records.pm lib/JawnOS/Controller/manager_misc9.pm jp/alarmclock/alarmclock_02_ble_handlers_wifi_setup.ino jt/jt_03_setup.ino jw/jw_03_setup.ino jw/jw_01_globals.ino lib/JawnOS/Domain/Ble.pm lib/JawnOS/Domain/Ble2.pm lib/JawnOS/Domain/Embedded2.pm
# covers:    The eighth audit pass: a proposal is never compiled, an agent path
#           cannot carry shell syntax, a child cannot run a shipping script,
#           a restore proves its snapshot and its machine, a synced tarball
#           holds no links, the IDE never writes through one, and a reflected
#           read is text, not a page.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

sub source { return read_file(root() . '/' . $_[0]) }

# --- a proposed file is checked, never compiled -----------------------------
my $records2 = source('lib/JawnOS/Domain/Records2.pm');
like($records2, qr/return '' if \$ext =~ \/\^\(\?:pl\|pm\|t\)\$\/;/,
	'a proposed Perl file is not compiled');
like($records2, qr/\\\$;\(\)\{\}\|&<>/, 'an agent path may not carry shell syntax');
like($records2, qr/jawnos\\\.db/, 'and the database is not an agent path');
like($records2, qr/\.env/, 'and neither is an env file');
like(source('lib/JawnOS/Domain/Misc.pm'), qr/jawnos\\\.db/,
	'the coding path has the same deny list');

# --- a child cannot run a shipping script, however it is spelled ------------
my $coding = source('lib/JawnOS/Domain/Coding.pm');
like($coding, qr/for my \$word \(split \/\\s\+\/, \$c\) \{/,
	'a child judges each word of a run command');
like($coding, qr/land_enqueue\|land_promote\|agent_land/,
	'and refuses the shipping and landing tools');

# --- the run verb and the learned verbs keep their authority ----------------
my $part29 = source('lib/JawnOS/Manager/Part29.pm');
like($part29, qr/refused: --output writes a file/, 'git --output is refused');
like($part29, qr/only git remote -v is read-only/, 'git remote is read-only in its -v form');
like($part29, qr/next if \$prim eq 'run_command' && \$k eq 'command';/,
	'a learned run_command keeps its configured command');
like($part29, qr/next if \$prim eq 'set_setting' && \(\$k eq 'app' \|\| \$k eq 'setting'\);/,
	'and a learned set_setting keeps its app and setting');

# --- an answer is escaped before it becomes HTML ----------------------------
my $sent = source('lib/JawnOS/Domain/Sent.pm');
like($sent, qr/unless \(\$data->\{'type'\} eq 'assistant'\) \{\n\s+# The reply is HTML.*\n\s+\$text = &subs::html_text\(\$text\);/s,
	'a Pen reply is escaped before its <br>s');

# --- logs name the work, not the payload ------------------------------------
unlike(source('lib/JawnOS/Domain/Generate.pm'), qr/\$log->info\(Dumper/,
	'generate does not dump its data');
unlike(source('lib/JawnOS/Controller/mail_ws.pm'), qr/\$log->info\(Dumper/,
	'and neither does the mail reply');

# --- a model URL is resolved before it is fetched ---------------------------
my $eval = source('lib/JawnOS/Domain/Evaluation.pm');
like($eval, qr/Socket::getaddrinfo/, 'a media host is resolved');
like($eval, qr/return 0 if \$private->\(\$ip\);/, 'and a private answer refuses it');
like($eval, qr/unless \$ai_media_url_ok->\(\$video_uri\)/, 'the video URL gets the same check');

# --- a reflected read is text, not a page -----------------------------------
like(source('lib/JawnOS/Controller/manager_watch.pm'),
	qr/content_type\('text\/plain'\).*render\(text => \$c->param\('uuid'\)/s,
	'the watch id is echoed as text');
like(source('lib/JawnOS/Controller/manager_misc8.pm'),
	qr/content_type\('text\/plain'\).*render\(text => \$clipboard\)/s,
	'and so is the clipboard');
like(source('perl/hooks.pl'), qr{/manager/budget}, 'the budget GET mutation is CSRF-checked');
like(source('lib/JawnOS/Manager/Part35.pm'), qr/header\('X-Forwarded-For'\)/,
	'a forwarded request is not the loopback health caller');

# --- filesystem and restore -------------------------------------------------
my $conf5 = source('lib/JawnOS/Controller/manager_configure5.pm');
like($conf5, qr/pragma integrity_check/, 'a restore proves the snapshot is a database');
like($conf5, qr/that backup belongs to another machine/, 'and refuses another machine snapshot');
like($conf5, qr/chmod 0600, \$database;/, 'the scratch database is private');
like($conf5, qr/system\('shred', '-u', \$database \. '\.1\.db'\)/, 'and its copy is shredded');

my $part08 = source('lib/JawnOS/Manager/Part08.pm');
like($part08, qr/tar tvzf/, 'a synced tarball has its member types checked');
like($part08, qr/return 0 unless \$line =~ \/\^\[-d\]\//, 'and links are refused');

my $ide = source('lib/JawnOS/Controller/manager_misc10.pm');
like($ide, qr/Fcntl::O_NOFOLLOW\(\)/, 'the IDE never writes through a symlink');
like(source('lib/JawnOS/Domain/Records.pm'), qr/system\('shred', '-u', \$tmp\)/,
	'a plaintext snapshot is shredded');
like(source('lib/JawnOS/Controller/manager_misc9.pm'),
	qr/path_is_under\(\$folder, &subs::home\('~'\), '\/sdcard', '\/storage'\)/,
	'the folder browser stays in the house');

# --- a cloud base is a normal folder ----------------------------------------
my $hidden = subs::cloud_sync_destination({ base => '~/.secrets', path => '' });
like($hidden->{'error'}, qr/hidden folder/, 'a hidden cloud base is refused');
my $fine = subs::cloud_sync_destination({ base => 'jawnos-sync', path => 'photos/a.jpg' });
is($fine->{'relative'}, 'photos/a.jpg', 'a normal cloud base still works');


# --- firmware: the pairing token is not a diagnostic, and is required ------
my $jp = source('jp/alarmclock/alarmclock_02_ble_handlers_wifi_setup.ino');
like($jp, qr/jonfig\["authorization"\] = undefined;/, 'device_query never echoes the token');
like($jp, qr/server\.on\("\/now_me".*?authorization\.length\(\) > 0 && rauth != authorization/s,
	'the Pico now_me asks for the stored token');
my $jt = source('jt/jt_03_setup.ino');
like($jt, qr/server\.on\("\/now_me".*?authorization\.length\(\) > 0 && rauth != authorization/s,
	'the deck now_me asks for the stored token');
my $jw = source('jw/jw_03_setup.ino');
like($jw, qr/server\.on\("\/now_me".*?authorization\.length\(\) > 0 && rauth != authorization/s,
	'the watch now_me asks for the stored token');
like($jw, qr/if \(authorization\.length\(\) > 0 && rauth == authorization\) \{/,
	'an empty token is never a delete match');
like($jw, qr/if \(!\(authorization\.length\(\) > 0 && rauth == authorization\)\) \{/,
	'nor a file-read match');
like(source('jw/jw_01_globals.ino'), qr/String ap_password = "president";/,
	'the watch access point is not open by default');

# --- BLE: the chip must match its radio, and the URL must be the house -----
my $ble = source('lib/JawnOS/Domain/Ble.pm');
ok(index($ble, "return undef unless ((\$c->{'id'} || '') eq \$chip_id);") >= 0,
	'a chip is bound to the radio it first spoke on');
my $ble2 = source('lib/JawnOS/Domain/Ble2.pm');
like($ble2, qr/refused a non-house URL/, 'a BLE frame URL is not a blind fetch');
ok(index(source('lib/JawnOS/Domain/Embedded2.pm'),
	"my \$ping = 'timeout .2 ping -c 1 ' . &subs::shell_quote(\$watch->{'ip'});") >= 0,
	'the watch ping address is one shell word');

done_testing();

