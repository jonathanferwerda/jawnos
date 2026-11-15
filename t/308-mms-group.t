# tests-for: lib/JawnOS/Domain/Sync.pm
# covers:    a group MMS keeps everyone the phone saw; a one-to-one message is unchanged
#           (the app's DeviceService.mms.list supplies the recipients)

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use Mojo::Template;
use JawnOSTest;

subs::preload('mms_list_check');
subs::preload('controller_builder');

{ package FakeRows;
  sub new { my ($class, $rows) = @_; return bless { rows => $rows || [] }, $class; }
  sub hashes { return $_[0]->{'rows'}; }
}

my $now = 1_700_000_000_000;
my (@inserts, @arrivals, @appointments, %seen);
my $bridge = [];

{
	no warnings 'redefine';
	local $subs::device = 'mobile';
	local *subs::device_call = sub { return { messages => $bridge } };
	local *subs::rightNow = sub { return $now };
	local *subs::epoch_or_span = sub { return $_[0] };
	local *subs::phone_number_app = sub { return 'phone' };
	local *subs::note_encrypter = sub { return 'SEALED:' . $_[1] };
	local *subs::suds_grabber = sub { return 'suds' };
	local *subs::controller_builder = sub { return undef };
	local *subs::format_name = sub { return 'Phone' };
	local *subs::unformat_name = sub { return 'phone' };
	local *subs::ui = sub { return $_[0] };
	local *subs::db_select = sub {
		my ($table, undef, $where) = @_;
		my $id = ref $where eq 'HASH' ? ($where->{'message_id'} || '') : '';
		return FakeRows->new($seen{$id} ? [ { uuid => 'already' } ] : []);
	};
	local *subs::db_insert = sub {
		my ($table, $row) = @_;
		push @inserts, $row;
		$seen{ $row->{'message_id'} } = 1 if $table eq 'mailbox';
		return 1;
	};
	local *subs::db_query = sub { return FakeRows->new([]) };
	local *subs::mail_arrival = sub { push @arrivals, $_[0]; return $_[0] };
	local *Manager::appointment_writer = sub { push @appointments, $_[1]; return { uuid => 'appt' } };

	# A group message from the phone: FROM is the sender the house files
	# under, and the other three are TO/TO/CC - one named twice, the way a
	# carrier's own list repeats an address.
	$bridge = [ {
		id => 11, thread => 42, received => $now,
		number => '+1 (555) 123-4567',
		body => 'Dinner at 7?',
		recipients => [
			{ number => '+1 (555) 123-4567', type => 137 },
			{ number => '+1 (555) 000-0001', type => 151 },
			{ number => '+1 (555) 000-0002', type => 151 },
			{ number => '5550000002', type => 151 },
			{ number => '+1 (555) 000-0003', type => 130 },
		],
		parts => [],
	} ];

	my $first = subs::mms_list_check();
	like $first, qr/MMS from 5551234567/, 'the group message is reported once';
	is scalar @inserts, 1, 'a group message files one mailbox row';
	my $row = $inserts[0];
	is $row->{'message_id'}, 'mms:11', 'the system id still dedupes the message';
	is $row->{'phone'}, '5551234567', 'the row stays in the sender thread';
	is $row->{'manager_file'}, 'Phone', 'the sender still names the row';
	is $row->{'body'}, 'SEALED:Dinner at 7?', 'the words are sealed as before';
	is $row->{'thread'}, 'mms:42', 'the group rides the phone thread id, namespaced';
	is $row->{'cc'}, '5550000001, 5550000002, 5550000003',
		'the other people are named once each, the sender left out';
	is $arrivals[0]->{'phone'}, '5551234567', 'the arrival still lands in the sender thread';
	is $arrivals[0]->{'thread'}, 'mms:42', 'the live arrival carries the group key, not just the stored row';
	is $arrivals[0]->{'cc'}, '5550000001, 5550000002, 5550000003', 'the live arrival carries the people';
	is scalar @appointments, 1, 'one sms appointment is written';

	my $second = subs::mms_list_check();
	is $second, '', 'a second pass files nothing';
	is scalar @inserts, 1, 'the group message is filed once';

	# A plain MMS names the house's own line, so there is exactly one other
	# address and the row must come out the shape it had before recipients.
	$bridge = [ {
		id => 12, thread => 43, received => $now + 1000,
		number => '+1 (555) 222-3333',
		body => 'Just you',
		recipients => [
			{ number => '+1 (555) 222-3333', type => 137 },
			{ number => '+1 (555) 999-9999', type => 151 },
		],
		parts => [],
	} ];

	subs::mms_list_check();
	is scalar @inserts, 2, 'the one-to-one message files its own row';
	my $solo = $inserts[1];
	is $solo->{'phone'}, '5552223333', 'the one-to-one row keeps its sender';
	ok !exists $solo->{'thread'}, 'the one-to-one row gains no thread key';
	ok !exists $solo->{'cc'}, 'the one-to-one row names no participants';
	is $solo->{'message_id'}, 'mms:12', 'the one-to-one row still dedupes by its id';
	ok !exists $arrivals[1]->{'thread'}, 'the one-to-one arrival gains no thread key';
	ok !exists $arrivals[1]->{'cc'}, 'the one-to-one arrival names no participants';

	# A bridge that predates recipients sends no list at all: the row must be
	# written exactly as it was, not crash and not gain empty columns.
	$bridge = [ {
		id => 13, thread => 44, received => $now + 2000,
		number => '+1 (555) 444-4444',
		body => 'Old bridge',
	} ];

	subs::mms_list_check();
	is scalar @inserts, 3, 'a message without an address list still files';
	my $legacy = $inserts[2];
	ok !exists $legacy->{'thread'}, 'no thread key comes from a missing list';
	ok !exists $legacy->{'cc'}, 'no participants come from a missing list';
}

