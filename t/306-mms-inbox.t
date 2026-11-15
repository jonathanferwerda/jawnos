# tests-for: lib/JawnOS/Domain/Sync.pm lib/JawnOS/Manager/Part31.pm perl/gb/01_state_and_defaults.pl perl/utility_jobs.pl
# covers:    an inbound MMS is filed once, with its text sealed and its media on the message

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use MIME::Base64 qw(encode_base64);
use Mojo::JSON qw(decode_json);
use JawnOSTest;

subs::preload('mms_list_check');
subs::preload('mms_attachment_store');
# Load the controller builder before the test stubs it: a lazy load inside the
# test's local scope would replace the stub for the second pass.
subs::preload('controller_builder');
require "$FindBin::Bin/../lib/JawnOS/Manager/Part31.pm";

{ package FakeRows;
  sub new { my ($class, $rows) = @_; return bless { rows => $rows || [] }, $class; }
  sub hashes { return $_[0]->{'rows'}; }
}

my $now = 1_700_000_000_000;
my (@inserts, @arrivals, %seen, @stored);
{
	no warnings 'redefine';
	local $subs::device = 'mobile';
	local *subs::device_call = sub {
		return { messages => [ {
			id => 7, thread => 3, received => $now, number => '+1 (555) 123-4567',
			body => 'Hi there',
			parts => [ { name => 'pic.jpg', mime => 'image/jpeg', data => 'aGVsbG8=' } ],
		} ] };
	};
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
	local *Manager::appointment_writer = sub { return { uuid => 'appt' } };
	local *Manager::mms_attachment_store = sub {
		my ($args) = @_;
		push @stored, $args;
		return { uuid => 'u1', f => '/tmp/pic.enc', src => '/file_open?file=/tmp/pic.enc', name => 'pic.jpg', mime => 'image/jpeg' };
	};

	my $first = subs::mms_list_check();
	like $first, qr/MMS from 5551234567/, 'the first pass reports the new message';
	is(scalar @inserts, 1, 'one mailbox row is written');
	my $row = $inserts[0];
	is $row->{'message_id'}, 'mms:7', 'the system id is the dedupe key';
	is $row->{'phone'}, '5551234567', 'the caller number is cleaned';
	is $row->{'body'}, 'SEALED:Hi there', 'the body is sealed at rest';
	is $row->{'status'}, 'inbox', 'the message is an inbox row';
	my $atts = decode_json($row->{'attachments'});
	is scalar @{$atts}, 1, 'the media part rides the message';
	is $atts->[0]->{'f'}, '/tmp/pic.enc', 'the attachment names the sealed file';
	is $stored[0]->{'mime'}, 'image/jpeg', 'the part is stored with its mime type';
	is $arrivals[0]->{'attachments'}, $row->{'attachments'}, 'the arrival carries the same attachments';

	my $second = subs::mms_list_check();
	is $second, '', 'the second pass files nothing';
	is scalar @inserts, 1, 'the message is filed once';
}

{
	my $tmp = tempdir(CLEANUP => 1);
	my $inserted;
	local *subs::setting_grabber = sub { return $tmp };
	local *subs::home = sub { return $_[0] };
	local *subs::path_name = sub { return 'phone' };
	local *subs::rightNow = sub { return $now };
	local *subs::random_string_creator = sub { return 'abc123' };
	local *subs::db_insert = sub { my ($table, $row) = @_; $inserted = $row; return 1 };
	local *subs::db_select = sub { return FakeRows->new([ { file => $inserted->{'file'} } ]) };
	local *subs::file_encrypter = sub { return 1 };
	my $entry = Manager::mms_attachment_store({ app => 'phone', name => 'pic.jpg', mime => 'image/jpeg', data => encode_base64('hello') });
	is ref($entry), 'HASH', 'a media part is stored';
	ok -e $entry->{'f'}, 'the part is written to disk';
	like $entry->{'src'}, qr{^/file_open[?]file=}, 'the entry carries a file_open URL';
	is $entry->{'mime'}, 'image/jpeg', 'the mime is kept';
}

my $part31 = do { open(my $fh, '<', "$FindBin::Bin/../lib/JawnOS/Manager/Part31.pm") or die $!; local $/; <$fh> };
like $part31, qr/sub mms_attachment_store/, 'the attachment helper exists';
like $part31, qr/file_encrypter\(\{ app => \$app \}\)/, 'the part is sealed with the house key';
like $part31, qr/encoding.*base64|decode_base64/, 'the bridge bytes are decoded';

my $defaults = do { open(my $fh, '<', "$FindBin::Bin/../perl/gb/01_state_and_defaults.pl") or die $!; local $/; <$fh> };
like $defaults, qr/'mms' => \{[^}]*toggle => 'on'/, 'the MMS poll is on by default';

my $jobs = do { open(my $fh, '<', "$FindBin::Bin/../perl/utility_jobs.pl") or die $!; local $/; <$fh> };
like $jobs, qr/mms_list_check/, 'the job calls the MMS check';

done_testing();
