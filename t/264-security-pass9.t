# tests-for: lib/JawnOS/Domain/Calendar.pm lib/JawnOS/Domain/Sync.pm perl/hooks.pl lib/JawnOS/Controller/Root_misc.pm lib/JawnOS/Manager/Part08.pm lib/JawnOS/Domain/Note.pm perl/Alarm.pl lib/JawnOS/Domain/Ai.pm lib/JawnOS/Controller/manager_misc14.pm lib/JawnOS/Domain/Lan.pm lib/JawnOS/Domain/Git.pm lib/JawnOS/Domain/Say.pm lib/JawnOS/Manager/Part22.pm lib/JawnOS/Controller/manager_watch.pm templates/store/item.html.ep templates/file_information.html.ep templates/apps/music/music.html.ep templates/twirl.html.ep lib/JawnOS/Manager/Part11.pm lib/JawnOS/Controller/manager_clock.pm lib/JawnOS/Controller/manager_security2.pm lib/JawnOS/Controller/manager_misc3.pm perl/AddressDirectory.pl lib/JawnOS/Controller/teletype_misc.pm lib/JawnOS/Controller/store_misc.pm lib/JawnOS/Controller/manager_security3.pm lib/JawnOS/Manager/Part25.pm lib/JawnOS/Controller/manager_embedded.pm perl/President.pl
# covers:    The ninth audit pass: ids are drawn from the OS, a token that only
#           opens with the empty key is refused, the legacy homepage value is
#           compared not thawed, the last shell sinks are closed, and reflected
#           or stored text cannot become HTML or script.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

sub source { return read_file(root() . '/' . $_[0]) }

# --- ids come from the OS, not from rand() ----------------------------------
my %seen;
for my $i (1 .. 200) {
	my $id = subs::random_string_creator(24);
	is(length($id), 24, 'a 24-character id is 24 characters') if $i == 1;
	like($id, qr/\A[A-Za-z0-9]+\z/, 'and holds the default alphabet') if $i == 1;
	$seen{$id}++;
}
is(scalar keys %seen, 200, '200 ids are 200 distinct values');
my $digits = subs::random_string_creator(40, '0123456789');
like($digits, qr/\A[0-9]{40}\z/, 'a digits-only id honours its alphabet');
like(source('lib/JawnOS/Domain/Calendar.pm'), qr/Crypt::PRNG::random_bytes/,
	'the generator draws from the OS');
unlike(source('lib/JawnOS/Domain/Calendar.pm'), qr/\brand \@chars\b/,
	'and no longer draws from rand()');

# --- a token is judged under the real key, never the empty one -------------
my $sealed = subs::encrypter('correct-horse', 'the payload');
like($sealed, qr/\AJS1:/, 'a new seal names the AEAD format');
is(subs::decrypter_strict('correct-horse', $sealed), 'the payload',
	'the real key opens its own seal');
isnt(subs::decrypter_strict('wrong-key', $sealed), 'the payload',
	'a different key does not');
my $tampered = $sealed;
my $middle = int(length($tampered) / 2);
substr($tampered, $middle, 1) = chr(ord(substr($tampered, $middle, 1)) ^ 1);
isnt(subs::decrypter_strict('correct-horse', $tampered), 'the payload',
	'a changed byte is refused');
# A legacy blob, written the way older builds wrote it: Crypt::Simple keyed by
# the empty passphrase.
my $legacy;
{
	require Crypt::Simple;
	local *main::encrypt;
	local *main::decrypt;
	Crypt::Simple->import(passphrase => undef);
	$legacy = eval { main::encrypt('legacy payload') };
}
isnt(subs::decrypter_strict('real-key', $legacy), 'legacy payload',
	'a legacy empty-key blob is refused by the strict reader');
is(subs::decrypter('real-key', $legacy), 'legacy payload',
	'while the legacy reader still reads it');
my $hooks = source('perl/hooks.pl');
like($hooks, qr/decrypter_strict\(\$pa, \$wsa\)/, 'ws_auth uses the strict reader');
like($hooks, qr/defined \$pa && length \$pa/, 'and shuts when no ws_pa is configured');
like(source('lib/JawnOS/Manager/Part08.pm'), qr/decrypter_strict\(\$secret, \$res->body\)/,
	'peer bytes are read strictly');
like(source('lib/JawnOS/Domain/Note.pm'), qr/decrypter_strict\(\$key, \$contented\)/,
	'a media unlock token is read strictly');