# ---------------------------------------------------------------- the bubble
# The live arrival is only half of it: the Chat window draws the bubble from
# `mail/message`, so the group must reach the template and come out as words.
{ package FakeContext;
  # chat_ui is what makes the partial draw the Chat bubble rather than the
  # mailbox's message row.
  sub new { return bless {}, shift }
  sub stash { return 1 }
}

my $partial = do { open(my $fh, '<', "$FindBin::Bin/../templates/mail/message.html.ep") or die $!; local $/; <$fh> };

sub render_bubble {
	my ($m) = @_;
	no warnings 'redefine';
	local *subs::mail_message_incoming = sub { return 1 };
	local *subs::lang = sub { return 'Me' };
	local *subs::ui = sub { return $_[0] };
	return Mojo::Template->new(vars => 1, auto_escape => 1)->render($partial, {
		m => $m, me => '', c => FakeContext->new,
	});
}

my $group_html = render_bubble({
	uuid => 'u1', status => 'inbox', manager_file => 'Phone', body => 'SEALED:Dinner at 7?',
	decrypted => 'no', thread => 'mms:42', cc => '5550000001, 5550000002',
});
like $group_html, qr/chat_bubble chat_in/, 'the group message still draws in the sender bubble';
like $group_html, qr/class="chat_group"/, 'the bubble carries the group line';
like $group_html, qr/>with 5550000001, 5550000002</, 'the group line names the participants as words';

my $solo_html = render_bubble({
	uuid => 'u2', status => 'inbox', manager_file => 'Phone', body => 'Just you', decrypted => 'no',
});
like $solo_html, qr/chat_bubble chat_in/, 'a one-to-one message still draws';
unlike $solo_html, qr/class="chat_group"/, 'a one-to-one bubble has no group line';

my $email_html = render_bubble({
	uuid => 'u3', email => 'someone@example.com', status => 'inbox', subject => 'Hi', cc => 'x@y',
});
unlike $email_html, qr/class="chat_group"/, 'the email branch is left alone';

done_testing();
