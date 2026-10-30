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
# utility_controller blob. Adoption restored the stored value verbatim - 103
# hours old on one machine - and the tunnels watchdog read that as "the worker
# has been stuck for twelve intervals", so it reset every tunnel on the first
# tick after every boot. A marker from a previous process is meaningless now;
# a marker this process wrote must be kept, or the periodic re-adoption would
# reset the clock every few seconds and no gate would ever elapse.

my $now = JawnOSTest::ts(2026, 10, 30, 12, 0, 0);
my $process_start = $now - (10 * 60 * 1000);   # this process has been up 10 min
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
	remote_machine_sync => { toggle => 'on', interval => 120, lasted_run => $now - 30000 },
	manager => 'not a job',
};

my $returned = subs::utility_adopt_runtime($jobs, $now, $process_start);
is($returned, $jobs, 'returns the job table it was given');
is($jobs->{'tunnels'}->{'lasted_run'}, $now, 'a marker from a previous process starts at now');
is($jobs->{'navigation'}->{'lasted_run'}, $now, 'a missing marker starts at now');
is($jobs->{'remote_machine_sync'}->{'lasted_run'}, $now - 30000, 'a marker this process wrote is kept');
is($jobs->{'tunnels'}->{'last_run'}, $now - 300000, 'the schedule stamp is left alone');
is($jobs->{'tunnels'}->{'interval'}, 120, 'the interval is left alone');
is($jobs->{'tunnels'}->{'toggle'}, 'on', 'the switch is left alone');
is_deeply($jobs->{'tunnels'}->{'addresses'}, [ { ip => '127.0.0.1', gw => '' } ], 'the network addresses are left alone');
ok(ref $jobs->{'tunnels'}->{'network'} eq 'HASH', 'the network map is left alone');
ok(!exists $jobs->{'__settings'}->{'lasted_run'}, 'private keys are not touched');
is_deeply($jobs->{'__batch_groups'}, [ { id => 'fast', seconds => 120 } ], 'batch pools are not touched');
is($jobs->{'manager'}, 'not a job', 'non-hash entries are not touched');

# Re-adoption in the same process must not reset a marker it just advanced.
my $again = subs::utility_adopt_runtime($jobs, $now + 5000, $process_start);
is($again->{'tunnels'}->{'lasted_run'}, $now, 'a second adoption keeps this process marker');

# Adoption is for boot and for someone else's edit, not for our own persist.
is(subs::utility_row_needs_adoption(0, 10, 10), 1, 'boot always adopts');
is(subs::utility_row_needs_adoption(1, 11, 10), 1, 'a newer stored row is adopted');
is(subs::utility_row_needs_adoption(1, 10, 10), 0, 'the row we just wrote is not adopted back');
is(subs::utility_row_needs_adoption(1, 9, 10), 0, 'an older stored row is not adopted');
is(subs::utility_row_needs_adoption(1, undef, undef), 0, 'an unstamped row is not adopted');

my $runtime = { __settings => { last_change => 5 }, tunnels => { toggle => 'on' } };
is(subs::utility_runtime_stamped($runtime, 99), 99, 'stamping returns the stamp');
is($runtime->{'__settings'}->{'last_change'}, 99, 'the runtime records the stamp it persisted');
is($runtime->{'tunnels'}->{'toggle'}, 'on', 'stamping leaves the jobs alone');
my $stampless = {};
subs::utility_runtime_stamped($stampless, 7);
is($stampless->{'__settings'}->{'last_change'}, 7, 'stamping creates __settings when absent');

# A fresh install has no marker at all.
is(subs::tunnels_stall_duty(undef, $now, 120), undef, 'no marker means not stalled');
is(subs::tunnels_stall_duty($now - $day, $now, 120), 'restart', 'a day-old marker is a stall');
is(subs::tunnels_stall_duty($now - (23 * 60 * 1000), $now, 120), undef, 'a recent marker is not a stall');
is(subs::tunnels_stall_duty($now - (25 * 60 * 1000), $now, 120), 'restart', 'past twelve intervals is a stall');
is(subs::tunnels_stall_duty($now - (60 * 60 * 1000), $now, 600), undef, 'the bound follows the interval');
is(subs::tunnels_stall_duty($now - (3 * 60 * 60 * 1000), $now, 600), 'restart', 'a longer interval moves the bound too');
is(subs::tunnels_stall_duty('nonsense', $now, 120), undef, 'an unreadable marker is not a stall');

done_testing();
