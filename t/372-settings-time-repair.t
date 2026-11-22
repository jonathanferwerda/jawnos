# tests-for: scripts/settings_time_repair.pl
# covers:    settings_time_plan - uuid wins, unique-key fallback, ambiguity, the
#           window, equality, value-changed and no-uuid guards, the summary
#           counts, and the default window's densest-hour burst

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;

# settings_time_repair puts back the settings.server_time a bad backfill stamped
# across every row. The pure planner is where the decisions live, so it is driven
# with synthetic arrays here: no snapshot is decrypted and the live database is
# never opened. The CLI's own refusal is checked separately, before it reads a
# database.

my $root = "$FindBin::Bin/..";
require "$root/scripts/settings_time_repair.pl";

sub row {
	my (%a) = @_;
	return {
		'uuid'        => $a{'uuid'},
		'app'         => $a{'app'} // 'home',
		'setting'     => $a{'setting'} // 's',
		'subsetting'  => exists $a{'subsetting'} ? $a{'subsetting'} : '',
		'device'      => exists $a{'device'} ? $a{'device'} : '',
		'value'       => $a{'value'} // 'v',
		'server_time' => $a{'server_time'} // '1000',
	};
}

sub plan_for {
	my ($old, $live, $window) = @_;
	return main::settings_time_plan($old, $live, { 'window_start' => $window });
}

# --- uuid wins, even when the logical key is ambiguous ------------------------
{
	my $plan = plan_for(
		[ row(uuid => 'u1', app => 'home', setting => 'a', server_time => '100'),
		  row(uuid => 'u9', app => 'home', setting => 'a', server_time => '50') ],
		[ row(uuid => 'u1', app => 'home', setting => 'a', server_time => '500') ],
		200,
	);
	is(scalar @{ $plan->{'plan'} }, 1, 'a uuid match plans one row despite an ambiguous key');
	is($plan->{'plan'}[0]{'match'}, 'uuid', 'and records the uuid match');
	is($plan->{'plan'}[0]{'to'}, '100', 'to is the snapshot server_time');
	is($plan->{'plan'}[0]{'from'}, '500', 'from is the live server_time');
	is($plan->{'summary'}{'ambiguous_keys'}, 0, 'a uuid match never counts the key as ambiguous');
	is($plan->{'summary'}{'matched_uuid'}, 1, 'one uuid match');
}

# --- a unique logical key is the fallback ------------------------------------
{
	my $plan = plan_for(
		[ row(uuid => 'snap', app => 'home', setting => 'a', subsetting => '', device => '', server_time => '100') ],
		[ row(uuid => 'live', app => 'home', setting => 'a', subsetting => undef, device => undef, server_time => '500') ],
		200,
	);
	is(scalar @{ $plan->{'plan'} }, 1, 'a unique key matches when the uuid is absent');
	is($plan->{'plan'}[0]{'match'}, 'key', 'and records the key match');
	is($plan->{'plan'}[0]{'uuid'}, 'live', 'the live uuid is what an apply would write by');
	is($plan->{'plan'}[0]{'to'}, '100', 'to the snapshot time');
	is($plan->{'summary'}{'matched_key'}, 1, 'counted as a key match');
}

# --- an ambiguous key is skipped, not guessed -------------------------------
{
	my $plan = plan_for(
		[ row(uuid => 's1', app => 'home', setting => 'a', server_time => '100'),
		  row(uuid => 's2', app => 'home', setting => 'a', server_time => '900') ],
		[ row(uuid => 'live', app => 'home', setting => 'a', server_time => '500') ],
		200,
	);
	is(scalar @{ $plan->{'plan'} }, 0, 'two snapshot rows with the key plan nothing');
	is($plan->{'summary'}{'ambiguous_keys'}, 1, 'the key is counted as ambiguous');
	is($plan->{'summary'}{'matched_key'}, 0, 'and not as a match');
}

# --- a row before the window is left alone ----------------------------------
{
	my $plan = plan_for(
		[ row(uuid => 'u1', server_time => '100') ],
		[ row(uuid => 'u1', server_time => '150') ],
		200,
	);
	is(scalar @{ $plan->{'plan'} }, 0, 'a live row before the window is not planned');
	is($plan->{'summary'}{'before_window'}, 1, 'and is counted');
}

# --- equal write times are left alone ---------------------------------------
{
	my $plan = plan_for(
		[ row(uuid => 'u1', server_time => '500') ],
		[ row(uuid => 'u1', server_time => '500') ],
		200,
	);
	is(scalar @{ $plan->{'plan'} }, 0, 'an already-equal time is not planned');
	is($plan->{'summary'}{'equal_already'}, 1, 'and is counted');
}