my $root = source('lib/JawnOS/Controller/Root_misc.pm');
unlike($root, qr/&subs::decrypter\(/, 'the legacy homepage value is not decrypted');
like($root, qr/\$remote_signatorial eq \$signatorial/, 'it is compared');

# --- the last shell sinks ---------------------------------------------------
my $alarm = source('perl/Alarm.pl');
unlike($alarm, qr/`ls -a \$cf`/, 'the cache folder is not listed by a shell');
like($alarm, qr/opendir\(my \$dh, \$cf\)/, 'it is read in Perl');
like(source('lib/JawnOS/Domain/Ai.pm'), qr/&subs::shell_quote\(\$bin\), &subs::shell_quote\(\$model\)/,
	'the whisper pipeline shell-quotes its program and model');
like(source('lib/JawnOS/Controller/manager_misc14.pm'), qr/&subs::shell_quote\(\$whisper_bin\)/,
	'and so does the second pipeline');
my $lan = source('lib/JawnOS/Domain/Lan.pm');
unlike($lan, qr/`ps -e \| grep \$pid`/, 'a pid is not grep\'d through a shell');
like($lan, qr/kill\(0, \$pid\)/, 'it is asked of the kernel');
like(source('lib/JawnOS/Domain/Git.pm'), qr/File::Temp::tempfile\('jawn_gh_XXXXXX'/,
	'the github download is an exclusive temp file');

# --- text cannot become markup or script ------------------------------------
my $say = source('lib/JawnOS/Domain/Say.pm');
like($say, qr/hint="' \. \$hint_attr \. '"/, 'the icon hint attribute is escaped');
like($say, qr/app="' \. \$name_attr \. '"/, 'and its app name');
like($say, qr/&subs::html_text\(encode_json\(\$unformatted_name\)\)/,
	'and the onclick name is a JS string, HTML-escaped');
my $part22 = source('lib/JawnOS/Manager/Part22.pm');
like($part22, qr/m\{\\Ahttps\?:\/\/\}i/, 'an iframe source must be http(s)');
like($part22, qr/&subs::html_text\(\$type->\{'iframe'\}\)/, 'and is escaped into its attribute');
like(source('lib/JawnOS/Controller/manager_watch.pm'),
	qr/content_type\('text\/plain'\);\n\s+\$c->render\(text => \$uuid\)/,
	'the watch save echoes an id as text');
like(source('templates/store/item.html.ep'), qr/article_html_clean/,
	'a shop description is sanitized HTML');
like(source('templates/file_information.html.ep'), qr/html_text\(\$file->\{'ocr'\}\)/,
	'OCR text is escaped');
like(source('templates/apps/music/music.html.ep'), qr/\$mao_js =~ s\{<\/\}\{<\\\\\/\}/,
	'the music state cannot close its script element');
like(source('templates/twirl.html.ep'), qr/\$hs_js =~ s\{<\/\}\{<\\\\\/\}/,
	'and neither can the high-score table');

# --- visitors and untrusted peers ------------------------------------------
my $part11 = source('lib/JawnOS/Manager/Part11.pm');
like($part11, qr/!&subs::guest_browser_session\(\$c->session\('privilege'\), \$c->session\('source'\)\)/,
	'the tunnel rail refuses a visitor ticket');
like($part11, qr/peer_allows\(\$c, \$rm, 'trusted'\)/, 'and wants a trusted peer');
like(source('lib/JawnOS/Controller/manager_clock.pm'), qr/peer_allows\(\$c, \$peer_rm, 'trusted'\)/,
	'an alarm edit from a peer needs trust');
my $sec2 = source('lib/JawnOS/Controller/manager_security2.pm');
my $go = () = $sec2 =~ /peer_allows\(\$c, \$rm, 'trusted'\)/g;
cmp_ok($go, '>=', 2, 'both Go relays need trust');
my $misc3 = source('lib/JawnOS/Controller/manager_misc3.pm');
my $appstore = () = $misc3 =~ /peer_allows\(\$c, \$rm, 'member'\)/g;
cmp_ok($appstore, '>=', 2, 'the app store rail needs a member grant');
like(source('perl/AddressDirectory.pl'), qr/peer_allows\(\$c, \$row, 'trusted'\)/,
	'the address directory is for trusted peers');
like(source('lib/JawnOS/Controller/teletype_misc.pm'), qr/a visitor's ticket is not/,
	'the neighbour list is not for visitors');
my $store = source('lib/JawnOS/Controller/store_misc.pm');
my $store_guards = () = $store =~ /# A shop document is written|# The compose view carries/g;
is($store_guards, 2, 'quote/save and the draft mail view are the house\'s');
like(source('lib/JawnOS/Controller/manager_security3.pm'), qr/guest_browser_session/,
	'padlock_state refuses a visitor ticket');
my $hooks_csrf = source('perl/hooks.pl');
like($hooks_csrf, qr{/manager/qrcode_generator}, 'the ticket QR GET is CSRF-checked');
like($hooks_csrf, qr{/manager/volume_control /manager/torch}, 'so are volume and torch');

# --- content does not reach the log ----------------------------------------
unlike(source('lib/JawnOS/Manager/Part25.pm'), qr/\$log->info\(\$m->\{'body'\}\)/,
	'a mail body is not logged');
unlike(source('lib/JawnOS/Controller/manager_embedded.pm'), qr/Dumper \$returner/,
	'the embedded request (with its token) is not logged');
unlike(source('perl/President.pl'), qr/Dumper \$query/, 'nor is an AI query');

done_testing();
