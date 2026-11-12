# tests-for: lib/JawnOS/Domain/People.pm lib/JawnOS/Domain/Sync.pm lib/JawnOS/Manager/Part25.pm lib/JawnOS/Manager/Part35.pm templates/mail/message.html.ep templates/apps/chat.html.ep public/js/manager/chat.js public/css/chat.css perl/help/topics_mail.pl perl/language/
# covers:    Chat's recent list and an sms row's direction - one rule for both
#           the thread and the recent preview, so an incoming reply can never
#           be drawn as the house's own words again.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;
use RepoSource;

my $root = repo_root();

# ---------------------------------------------------------------- direction
# A phone row carries its direction in the status the phone wrote; a row from
# before that (public) still names its sender in manager_file.
is( &subs::mail_message_incoming({ phone => '5199188319', status => 'sent', manager_file => 'Me' }, 'Me'), 0,
	'a sent sms is the house\'s own' );
is( &subs::mail_message_incoming({ phone => '5199188319', status => 'inbox', manager_file => 'Dave' }, 'Me'), 1,
	'an inbox sms came from its sender' );
foreach my $received (qw(received recieved)) {
	is( &subs::mail_message_incoming({ phone => '5199188319', status => $received, manager_file => 'Dave' }, 'Me'), 1,
		"a '$received' sms is incoming" );
}
is( &subs::mail_message_incoming({ phone => '5199188319', status => 'public', manager_file => 'Dave' }, 'Me'), 1,
	'a legacy public sms with someone else as writer is incoming' );
is( &subs::mail_message_incoming({ phone => '5199188319', status => 'public', manager_file => 'Me' }, 'Me'), 0,
	'a legacy public sms written by the house is outgoing' );
is( &subs::mail_message_incoming({ contact => 'ticket', status => 'sent', manager_file => 'Dave' }, 'Me'), 1,
	'a ticket row still falls back to its writer' );
is( &subs::mail_message_incoming({ contact => 'ticket', status => 'sent', manager_file => 'Me' }, 'Me'), 0,
	'the house\'s ticket row is outgoing' );

# ---------------------------------------------------------------- the writes
my $sync = read_file("$root/lib/JawnOS/Domain/Sync.pm");
like( $sync, qr/my \$status = \$outgoing \? 'sent' : \(/, 'the phone import names sent and inbox, not public' );
like( $sync, qr/status => \$status,/, 'and files that status on the row' );
like( $sync, qr/if \(\$status eq 'inbox'\) \{/, 'only a delivered text announces itself' );

my $depub = read_file("$root/lib/JawnOS/Manager/Part35.pm");
like( $depub, qr/where status=\? and coalesce\(phone,/, 'the depublicizer leaves a phone row\'s direction alone' );

my $part25 = read_file("$root/lib/JawnOS/Manager/Part25.pm");
like( $part25, qr/\$m->\{'status'\} = \$incoming \? 'inbox' : 'sent'/, 'reading a phone thread keeps the sms direction' );
like( $part25, qr/\$body = \$m->\{'body'\} unless length \$body/, 'a plain public body survives the read' );
like( $part25, qr/my \$recent_chats = \[\];/, 'chat builds a recent list' );
like( $part25, qr/recent_chats => \$recent_chats,/, 'and hands it to the panel' );
like( $part25, qr/my \$sort = \$ts \|\| /, 'a corrupted date falls back to the write time rather than sorting first' );

# ---------------------------------------------------------------- the panel
my $template = read_file("$root/templates/apps/chat.html.ep");
my $recent_at = index($template, 'data-chat_group="recent"');
my $people_at = index($template, 'data-chat_group="people"');
cmp_ok($recent_at, '>', -1, 'the recent list is in the rail');
cmp_ok($people_at, '>', -1, 'the people list is in the rail');
cmp_ok($recent_at, '<', $people_at, 'recent sits above people');
like( $template, qr/class="chat_friend chat_recent"/, 'a recent row opens like a friend row' );
like( $template, qr/chat_recent_preview/, 'and carries the last words' );

my $message = read_file("$root/templates/mail/message.html.ep");
like( $message, qr/&subs::mail_message_incoming\(\$m, \$me\)/, 'the bubble asks the one direction rule' );
like( $message, qr/&subs::lang\('people\.me'\)/, 'and names the house\'s own bubble Me' );

my $chat_js = read_file("$root/public/js/manager/chat.js");
like( $chat_js, qr/\$\(document\)\.on\('click', '\.chat_shell \.chat_friend'/, 'a recent row uses the friend click' );
like( $chat_js, qr/attr\('data-section'\)/, 'and opens the section the row names' );

my $css = read_file("$root/public/css/chat.css");
like( $css, qr/#message \{[^}]*height: 34px/s, 'the composer gives a 15px line its padding and descenders' );
unlike( $css, qr/\.chat_out \.chat_sender \{[^}]*display: none/s, 'the sender label is no longer hidden on outgoing bubbles' );

# ---------------------------------------------------------------- the label
for my $file (glob "$root/perl/language/*.pl") {
	my ($lang) = $file =~ m{language/([a-z]+)\.pl$};
	my $src = read_file($file);
	like( $src, qr/'chat\.recent' => '[^']+'/, "$lang names the recent list" );
}
my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like( $loader, qr/\bmail_message_incoming\b/, 'the direction helper is in the domain loader' );

done_testing();
