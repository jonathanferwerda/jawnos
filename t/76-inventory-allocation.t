# tests-for: lib/JawnOS/Manager/Part16.pm
# covers:    The inventory panel's Share wheel is a scope split into its own parts: a week into days, a day into hours.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use Time::Local;
use RepoSource qw(repo_root);

# The inventory panel's Share wheel is a scope split into its own parts: a week
# into days, a day into hours. The percentages have to add up to 100, the parts
# have to be in time order, and a scope with nothing recorded has to come back
# as empty rather than as a wheel of nothing. The helper is a plain sub in
# Manager/Part16.pm, so it is read and called without the app.

my $part16 = repo_root() . '/lib/JawnOS/Manager/Part16.pm';
require $part16;

sub window {
	my ($y, $m, $d, $days) = @_;
	my $start = timelocal(0, 0, 0, $d, $m, $y) * 1000;
	my $end = timelocal(0, 0, 0, $d + $days, $m, $y) * 1000;
	return ($start, $end);
}

sub percent_sum {
	my $slices = shift;
	my $sum = 0;
	$sum += $_->{'percent'} for @{$slices};
	return $sum;
}

subtest 'a week splits into seven days that add up to 100' => sub {
	my ($start, $end) = window(2026, 5, 7, 7);	# Sun 7 June 2026
	my @appts;
	for my $d (0 .. 6) {
		push @appts, {
			timestamp => timelocal(0, 0, 12, 7 + $d, 5, 2026) * 1000,
			duration => 3600000,
		};
	}
	my $allocation = Manager::inventory_allocation(\@appts, 'duration', 'week', $start, $end);
	is($allocation->{'scope'}, 'week', 'the answer names its scope');
	ok(!$allocation->{'empty'}, 'a busy week is not empty');
	is(scalar @{$allocation->{'slices'}}, 7, 'one slice for each day of the week');
	is(percent_sum($allocation->{'slices'}), 100, 'the percentages add up to 100');
	is($allocation->{'total'}, 7 * 3600000, 'the total is the whole window');

	my $previous = 0;
	for my $slice ( @{$allocation->{'slices'}} ) {
		cmp_ok($slice->{'start'}, '>', $previous, 'the slices are in time order');
		$previous = $slice->{'start'};
		like($slice->{'label'}, qr{^\d+/\d+$}, "a day is labelled by its date ($slice->{'label'})");
	}
	is($allocation->{'slices'}->[0]->{'label'}, '6/7', 'the first slice is the week\'s first day');
	is($allocation->{'slices'}->[6]->{'label'}, '6/13', 'the last slice is the week\'s last day');
};

subtest 'a session across midnight gives each day its own part' => sub {
	my ($start, $end) = window(2026, 5, 7, 7);
	my @appts = ({
		timestamp => timelocal(0, 0, 23, 7, 5, 2026) * 1000,
		duration => 2 * 3600000,
	});
	my $allocation = Manager::inventory_allocation(\@appts, 'duration', 'week', $start, $end);
	is(scalar @{$allocation->{'slices'}}, 2, 'two days hold time');
	is($allocation->{'slices'}->[0]->{'percent'}, 50, 'the first day holds half the session');
	is($allocation->{'slices'}->[1]->{'percent'}, 50, 'the second day holds the other half');
	is(percent_sum($allocation->{'slices'}), 100, 'the halves add up to 100');
};

subtest 'a day is labelled by its hours' => sub {
	my ($start, $end) = window(2026, 5, 7, 1);
	my @appts = (
		{ timestamp => $start + 9 * 3600000, duration => 3600000 },
		{ timestamp => $start + 9 * 3600000 + 60000, duration => 1800000 },
		{ timestamp => $start + 15 * 3600000, duration => 3600000 },
	);
	my $allocation = Manager::inventory_allocation(\@appts, 'duration', 'day', $start, $end);
	is(scalar @{$allocation->{'slices'}}, 2, 'only the hours that hold time are slices');
	is_deeply([ map { $_->{'label'} } @{$allocation->{'slices'}} ], [ '09:00', '15:00' ], 'the hours are named as clock times');
	is($allocation->{'slices'}->[0]->{'percent'}, 60, 'the hour holding the two sessions is 60% of the day');
	is(percent_sum($allocation->{'slices'}), 100, 'the hours add up to 100');
};

subtest 'rounding never loses or adds a point' => sub {
	my ($start, $end) = window(2026, 5, 7, 1);
	my @appts = map {
		{ timestamp => $start + $_ * 3600000, duration => 1000 }
	} (0, 1, 2);
	my $allocation = Manager::inventory_allocation(\@appts, 'duration', 'day', $start, $end);
	is_deeply([ map { $_->{'percent'} } @{$allocation->{'slices'}} ], [ 34, 33, 33 ], 'three equal parts are rounded to a whole 100');
};

subtest 'occurrences count once in the part they open' => sub {
	my ($start, $end) = window(2026, 5, 7, 7);
	my @appts = map {
		{ timestamp => timelocal(0, 0, 12, 7 + $_, 5, 2026) * 1000, duration => 0 }
	} (0, 2, 4);
	my $allocation = Manager::inventory_allocation(\@appts, 'occurences', 'week', $start, $end);
	is(scalar @{$allocation->{'slices'}}, 3, 'only the days that hold an occurrence are slices');
	is($allocation->{'total'}, 3, 'the total is the three occurrences');
	is(percent_sum($allocation->{'slices'}), 100, 'the occurrences add up to 100');
};

subtest 'a scope with nothing recorded is gracefully empty' => sub {
	my ($start, $end) = window(2026, 5, 7, 7);
	my $allocation = Manager::inventory_allocation([], 'duration', 'week', $start, $end);
	ok($allocation->{'empty'}, 'the empty flag is set');
	is($allocation->{'total'}, 0, 'the total is nothing');
	is_deeply($allocation->{'slices'}, [], 'there are no slices to draw');

	my $outside = Manager::inventory_allocation([
		{ timestamp => $start - 3600000, duration => 3600000 },
	], 'duration', 'week', $start, $end);
	ok($outside->{'empty'}, 'a session outside the scope leaves it empty');

	my $unknown = Manager::inventory_allocation([], 'duration', 'fortnight', $start, $end);
	ok($unknown->{'empty'}, 'an unknown scope comes back empty rather than guessed');
};

subtest 'a year splits into its months' => sub {
	my $start = timelocal(0, 0, 0, 1, 0, 2026) * 1000;
	my $end = timelocal(0, 0, 0, 1, 0, 2027) * 1000;
	my @appts = map {
		{ timestamp => timelocal(0, 0, 12, 15, $_, 2026) * 1000, duration => 3600000 }
	} (0, 5, 11);
	my $allocation = Manager::inventory_allocation(\@appts, 'duration', 'year', $start, $end);
	is(scalar @{$allocation->{'slices'}}, 3, 'three months hold time');
	is(percent_sum($allocation->{'slices'}), 100, 'the months add up to 100');
	cmp_ok($allocation->{'slices'}->[0]->{'start'}, '<', $allocation->{'slices'}->[1]->{'start'}, 'the months are in time order');
};

done_testing();
