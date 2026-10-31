use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

# sms_list_check wrote the mailbox row and the appointment with the same stamp,
# so the millisecond-date bug filled both tables. Mailbox has no stop_timestamp,
# and its body is a sealed note whose ciphertext differs on every write: two
# writes of one message can never be compared byte for byte. These tests pin the
# inverse, the event identity used to dedupe, and the wiring that lets the audit
# and the signed peer lever clear mailbox rows too.

my $real = 1793302644491;               # the message's real millisecond date
my $ost  = 1793393508781;               # the moment the mangled row was written
my $now  = $ost;
my $bad_ts = $ost - $real * 60000;      # what ago_calc stored (minutes, not ms)

# A mailbox-shaped row as sms_list_check writes it: no stop_timestamp, and the
# phone is one of the sanctioned fixtures.
sub mailbox_row {
	my (%over) = @_;
	return {
		uuid => 'fixture-uuid', phone => '5199188319', manager_file => 'Me',
		status => 'sent', body => 'A' x 120, timestamp => $bad_ts,
		ost => $ost, server_time => $ost, app => undef,
		%over,
	};
}

# ------------------------------------------------- records_bad_date_fix (mailbox)
my $row = mailbox_row();
my $fix = &subs::records_bad_date_fix($row, $now);
is ref($fix), 'HASH', 'a mangled mailbox row is recognised';
is $fix->{'timestamp'}, $real, 'its millisecond date is recovered exactly';
ok !defined $fix->{'stop_timestamp'}, 'a mailbox row never gains a stop';

# ------------------------------------------------------- the dedupe decision
# No sane copy: keep the first mangled row, tombstone its re-writes.
my $first = mailbox_row(uuid => 'm-first');
my $again = mailbox_row(uuid => 'm-again', timestamp => $bad_ts - 7);
my $d = &subs::records_mailbox_date_decisions([$first, $again], [], $now);
is scalar @{$d}, 2, 'both mangled rows are decided';
is $d->[0]->{'suggested'}, 'repair', 'the first row of an event is repaired';
is $d->[0]->{'table'}, 'mailbox', 'the finding says which table it belongs to';
is $d->[1]->{'suggested'}, 'tombstone', 'a re-write inside the same second is tombstoned';

# A sane copy is already stored. Its body is sealed, so it cannot equal the
# mangled row's ciphertext; the event (phone, sender, status, time) still wins.
my $sealed = {
	uuid => 'sane-sealed', phone => '5199188319', manager_file => 'Me',
	status => 'sent', body => 'B' x 140, timestamp => $real + 220,
};
my $d2 = &subs::records_mailbox_date_decisions([$first], [$sealed], $now);
is $d2->[0]->{'suggested'}, 'tombstone', 'a sane sealed copy of the event wins';
like $d2->[0]->{'why'}, qr/already stored/, 'and the reason says so';

# A readable body has to agree; one that does not cannot be the same message.
my $readable = {
	uuid => 'sane-plain', phone => '5199188319', manager_file => 'Me',
	status => 'sent', body => 'hello from the fixture', timestamp => $real + 220,
};
my $plain_same = mailbox_row(uuid => 'm-plain', body => 'hello from the fixture');
my $d3 = &subs::records_mailbox_date_decisions([$plain_same], [$readable], $now);
is $d3->[0]->{'suggested'}, 'tombstone', 'an identical readable body is the same message';

my $plain_other = mailbox_row(uuid => 'm-other', body => 'a different message entirely');
my $d4 = &subs::records_mailbox_date_decisions([$plain_other], [$readable], $now);
is $d4->[0]->{'suggested'}, 'repair', 'a different readable body is not deduped away';

# The event is narrower than the table: another sender, another status or a
# time outside the second is its own event, not a re-write.
foreach my $field (qw(phone manager_file status)) {
	my $other = { %{$sealed}, $field => 'someone else' };
	my $dd = &subs::records_mailbox_date_decisions([$first], [$other], $now);
	is $dd->[0]->{'suggested'}, 'repair', "a different $field is a different event";
}
my $later = { %{$sealed}, timestamp => $real + 2000 };
my $d5 = &subs::records_mailbox_date_decisions([$first], [$later], $now);
is $d5->[0]->{'suggested'}, 'repair', 'a sane row more than a second away is not the same event';

# A row below the signature is not touched, and an unreadable row is skipped.
my $sane_row = mailbox_row(uuid => 'm-sane', timestamp => $real);
is scalar @{ &subs::records_mailbox_date_decisions([$sane_row], [], $now) }, 0,
	'a sane row is left alone';

# ------------------------------------------------------------------- wiring
{
	my $read = sub {
		open(my $fh, '<', $_[0]) or die "$_[0]: $!";
		local $/;
		my $text = <$fh>;
		close $fh;
		return $text;
	};
	my $root = root();
	my $subs = $read->("$root/subroutines.pl");
	like $subs, qr/sub records_mailbox_bad_dates_scan/,
		'the mailbox bad-date scan is reusable';
	like $subs, qr/sub records_mailbox_date_decisions/,
		'with a pure keep/tombstone decision';
	like $subs, qr/sub records_mailbox_repair_date/, 'and a repair writer';
	like $subs, qr/sub records_mailbox_tombstone/, 'and a mailbox tombstone';
	like $subs, qr/mailbox_bad_dates => scalar \@\{\$report->\{'mailbox_bad_dates'\}\}/,
		'the audit summary counts mailbox bad dates';
	like $subs, qr/\$report->\{'mailbox_bad_dates'\}/,
		'records_audit fills the mailbox bad-date list';
	like $subs, qr/records_mailbox_bad_dates_scan\(\$now\)/,
		'the peer repair pass includes the mailbox';
	like $subs, qr/table => 'mailbox'/, 'the tombstone names the mailbox table';
	my $manager = $read->("$root/Manager.pl");
	like $manager, qr/subs::records_repair_bad_dates/,
		'the records/repair rail reaches the mailbox pass through the same call';
	my $cli = $read->("$root/scripts/records_audit.pl");
	like $cli, qr/BAD DATES IN THE MAILBOX/, 'the CLI prints the mailbox section';
}

done_testing();
