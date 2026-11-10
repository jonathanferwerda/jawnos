# tests-for: lib/JawnOS/Manager/Part01.pm lib/JawnOS/Manager/Part02.pm lib/JawnOS/Manager/Part04.pm lib/JawnOS/Manager/Part12.pm lib/JawnOS/Domain/Notify.pm lib/JawnOS/Domain/Records2.pm lib/JawnOS/Domain/Records.pm lib/JawnOS/Domain/Crypt.pm lib/JawnOS/Domain/Sent.pm lib/JawnOS/Domain/People.pm lib/JawnOS/Domain/Run.pm lib/JawnOS/Domain/Embedded.pm lib/JawnOS/Controller/manager_misc3.pm lib/JawnOS/Controller/manager_embedded.pm scripts/security_audit.pl
# covers:    The fourth audit pass: a request timestamp is a number before it
#           reaches a capture filename, a run command loses every shell
#           metacharacter, the QR encodes the URL it was given, and the shells
#           that remain take their words as a list.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

require(root() . '/lib/JawnOS/Manager/Part01.pm');
require(root() . '/lib/JawnOS/Manager/Part12.pm');
require(root() . '/lib/JawnOS/Domain/Records2.pm');

sub source {
	my ($rel) = @_;
	return read_file(root() . '/' . $rel);
}

# --- the timestamp is a number ----------------------------------------------
{
	package FakeC;
	sub new { my ($class, $p) = @_; return bless { p => $p || {} }, $class }
	sub param { my ($s, $k) = @_; return $s->{p}->{$k} }
	package main;
}

for my $bad ( '$(id)', '`id`', '1234; id', '../x', "1234\n5" ) {
	my $c = FakeC->new({ timestamp => $bad });
	my $got = Manager::timestamp_adjuster($c);
	like($got, qr/\A\d{1,16}\z/, "a timestamp of '$bad' becomes a number");
	unlike($got, qr/\Q$bad\E/, "and keeps none of its text");
}

my $good = FakeC->new({ timestamp => '1791953166531' });
is(Manager::timestamp_adjuster($good), '1791953166531', 'a real epoch-millisecond stamp is unchanged');

# --- the run verb loses every shell metacharacter ---------------------------
for my $cmd (
	'perl scripts/x $(id)', 'perl scripts/x `id`', 'git log; rm -rf /',
	'prove t/ "quoted"', 'git log > /tmp/x', 'perl scripts/x [a]',
) {
	my $out = subs::coding_propose_execute({ action => 'run', command => $cmd }, {});
	like($out, qr/^refused:/, "run command '$cmd' is refused");
}

# --- the QR encodes the URL it was given ------------------------------------
is(Manager::qrencode_png(''), '', 'an empty URL makes no QR');
is(Manager::qrencode_png(undef), '', 'an absent URL makes no QR');
my $have_qrencode = grep { -x "$_/qrencode" } split /:/, ($ENV{'PATH'} // '');
SKIP: {
	skip 'qrencode is not installed', 1 unless $have_qrencode;
	my $png = Manager::qrencode_png('https://127.0.0.1/box_office/x?s=secret');
	is(substr($png, 0, 4), "\x89PNG", 'a URL becomes a PNG');
}

# --- the shells still here take their words as a list ------------------------
my $part01 = source('lib/JawnOS/Manager/Part01.pm');
like($part01, qr/\$timestamp =~ \/\\A\\d\{1,16\}\\z\//, 'the capture timestamp is validated');
like($part01, qr/system\('ffmpeg', '-nostdin', '-i', '\/dev\/video0', \$filename\)/,
	'the webcam capture runs in list form');
like($part01, qr/system\('mkdir', '-p', \$filename\)/, 'the capture folder is made in list form');
like($part01, qr/system\('rec', \$filename\)/, 'the microphone capture runs in list form');
unlike($part01, qr/`ffmpeg [^`]*\$filename/, 'no raw capture path reaches a shell');
unlike($part01, qr/`rec \$filename`/, 'no raw recording path reaches a shell');

my $part02 = source('lib/JawnOS/Manager/Part02.pm');
like($part02, qr/system\('ffmpeg', '-nostdin', '-i', '\/dev\/video0', \$filename\)/,
	'the camera bridge runs ffmpeg in list form');
like($part02, qr/system\('play', \$file\)/, 'the audio player runs in list form');

my $part04 = source('lib/JawnOS/Manager/Part04.pm');
like($part04, qr/'magick ' \. &quote\(\$file \. '\[0\]'\)/, 'the thumbnail convert quotes its path');
unlike($part04, qr/'magick "' \. \$file/, 'no raw path is embedded in a double-quoted command');

my $part12 = source('lib/JawnOS/Manager/Part12.pm');
like($part12, qr/&qrencode_png\(\$url\)/, 'the ticket QR asks the helper');
ok(index($part12, "open(my \$fh, '-|', 'qrencode', '-o', '-', \$url)") >= 0, 'the QR helper passes the URL as one argv word');
like($part12, qr/system\('magick', \$file, '-resize'/, 'the avatar thumbnail runs magick in list form');
unlike($part12, qr/qx\/qrencode/, 'no shell report string survives');

my $notify = source('lib/JawnOS/Domain/Notify.pm');
like($notify, qr/my \@am = \('am', 'broadcast'/, 'the notification broadcast runs in list form');
like($notify, qr/system\(\@argv\) if \@argv/, 'the notification sound passes argv');
unlike($notify, qr/`am broadcast/, 'no notification text reaches a shell');

my $sent = source('lib/JawnOS/Domain/Sent.pm');
like($sent, qr/system\('weasyprint', \$page, \$loc\)/, 'the paper draw runs in list form');
like($sent, qr/system\('mkdir', '-p', \$destination\)/, 'the attachment folder is made in list form');
like($sent, qr/system\('shred', '-u', \$loc\)/, 'the attachment scratch is shredded in list form');

my $crypt = source('lib/JawnOS/Domain/Crypt.pm');
like($crypt, qr/&quote\(\$key_file\)/, 'peer verification quotes its key path');
like($crypt, qr/&quote\(\$key\)/, 'peer signing quotes its private key path');

like(source('lib/JawnOS/Domain/People.pm'), qr/&quote\(\$key_file\)/,
	'the device signature check quotes its paths');

my $run = source('lib/JawnOS/Domain/Run.pm');
like($run, qr/\$branch = 'main' unless \$branch =~ \/\\A\[A-Za-z0-9\]/, 'a branch name is a ref, not a shell word');
like($run, qr/system\('cd ' \. &quote\(\$repo\)/, 'the ancestry probe quotes its paths');

my $embedded = source('lib/JawnOS/Domain/Embedded.pm');
like($embedded, qr/opendir\(my \$dh, \$directory\)/, 'the backup list is read in Perl');
unlike($embedded, qr/`ls -t \$directory`/, 'no raw directory reaches ls');

like(source('lib/JawnOS/Controller/manager_misc3.pm'), qr/&quote\(\$base\)/,
	'the code bundle quotes its base hash');
like(source('lib/JawnOS/Controller/manager_embedded.pm'), qr/'nohup sh -c ' \. &quote\(\$command\)/,
	'the USB upload quotes the command it wraps');

like(source('scripts/security_audit.pl'), qr/perl\.shell\.double_quoted/,
	'the audit names a double-quoted system string');

done_testing();
