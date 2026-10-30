use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

# `subs::utility_adopt_runtime` and `subs::tunnels_stall_duty` decide what a
# stored utility row means to a fresh process.
#
# Regression: `lasted_run` is process state, but it rides the stored
# utility_controller blob, and the controller never copies the live value back
# (it persists last_run/last_attempt/last_effect/status only). Adoption restored
# the stored value verbatim - 103 hours old on one machine - and the tunnels
# watchdog read that as "the worker has been stuck for twelve intervals", so it
# reset every tunnel on the first tick after every boot. An absent marker is a
# fresh process, not a stall.

my $now = JawnOSTest::ts(2026, 10, 30, 12, 0, 0);
my $day = 24 * 60 * 60 * 1000;

my $jobs = {
	__settings => { last_change => $now - $day },
	__batch_groups => [ { id => 'fast', seconds => 120 } ],
	tunnels => {
		toggle => 'on',
		interval => 120,
		last_run => $now - 300000,
		lasted_run => $now - (103 * 60 * 60 * 1000),
		network => { lo => { ip => '127.0.0.1' } },
		addresses => [ { ip => '127.0.0.1', gw => '' } ],
	},
	navigation => { toggle => 'on', interval => 240 },
	manager => 'not a job',
};

my $returned = subs::utility_adopt_runtime($jobs, $now);
is($returned, $jobs, 'returns the job table it was given');
is($jobs->{'tunnels'}->{'lasted_run'}, $now, 'adoption resets a stale runtime marker');
is($jobs->{'navigation'}->{'lasted_run'}, $now, 'adoption sets a missing runtime marker');
is($jobs->{'tunnels'}->{'last_run'}, $now - 300000, 'the schedule stamp is left alone');
is($jobs->{'tunnels'}->{'interval'}, 120, 'the interval is left alone');
is($jobs->{'tunnels'}->{'toggle'}, 'on', 'the switch is left alone');
is_deeply($jobs->{'tunnels'}->{'addresses'}, [ { ip => '127.0.0.1', gw => '' } ], 'the network addresses are left alone');
ok(ref $jobs->{'tunnels'}->{'network'} eq 'HASH', 'the network map is left alone');
ok(!exists $jobs->{'__settings'}->{'lasted_run'}, 'private keys are not touched');
is_deeply($jobs->{'__batch_groups'}, [ { id => 'fast', seconds => 120 } ], 'batch pools are not touched');
is($jobs->{'manager'}, 'not a job', 'non-hash entries are not touched');

# A fresh install has no marker at all.
is(subs::tunnels_stall_duty(undef, $now, 120), undef, 'no marker means not stalled');
is(subs::tunnels_stall_duty($now - $day, $now, 120), 'restart', 'a day-old marker is a stall');
is(subs::tunnels_stall_duty($now - (23 * 60 * 1000), $now, 120), undef, 'a recent marker is not a stall');
is(subs::tunnels_stall_duty($now - (25 * 60 * 1000), $now, 120), 'restart', 'past twelve intervals is a stall');
is(subs::tunnels_stall_duty($now - (60 * 60 * 1000), $now, 600), undef, 'the bound follows the interval');
is(subs::tunnels_stall_duty($now - (3 * 60 * 60 * 1000), $now, 600), 'restart', 'a longer interval moves the bound too');
is(subs::tunnels_stall_duty('nonsense', $now, 120), undef, 'an unreadable marker is not a stall');

done_testing();
