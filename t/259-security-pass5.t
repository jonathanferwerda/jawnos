# tests-for: lib/JawnOS/Controller/manager_ws.pm lib/JawnOS/Controller/manager_misc10.pm lib/JawnOS/Controller/manager_misc13.pm lib/JawnOS/Controller/manager_misc9.pm lib/JawnOS/Controller/manager_misc11.pm lib/JawnOS/Controller/manager_misc14.pm lib/JawnOS/Controller/sesh_check.pm lib/JawnOS/Controller/manager_configure2.pm lib/JawnOS/Domain/Render.pm lib/JawnOS/Domain/Format.pm lib/JawnOS/Domain/House.pm lib/JawnOS/Domain/People.pm lib/JawnOS/Domain/Archive.pm lib/JawnOS/Domain/Evaluation.pm lib/JawnOS/Domain/Ble.pm lib/JawnOS/Manager/Part12.pm lib/JawnOS/Manager/Part22.pm lib/JawnOS/Manager/Part24.pm lib/JawnOS/Manager/Part29.pm lib/JawnOS/Manager/Part08.pm lib/JawnOS/Manager/Part35.pm scripts/security_audit.pl templates/mail/email.html.ep templates/mail/message.html.ep templates/apps/video/markup.html.ep public/js/manager/manager/07_timeshift.js
# covers:    The fifth audit pass: a guest socket has no pty, the IDE and file
#           routes stay inside the house, a leading & is not Perl, the browser
#           origin has no raw remote HTML, and a pinned key is not a grant.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file write_file);
use JawnOSTest;
require(root() . '/lib/JawnOS/Manager/Part29.pm');

sub source { return read_file(root() . '/' . $_[0]) }

# --- containment helpers ----------------------------------------------------
ok( subs::path_is_under('/home/jawn/jawnos/x', '/home/jawn'), 'a child of the root is under it');
ok( subs::path_is_under('/home/jawn', '/home/jawn/'), 'the root itself, with a trailing slash, is under it');
ok(!subs::path_is_under('/home/jawn/../etc/x', '/home/jawn'), 'a .. component is refused');
ok(!subs::path_is_under('/home/jawnos/x', '/home/jawn'), 'a sibling with the root as a prefix is refused');
ok(!subs::path_is_under('relative/x', '/home/jawn'), 'a relative path is refused');

my $dir = tempdir(CLEANUP => 1);
$gb::tmp_dir = $dir;
my $ok_file = "$dir/ok.txt";
write_file($ok_file, 'x');
ok(subs::media_path_allowed($ok_file), 'a file in the temp root is readable');
ok(!subs::media_path_allowed('/etc/passwd'), 'a system file is not media');
symlink('/etc/passwd', "$dir/link") or die "symlink: $!";
ok(!subs::media_path_allowed("$dir/link"), 'a link out of the root is refused');

# --- the ticket QR and the cloud base stay in the house ---------------------
my $cloud = subs::cloud_sync_destination({ base => '/etc', path => '' });
is($cloud->{'error'}, 'destination is outside the house', 'an absolute /etc cloud base is refused');
my $cloud_ok = subs::cloud_sync_destination({ base => 'jawnos-copy', path => 'a/b' });
ok(!$cloud_ok->{'error'}, 'a relative cloud base is under home and allowed');

# --- a leading & is refused, not eval'd -------------------------------------
{
	package FakeC;
	sub new { my ($class, $p) = @_; return bless { p => $p || {} }, $class }
	sub param { my ($s, $k) = @_; return $s->{p}->{$k} }
	package main;
}

# --- the coding run verb rejects shell metacharacters -----------------------
for my $cmd ( 'perl scripts/x $(id)', 'perl scripts/x `id`', 'prove t/ "q"', 'git log > /tmp/x' ) {
	my $out = Manager::coding_execute(undef, { action => 'run', command => $cmd }, {});
	like($out, qr/^refused:/, "coding run '$cmd' is refused");
}

# --- source shapes ----------------------------------------------------------
my $ws = source('lib/JawnOS/Controller/manager_ws.pm');
like($ws, qr/privilege_is_house\(\$c->session\('privilege'\)\)/, 'the socket asks for house privilege');
like($ws, qr/\$apper ne 'server'/, 'and refuses the server app to a visitor');

