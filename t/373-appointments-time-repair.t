# tests-for: scripts/appointments_time_repair.pl
# covers:    appointments_time_plan - uuid matching, the window, equality, a row
#           changed since the snapshot, the local-bookkeeping exemption, the
#           summary counts, and the default window's largest recent cluster

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;

# appointments_time_repair puts back the appointments.server_time a bad backfill
# stamped across 41k rows. The pure planner is where the decisions live, so it is
# driven with synthetic arrays here: no snapshot is decrypted and the live
# database is never opened. The CLI's own refusal is checked separately, before
# it reads a database.

my $root = "$FindBin::Bin/..";
require "$root/scripts/appointments_time_repair.pl";

sub row {
	my (%a) = @_;
	return {
		'uuid'           => $a{'uuid'},
		'app'            => $a{'app'} // 'vape',
		'type'           => $a{'type'} // 'stop',
		'timestamp'      => $a{'timestamp'} // '100',
		'stop_timestamp' => $a{'stop_timestamp'} // '',
		'duration'       => $a{'duration'} // '60',
		'status'         => $a{'status'} // '',
		'data'           => $a{'data'} // '',
		'seen'           => exists $a{'seen'} ? $a{'seen'} : '',
		'stop_seen'      => exists $a{'stop_seen'} ? $a{'stop_seen'} : '',
		'ost'            => exists $a{'ost'} ? $a{'ost'} : '',
		'server_time'    => $a{'server_time'} // '1000',
	};
}

sub plan_for {
	my ($old, $live, $window) = @_;
	return main::appointments_time_plan($old, $live, { 'window_start' => $window });
}

# --- a uuid match plans the snapshot's time -----------------------------------
{
	my $plan = plan_for(
		[ row(uuid => 'u1', server_time => '100') ],
		[ row(uuid => 'u1', server_time => '500') ],
		200,
	);
	is(scalar @{ $plan->{'plan'} }, 1, 'one pure re-stamp is planned');
	is($plan->{'plan'}[0]{'to'}, '100', 'to is the snapshot server_time');
	is($plan->{'plan'}[0]{'from'}, '500', 'from is the live server_time');
	is($plan->{'summary'}{'matched_uuid'}, 1, 'one uuid match');
	is($plan->{'summary'}{'planned'}, 1, 'and one planned row');
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

# --- a row genuinely written since the snapshot is not re-timed -------------
{
	my $plan = plan_for(
		[ row(uuid => 'u1', timestamp => '100', server_time => '100') ],
		[ row(uuid => 'u1', timestamp => '400', server_time => '500') ],
		200,
	);
	is(scalar @{ $plan->{'plan'} }, 0, 'a changed event time is a real write, not a re-stamp');
	is($plan->{'summary'}{'changed_since'}, 1, 'and is counted as changed');
}
{
	my $plan = plan_for(
		[ row(uuid => 'u1', status => '', server_time => '100') ],
		[ row(uuid => 'u1', status => 'deleting', server_time => '500') ],
		200,
	);
	is(scalar @{ $plan->{'plan'} }, 0, 'a changed status is a real write');
	is($plan->{'summary'}{'changed_since'}, 1, 'and is counted as changed');
}
{
	my $plan = plan_for(
		[ row(uuid => 'u1', data => '{"n":1}', server_time => '100') ],
		[ row(uuid => 'u1', data => '{"n":2}', server_time => '500') ],
		200,
	);
	is(scalar @{ $plan->{'plan'} }, 0, 'a changed measure payload is a real write');
}

# --- local delivery/machine bookkeeping alone is still a pure re-stamp ------
{
	my $plan = plan_for(
		[ row(uuid => 'u1', seen => '', stop_seen => '', ost => '', server_time => '100') ],
		[ row(uuid => 'u1', seen => 'yes', stop_seen => 'yes', ost => '1795000000000', server_time => '500') ],
		200,
	);
	is(scalar @{ $plan->{'plan'} }, 1, 'seen/stop_seen/ost are not row meaning');
	is($plan->{'summary'}{'planned'}, 1, 'so the row is still restored');
}

# --- the default window is the largest recent cluster, not the oldest row ----
{
	my @stamp = map { row(uuid => 'x' . $_, server_time => 12345678) } 1 .. 90;
	is(main::_burst_window_start(\@stamp), 12345678,
		'a repeated exact stamp is the incident start');
}
{
	my @burst = map { row(uuid => 'b' . $_, server_time => (10000000 + $_ * 10)) } 1 .. 90;
	my @old = map { row(uuid => 'o' . $_, server_time => (100 + $_)) } 1 .. 10;
	is(main::_burst_window_start([ @burst, @old ]), 10000010,
		'the default window starts at the first row of the largest cluster');
}
{
	my @spread = map { row(uuid => 's' . $_, server_time => (1000 + $_ * 100000)) } 1 .. 10;
	is(main::_burst_window_start(\@spread), undef,
		'a table with no dense cluster asks for --window-start');
}
{
	# A per-row backfill can take hours: sub-hour gaps stay one cluster.
	my @slow = map { row(uuid => 'm' . $_, server_time => (10000000 + ($_ - 1) * 600000)) } 1 .. 60;
	my @old = map { row(uuid => 'o2' . $_, server_time => (100 + $_)) } 1 .. 2;
	is(main::_burst_window_start([ @slow, @old ]), 10000000,
		'a multi-hour re-stamp is still one cluster');
}

# --- the summary counts every live row exactly once --------------------------
{
	my $plan = plan_for(
		[
			row(uuid => 'u2', app => 'alpha', type => 'stop', server_time => '100'),
			row(uuid => 'u3', app => 'beta', type => 'usual', server_time => '100'),
			row(uuid => 'u4', app => 'beta', type => 'start', server_time => '800'),
		],
		[
			row(uuid => 'u2', app => 'alpha', type => 'stop', server_time => '500'),
			row(uuid => 'u3', app => 'beta', type => 'usual', server_time => '150'),
			row(uuid => 'u4', app => 'beta', type => 'start', server_time => '800'),
			row(uuid => 'live-5', app => 'gamma', type => 'stop', server_time => '900'),
			row(uuid => undef, app => 'delta', type => 'stop', server_time => '900'),
		],
		200,
	);
	is_deeply($plan->{'summary'}, {
		'live_rows' => 5,
		'snapshot_rows' => 3,
		'matched_uuid' => 3,
		'no_counterpart' => 1,
		'no_uuid' => 1,
		'changed_since' => 0,
		'equal_already' => 1,
		'before_window' => 1,
		'planned' => 1,
	}, 'the summary counts every live row exactly once');
	is_deeply([ map { $_->{'app'} . '/' . $_->{'type'} } @{ $plan->{'plan'} } ], ['alpha/stop'],
		'the plan carries the one row still to restore');
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
