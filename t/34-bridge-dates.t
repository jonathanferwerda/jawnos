use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

# The Android bridge reports an SMS or call date as the epoch in milliseconds
# (Telephony.Sms.DATE / CallLog.Calls.DATE). The old termux-api list returned a
# written date, so the checks handed the value to ago_calc, which bills a bare
# number as *minutes*. That subtracted date*60000 ms from now and wrote records
# millions of years in the past (the "3409757y" rows). These tests pin the
# pass-through and the exact inverse used to repair what was already written.

my $now = &subs::rightNow();

# ------------------------------------------------------------- epoch_or_span
is &subs::epoch_or_span(1793457310112, $now), 1793457310112,
	'a millisecond epoch passes through';
is &subs::epoch_or_span('1793457310112', $now), 1793457310112,
	'the bridge value as a string passes through too';
is &subs::epoch_or_span(1793457310, $now), 1793457310000,
	'a ten-digit seconds stamp is widened to milliseconds';
is &subs::epoch_or_span('3h', $now), $now - 3 * 3600000,
	'a span still reaches ago_calc unchanged';
is &subs::epoch_or_span('-120m', $now), $now + 120 * 60000,
	'and a signed span keeps its sign';
is &subs::epoch_or_span(undef, $now), undef,
	'nothing stays nothing';

# --------------------------------------------------------- records_bad_date_fix
my $sms = {
	timestamp => -107596365275951649, ost => 1793393508781,
	server_time => 1793393508774, type => 'sms', app => 'andrea_urbaniak',
};
my $fix = &subs::records_bad_date_fix($sms, $now);
is ref($fix), 'HASH', 'a mangled row is recognised';
is $fix->{'timestamp'}, 1793302644491, 'its millisecond date is recovered exactly';
ok !defined $fix->{'stop_timestamp'}, 'an sms row is not given a stop';

my $stop = {
	timestamp => -107513007236039449, stop_timestamp => -107513007236039449,
	ost => 1793393520600, server_time => 1793394061244, type => 'stop', app => '4162465203',
};
my $sfix = &subs::records_bad_date_fix($stop, $now);
is $sfix->{'timestamp'}, 1791913343826, 'a call row recovers from its own ost';
is $sfix->{'stop_timestamp'}, $sfix->{'timestamp'}, 'its end lands on the same date';

is &subs::records_bad_date_fix({ timestamp => 1793457310112, ost => $now }, $now), undef,
	'a sane row is left alone';
is &subs::records_bad_date_fix({ timestamp => -2000000000000000, ost => '', server_time => 'x' }, $now), undef,
	'a row with no readable writing moment is not rewritten';

# ------------------------------------------------------------- the audit wiring
# The repair runs through the sanctioned audit path (scripts/records_audit.pl
# --apply), so a bad-date finding must be carried by records_audit and applied
# by records_reconcile. Pin the wiring so a rename cannot quietly drop it.
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
	like $subs, qr/bad_dates => scalar \@\{\$report->\{'bad_dates'\}\}/,
		'the audit summary counts bad dates';
	like $subs, qr/\$report->\{'bad_dates'\}/,
		'records_audit fills the bad_dates list';
	like $subs, qr/action => 'repair-date'/,
		'records_reconcile carries a repair-date action';
	like $subs, qr/sub records_repair_date/,
		'and writes it through records_repair_date';
	like $subs, qr/sub records_bad_dates_scan/, 'the bad-date scan is reusable';
	like $subs, qr/sub records_repair_bad_dates/, 'with a repair-only pass for a peer';
	my $manager = $read->("$root/Manager.pl");
	like $manager, qr/eq 'bad_dates'/, 'the records/repair rail offers the bad-date pass';
	like $manager, qr/subs::records_repair_bad_dates/, 'and calls it';
	my $cli = $read->("$root/scripts/records_audit.pl");
	like $cli, qr/BAD DATES/, 'the CLI prints the bad-date section';
}

done_testing();
