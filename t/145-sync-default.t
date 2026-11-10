# tests-for: perl/gb/01_state_and_defaults.pl perl/utility_jobs.pl lib/JawnOS/Domain/Records2.pm
# covers:    the built-in utility switches a fresh machine starts from - the sync
#            pass runs on its own timer so a box with no LAN presence still syncs -
#            and the task leaves the scheduling to utility_runner.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

require JawnOS::Domain::Records2;

# The defaults are what a machine clones into its utility row when that row does
# not exist yet, so a job switched off here stays off on a new box until someone
# opens Configure and finds it.
my $root = root();
require "$root/perl/gb/01_state_and_defaults.pl";

my $sync = $gb::timeouts->{'remote_machine_sync'};
ok(ref $sync eq 'HASH', 'the sync pass is a declared utility');
is($sync->{'toggle'}, 'on',
	'the sync pass starts on: a machine with no LAN presence wake (a VM, a LXC reached over the tailnet) still syncs');

# The pace is the fast pool's, not the job's own interval, so the switch turning
# on does not mean a copy every two minutes.
is($sync->{'group'}, 'fast', 'the sync pass runs in the fast pool');
ok(($sync->{'timeout'} || 0) >= 900, 'its slot is long enough for a full snapshot merge');

# An unrelated switch keeps its old default; this change is scoped to sync.
is($gb::timeouts->{'navigation'}->{'toggle'}, 'off', 'navigation still starts off');

# The worktree sweep is housekeeping, not a test: it runs daily and it is on by
# default, because nothing else ever removes an agent worktree.
my $gc = $gb::timeouts->{'worktree_gc'};
ok(ref $gc eq 'HASH', 'the worktree sweep is a declared utility');
is($gc->{'toggle'}, 'on', 'the sweep starts on: a landed worktree is scratch');
is($gc->{'group'}, 'daily', 'the sweep runs in the daily pool');
my ($gc_task) = read_file("$root/perl/utility_jobs.pl") =~ /(\$gb::timeouts->\{'worktree_gc'\}->\{'subroutine'\} = sub \{.*?\n\t\t\};)/s;
ok(defined $gc_task && length $gc_task, 'the sweep task is declared in utility_jobs.pl');
like($gc_task // '', qr/worktree_gc\.pl/, 'it runs the sweep script');
like($gc_task // '', qr/--apply/, 'in apply mode, not report-only');

# utility_runner decides when a slot is due. A second gate inside the task on
# `lasted_run` looked equivalent, but adoption stamps that marker to "now" for a
# fresh process, so the first slot after every restart was skipped - and a box
# that restarts often could defer the pass indefinitely.
my $president = read_file("$root/perl/utility_jobs.pl");
my ($sync_task) = $president =~ /(\$gb::timeouts->\{'remote_machine_sync'\}->\{'subroutine'\} = sub \{.*?\n\t\t\};)/s;
ok(defined $sync_task && length $sync_task, 'the sync task is declared in utility_jobs.pl');
unlike($sync_task, qr/lasted_run'\}\s*>=\s*\(\$interval \* 1000\)/,
	'the sync task does not gate itself on lasted_run: the runner slot is the schedule');

# --- the Dev panel's check cadence -----------------------------------------
# The code watcher's pace is per machine: the setting may be 30 seconds or the
# hour, and anything else must fall back to the hour rather than make a bot.
{
	my %store;
	no warnings 'redefine';
	local *subs::setting_grabber = sub {
		my ($q) = @_;
		return $store{'device'} if defined $q->{'device'};
		return $store{'any'};
	};
	local *subs::signatorial_designer = sub { return 'machine' };
	$store{'device'} = '30'; $store{'any'} = '30';
	is(&subs::sync_update_interval_get('machine'), 30, 'a 30-second choice is read for that machine');
	is(&subs::sync_update_interval_get(), 30, 'the watcher reads this machine\'s own row');
	$store{'device'} = '3600'; $store{'any'} = '3600';
	is(&subs::sync_update_interval_get('machine'), 3600, 'and the hour is read');
	$store{'device'} = ''; $store{'any'} = '30';
	is(&subs::sync_update_interval_get('machine'), 30, 'a missing per-machine row falls back to the current one');
	$store{'device'} = '60'; $store{'any'} = '60';
	is(&subs::sync_update_interval_get('machine'), 3600, 'an unknown value falls back to the hour');
}

my $jobs = read_file("$root/perl/utility_jobs.pl");
my ($git_interval) = $jobs =~ /(if \(\$t eq 'git_sync'\).*?\n\t\t\})/s;
ok(defined $git_interval && length $git_interval, 'the runner overrides the pool for git_sync');
like($git_interval // '', qr/sync_update_interval_get/, 'from the Dev panel setting');
my @cadence = $jobs =~ /sync_update_interval_get\b/g;
ok(scalar @cadence >= 2, 'the runner and the status dot both read it');

done_testing();
