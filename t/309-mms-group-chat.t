# tests-for: lib/JawnOS/Manager/Part25.pm lib/JawnOS/Manager/Part37.pm lib/JawnOS/Manager/Part31.pm lib/JawnOS/Controller/mail_ws.pm templates/apps/chat.html.ep public/js/manager/chat.js public/js/mailbox.js
# covers:    a group MMS is a conversation of its own - keyed by the phone's
#           thread id, watched by that id, and replied to by everyone on it,
#           in words alone as well as with a picture.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;
use RepoSource;

# The manager parts are plain Perl files; load the two that own the group's
# address and its send before calling into them.
require "$FindBin::Bin/../lib/JawnOS/Manager/Part37.pm";

my $root = repo_root();

# ---------------------------------------------------------------- the socket
# A tab watching a group is addressed by the phone's thread id, so another
# member's reply lands in the group rather than in their one-to-one thread.
is( Manager::mailws_address_matches({ thread => 'mms:42' }, { thread => 'mms:42' }, undef), 1,
	'a group tab catches a message on its thread' );
is( Manager::mailws_address_matches({ phone => '5199188319' }, { thread => 'mms:42' }, undef), 0,
	'a one-to-one tab does not catch the group' );
is( Manager::mailws_address_matches({ thread => 'mms:42' }, { phone => '5199188319' }, undef), 0,
	'a group message does not fall through to a member\'s number' );
is( Manager::mailws_address_matches({ phone => '5199188319' }, { phone => '5199188319' }, undef), 1,
	'a plain sms still matches by number' );

{ package FakeRows;
  sub new { my ($class, $rows) = @_; return bless { rows => $rows || [] }, $class; }
  sub hashes { return $_[0]->{'rows'}; }
}

# ---------------------------------------------------------------- the people
# Who a reply goes to: every address the group's rows carry, once each, as the
# bare digits the phone's own thread uses. A carrier repeats an address when a
# person is both TO and CC, and the leading 1 is not part of it.
{
	local *subs::db_query = sub {
		return FakeRows->new([
			{ phone => '5199188319', cc => '5199188320, 5199188319' },
			{ phone => '+1 (519) 918-8321', cc => '' },
		]);
	};
	is_deeply( Manager::mailws_group_addresses('mms:42'),
		[ '5199188319', '5199188320', '5199188321' ],
		'a group replies to everyone once, in the phone\'s own digits' );
	is_deeply( Manager::mailws_group_addresses('p:5199188319'), [], 'a one-to-one dial has no group list' );
	is_deeply( Manager::mailws_group_addresses(undef), [], 'no dial has no group list' );
}

{
	package FakeMailC;
	sub new { my ($class, $params) = @_; return bless { params => $params }, $class; }
	sub param { my ($self, $key) = @_; return $self->{'params'}->{$key}; }
	sub session { my ($self, $key) = @_; return $self->{'params'}->{$key}; }
}

my $group_c = FakeMailC->new({ privilege => 'citizen', mail_thread => 'mms:42', phone => '5199188319' });
my $group_address = Manager::mailws_address($group_c, {});
is( $group_address->{'thread'}, 'mms:42', 'the tab registers the group thread' );
ok( !$group_address->{'phone'}, 'and not the sender\'s number' );

my $plain_c = FakeMailC->new({ privilege => 'citizen', phone => '5199188319' });
my $plain_address = Manager::mailws_address($plain_c, {});
is( $plain_address->{'phone'}, '5199188319', 'a plain thread still registers its number' );
ok( !$plain_address->{'thread'}, 'and carries no thread' );

# ---------------------------------------------------------------- the rail
my $part25 = read_file("$root/lib/JawnOS/Manager/Part25.pm");
like( $part25, qr/my \$thread = \$c->param\('mail_thread'\)/, 'the reader takes the group dial' );
like( $part25, qr/\$key = 'g:' \. \$r->\{'thread'\}/, 'a group row keys on its thread, not its sender' );
like( $part25, qr/\$thread_key = \$r->\{'thread'\}/, 'the row hands the thread to the template' );
like( $part25, qr/thread = \? and coalesce\(status,/, 'a group thread is read back by its thread id' );
like( $part25, qr/,\s*thread, cc\n/, 'the recent list reads both group columns' );

my $template = read_file("$root/templates/apps/chat.html.ep");
like( $template, qr/thread="<%= \$rc->\{'thread'\} \|\| '' %>"/, 'the recent row carries the thread' );

# ---------------------------------------------------------------- the page
my $chat_js = read_file("$root/public/js/manager/chat.js");
like( $chat_js, qr/localStorage\.setItem\('mail_thread', thread\)/, 'opening a row remembers the group' );
like( $chat_js, qr/data\.mail_thread = thread/, 'and asks the reader for that group' );
like( $chat_js, qr/localStorage\.setItem\('mail_thread', ''\)/, 'a person\'s appointment clears the group' );
like( $chat_js, qr/return 'thread:' \+ thread/, 'the road chosen is remembered per group' );

my $mailbox_js = read_file("$root/public/js/mailbox.js");
like( $mailbox_js, qr/mail_thread: mail_thread/, 'the composer files on the group\'s thread' );
like( $mailbox_js, qr/mail_thread: localStorage\.getItem\('mail_thread'\)/, 'the socket watches the group' );
like( $mailbox_js, qr/if \(mail_thread\) \{/, 'a group\'s sender is a member, not the recipient' );

# ---------------------------------------------------------------- the send
my $mail_ws = read_file("$root/lib/JawnOS/Controller/mail_ws.pm");
like( $mail_ws, qr/my \$group_thread = /, 'the sender recognises a group thread' );
like( $mail_ws, qr/thread => \(\$group_thread \|\| undef\)/, 'and files the row on it' );
like( $mail_ws, qr/my \$send_to = \$group_thread \? join\(' ', \@group_send\)/, 'a group goes to everyone at once' );
like( $mail_ws, qr/if \(\$rides_mms \|\| \$group_thread\)/, 'words alone still ride the mms on a group' );

my $part31 = read_file("$root/lib/JawnOS/Manager/Part31.pm");
like( $part31, qr/scalar \@\{\$parts\} > 0 \|\| \(defined \$text && length \$text\)/,
	'a group with no picture is still one mms' );

done_testing();