my $ide = source('lib/JawnOS/Controller/manager_misc10.pm');
like($ide, qr/path_is_under\(\$filename, &subs::home\('~'\), '\/sdcard'\)/, 'file_create is confined to the house');
like($ide, qr/system\('shred', '-u', \$file\)/, 'file_delete shreds in list form');
unlike($ide, qr/`touch \$filename`/, 'no raw create path reaches a shell');
like($ide, qr/path_is_under\(\$file, &subs::home\('~'\), '\/sdcard'\)/, 'file_open and save are confined');
like($ide, qr/sysopen\(my \$save_fh, \$file, Fcntl::O_WRONLY\(\) \| Fcntl::O_CREAT\(\) \| Fcntl::O_TRUNC\(\) \| Fcntl::O_NOFOLLOW\(\)/,
	'save writes in Perl and refuses to follow a symlink');

my $part24 = source('lib/JawnOS/Manager/Part24.pm');
like($part24, qr/path_is_under\(\$file, &subs::home\('~'\), '\/sdcard'\)/, 'the IDE reader is confined');
like($part24, qr/open\(my \$dfh, '-\|', 'df', '-h', '--', \$folder\)/, 'the disk figure is read in list form');
unlike($part24, qr/`cat \$file`/, 'no file read goes through cat');
unlike($part24, qr/`ls \$formatted/, 'no folder listing goes through ls');

like(source('lib/JawnOS/Domain/Render.pm'), qr/refused: a leading & is not a command/,
	'the leading-& branch refuses instead of eval');
unlike(source('lib/JawnOS/Domain/Render.pm'), qr/eval \{ \$command \}/, 'the command string is not eval\'d');
like(source('lib/JawnOS/Manager/Part29.pm'), qr/refused: a shell metacharacter in a run command/,
	'the coding run verb rejects metacharacters');

my $people = source('lib/JawnOS/Domain/People.pm');
like($people, qr/article_html_clean\(\$html_text\)/, 'an HTML letter is sanitized before storage');
like($people, qr/html_text\(\$plain_text\)/, 'a plain letter is escaped before storage');
like(source('templates/mail/email.html.ep'), qr/article_html_clean\(\$body\)/, 'the reader sanitizes old rows too');
my $message = source('templates/mail/message.html.ep');
unlike($message, qr/<%== \$m->\{'email'\} %>/, 'the sender address is escaped');
unlike($message, qr/<%== \$m->\{'manager_file'\} %>/, 'the sender name is escaped');
like(source('templates/apps/video/markup.html.ep'), qr/<video autoplay/, 'the media window no longer renders a request contents param');
unlike(source('templates/apps/video/markup.html.ep'), qr/<%== \$c->param\('contents'\) %>/, 'no raw request fragment is drawn');

my $part22 = source('lib/JawnOS/Manager/Part22.pm');
like($part22, qr/article_html_clean\(\$raw_html\)/, 'a fetched page is sanitized before storage');
like($part22, qr/content => \$content,/, 'the stripped form is stored, not the raw body');
like(source('public/js/manager/manager/07_timeshift.js'), qr/sandbox: 'allow-forms'/, 'the browser iframe is sandboxed');

my $misc13 = source('lib/JawnOS/Controller/manager_misc13.pm');
like($misc13, qr/html_text\(\$words\)/, 'say_it escapes its reply');
like($misc13, qr/bad timestamp/, 'a snapshot name must be a number');
like($misc13, qr/the body names another machine/, 'a health report cannot name another machine');

like(source('lib/JawnOS/Manager/Part08.pm'), qr/no_bless_objects => 1/, 'peer Sereal refuses blessed objects');
my $eval = source('lib/JawnOS/Domain/Evaluation.pm');
like($eval, qr/\$ai_media_url_ok->\(\$part->\{'url'\}\)/, 'a model image URL is checked');
like($eval, qr/max_redirects\(0\)/, 'the image fetch does not follow redirects');
like(source('lib/JawnOS/Domain/Archive.pm'), qr/destination is outside the house/, 'a cloud base is confined');
like(source('lib/JawnOS/Controller/manager_misc9.pm'), qr/path_name\(\$u->filename\)/, 'the recording upload name is one component');
like(source('lib/JawnOS/Controller/manager_configure2.pm'), qr/my %editable = map/, 'the remote-machine field is whitelisted');

# --- a pinned key is not a grant -------------------------------------------
my $part12 = source('lib/JawnOS/Manager/Part12.pm');
like($part12, qr/peer_allows\(\$c, \$rm, 'trusted'\)/, 'the ticket desk needs a trusted grant');
my $sesh = source('lib/JawnOS/Controller/sesh_check.pm');
like($sesh, qr/\$peer_row->\{'pubkey'\} && &subs::peer_verify_strict/, 'a peer login needs a pinned key');
like($sesh, qr/peer_allows\(\$c, \$peer_row, 'resident'\)/, 'and a live resident grant');
like(source('lib/JawnOS/Domain/House.pm'), qr/return 0 unless \$sig;/, 'an unsigned beacon proves nothing');
like(source('lib/JawnOS/Controller/manager_misc14.pm'), qr/next unless \$cand->\{'pubkey'\}/, 'remote_auth_test skips keyless rows');

for my $rel (qw(lib/JawnOS/Controller/manager_misc2.pm lib/JawnOS/Controller/manager_misc3.pm lib/JawnOS/Controller/manager_security2.pm lib/JawnOS/Controller/manager_security3.pm lib/JawnOS/Controller/manager_misc11.pm)) {
	like(source($rel), qr/peer_allows\(\$c, \$rm, 'trusted'\)/, "$rel requires a trusted grant");
}

my $health = source('lib/JawnOS/Manager/Part35.pm');
like($health, qr/signatorial.*eq ''/, 'the loopback shortcut does not apply to a named peer');

for my $rel (qw(lib/JawnOS/Controller/mail_ws.pm lib/JawnOS/Manager/Part34.pm lib/JawnOS/Domain/Notify.pm lib/JawnOS/Controller/manager_embedded.pm lib/JawnOS/Domain/Device.pm)) {
	like(source($rel), qr/peer_host_is_literal\(\$ping_ip\)/, "$rel pings only a literal host");
}
like(source('lib/JawnOS/Domain/Ble.pm'), qr/my \@am = \('am', 'broadcast'/, 'the BLE broadcast is an argv list');
like(source('lib/JawnOS/Controller/manager_misc11.pm'), qr/\$jawn_uuid =~ s\/\[\^A-Za-z0-9\]\/\/g;/, 'the SMS result name is a token');

my $audit = source('scripts/security_audit.pl');
like($audit, qr/perl\.shell\.terminal_name/, 'the audit names terminal_name as a non-quoter');
like($audit, qr/perl\.eval\.command/, 'the audit names the leading-& eval');
like($audit, qr/perl\.shell\.am_broadcast/, 'the audit names am broadcast');

done_testing();