# --- no snapshot row is left alone ------------------------------------------
{
	my $plan = plan_for(
		[],
		[ row(uuid => 'u1', server_time => '500') ],
		200,
	);
	is(scalar @{ $plan->{'plan'} }, 0, 'a live row with no counterpart is not planned');
	is($plan->{'summary'}{'no_counterpart'}, 1, 'and is counted');
}

# --- a value changed since the snapshot is a real write, not a re-stamp ------
{
	my $plan = plan_for(
		[ row(uuid => 'u1', value => 'before', server_time => '100') ],
		[ row(uuid => 'u1', value => 'after', server_time => '500') ],
		200,
	);
	is(scalar @{ $plan->{'plan'} }, 0, 'a row whose value changed is not re-timed');
	is($plan->{'summary'}{'value_changed'}, 1, 'and is counted as a real later write');
}

# --- a row with no uuid cannot be written back safely ------------------------
{
	my $plan = plan_for(
		[ row(uuid => 'u1', server_time => '100') ],
		[ row(uuid => undef, server_time => '500') ],
		200,
	);
	is(scalar @{ $plan->{'plan'} }, 0, 'a live row with no uuid is not planned');
	is($plan->{'summary'}{'no_uuid'}, 1, 'and is counted');
}

# --- the default window is the densest recent hour, not the oldest row -------
{
	my @burst = map { row(uuid => 'b' . $_, server_time => (10000000 + $_ * 10)) } 1 .. 90;
	my @old = map { row(uuid => 'o' . $_, server_time => (100 + $_)) } 1 .. 10;
	is(main::_burst_window_start([ @burst, @old ]), 10000010,
		'the default window starts at the first row of the densest hour');
}
{
	my @spread = map { row(uuid => 's' . $_, server_time => (1000 + $_ * 100000)) } 1 .. 10;
	is(main::_burst_window_start(\@spread), undef,
		'a table with no dense burst asks for --window-start');
}

# --- the summary counts every live row exactly once --------------------------
{
	my $plan = plan_for(
		[
			row(uuid => 'snap-1', app => 'alpha', setting => 'a', subsetting => 's', device => 'd', server_time => '100'),
			row(uuid => 'u2', app => 'alpha', setting => 'b', server_time => '100'),
			row(uuid => 'u3', app => 'beta', setting => 'c', server_time => '100'),
			row(uuid => 'u4', app => 'beta', setting => 'd', server_time => '800'),
			row(uuid => 'amb-1', app => 'delta', setting => 'f', server_time => '100'),
			row(uuid => 'amb-2', app => 'delta', setting => 'f', server_time => '200'),
		],
		[
			row(uuid => 'live-1', app => 'alpha', setting => 'a', subsetting => 's', device => 'd', server_time => '900'),
			row(uuid => 'u2', app => 'alpha', setting => 'b', server_time => '500'),
			row(uuid => 'u3', app => 'beta', setting => 'c', server_time => '150'),
			row(uuid => 'u4', app => 'beta', setting => 'd', server_time => '800'),
			row(uuid => 'live-5', app => 'gamma', setting => 'e', server_time => '900'),
			row(uuid => 'live-6', app => 'delta', setting => 'f', server_time => '900'),
		],
		200,
	);
	is_deeply($plan->{'summary'}, {
		'live_rows' => 6,
		'snapshot_rows' => 6,
		'matched_uuid' => 3,
		'matched_key' => 1,
		'ambiguous_keys' => 1,
		'no_counterpart' => 1,
		'no_uuid' => 0,
		'value_changed' => 0,
		'equal_already' => 1,
		'before_window' => 1,
		'planned' => 2,
	}, 'the summary counts every live row exactly once');
	is_deeply([ map { $_->{'app'} . '/' . $_->{'setting'} } @{ $plan->{'plan'} } ], [ 'alpha/a', 'alpha/b' ],
		'the plan is sorted by app, setting');
	is_deeply([ map { $_->{'match'} } @{ $plan->{'plan'} } ], [ 'key', 'uuid' ],
		'and carries how each row matched');
}

# --- --apply without an explicit --backup is refused before any database read -
{
	my $buf = '';
	open my $fh, '>', \$buf or die "capture: $!";
	my $rc;
	{
		local *STDOUT = $fh;
		$rc = main('--apply');
	}
	close $fh;
	is($rc, 1, '--apply without --backup exits 1');
	like($buf, qr/--apply requires an explicit --backup/, 'and says what is missing');
}

done_testing();
