# Part of perl/President.pl (package President). The utility scheduler and the
# helpers it drives now live here so the scheduler can run in its own process on
# a box without fork as well as in a forked child on Unix (see
# jobs::job_utility_functions and perl/subprocessor_worker.pl).
#
# The bodies are the ones that used to sit in President.pl, unchanged. They read
# $config, $device and $log, which subroutines.pl sets in a worker and the
# President call site stamps before the fork (see manager_starter), plus the
# $gb:: state gb.pl fills in either process.
package President;

use strict;
use warnings;
no warnings qw(uninitialized once);

use Mojo::IOLoop;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Util qw(md5_sum);
use File::Slurp qw(read_file write_file);
use Clone qw(clone);

# The environment the bodies read. On Unix the call site fills these before the
# fork and the child inherits them; in a worker the job fills them from
# subroutines.pl before the module is loaded.
our ($config, $device, $log);

# One schedule for every utility. The old design armed a Mojo::IOLoop->recurring
# timer per utility and gated it on an in-memory "lasted_run": on a machine whose
# servers restart every few minutes that either never fired (a long interval's
# timer was re-armed before it ever elapsed) or fired at once (lasted_run reset
# to undef on every boot). This runs each enabled utility on its own fixed slot
# grid (see below), rebuilding the slot from its persisted last_run on a restart,
# and throttles a failing one to its interval instead of retrying it every tick.
# State lives in memory, so Ctrl+C or a restart-status teardown (both kill this
# process) still stops every utility with it.
our %utility_slots;
our $announced_beat;
# When this tree's utility child came up, and how many due jobs one tick may
# start. A restart makes every slot past due at once (each is rebuilt from its
# persisted last_run), and a job may fork a subprocessor - a copy of this grown
# process as far as the kernel's accounting is concerned. Android charges every
# fork's RSS to the app's uid, so a first pass that starts a dozen jobs looks
# like a gigabyte to the low-memory killer and the app is reaped every few
# seconds. Two at a time drains the backlog without that spike.
our $utility_boot_at;
our $utility_pass_cap = 2;
sub utility_runner() {
	return if $gb::utility_functions_watcher == 0;
	# Give the servers and the WebView their few seconds first: a tree that has
	# just started should not also be starting work.
	return if $utility_boot_at && &subs::rightNow() - $utility_boot_at < 20000;
	# The definer runs from the controller, once. If that call was skipped (the
	# database busy under a land or a backup), every job is left without a
	# subroutine and the loop below then skips all of them in silence: the tree
	# looks alive, nothing syncs, and no line says why. Attach what is missing on
	# the first tick, and say how the tree looked, so the state is healed or at
	# least visible.
	unless ($gb::utility_bare_checked) {
		$gb::utility_bare_checked = 1;
		my $bare = &subs::utility_bare_jobs($gb::timeouts);
		$log->info('utility runner: first tick, ' . scalar(keys %{$gb::timeouts}) . ' slot(s), '
			. scalar(@{$bare}) . ' without a subroutine');
		if (scalar @{$bare}) {
			&utility_definer();
			$log->info('utility runner: attached ' . scalar(@{$bare}) . ' job(s) the controller never reached');
		}
		# Name the numbers that decide the three jobs the house rides on, once per
		# boot: the last silence had every slot populated and every routine attached,
		# so the reason was in these values and nowhere in the logs.
		foreach my $t ( 'remote_machine_sync', 'sync_kick', 'remote_relay' ) {
			my $u = $gb::timeouts->{$t};
			next unless ref $u eq 'HASH';
			my $pool = &subs::batch_interval($gb::timeouts, $t);
			my $span = (defined $pool ? $pool : ($u->{'interval'} || 0)) * 1000;
			my $anchor = $u->{'last_run'} || 0;
			$anchor = $u->{'last_attempt'} if ($u->{'last_attempt'} || 0) > $anchor;
			my $now_at = &subs::rightNow();
			my $due = ($anchor && $span) ? (int($anchor / $span) + 1) * $span : $now_at;
			$log->info('utility runner: ' . $t . ' toggle=' . ($u->{'toggle'} || '-')
				. ' interval=' . ($u->{'interval'} || '-')
				. ' pool=' . (defined $pool ? $pool : '-')
				. ' last_run=' . ($u->{'last_run'} || '-')
				. ' last_attempt=' . ($u->{'last_attempt'} || '-')
				. ' due=' . $due . ' now=' . $now_at . ' overdue=' . (($due <= $now_at) ? 'yes' : 'no')
				. ' subroutine=' . ($u->{'subroutine'} ? 'yes' : 'no'));
		}
	}
	# A short trace of the tick itself: whether the runner is being called at all,
	# and which slots it finds due. A job that starts is logged by its own effect;
	# a tick that starts nothing has no voice, and the house cannot tell a quiet
	# schedule from a dead one.
	$gb::utility_tick_n = ($gb::utility_tick_n || 0) + 1;
	my $trace = $gb::utility_tick_n <= 12;
	# The app's scheduled wake wants to know when the due work is done so it can
	# release the CPU before its 45s backstop. It is written only after a tick
	# that ran nothing, and removed as soon as a job starts, so a reader can tell
	# "everything due has finished" from "the tree is down or still working".
	my $idle_file = &subs::home('~/.president/utility_idle');
	my $pull_file = &subs::home('~/.president/sync_pull');
	# The app's beat marker: a new mtime is this machine's few seconds of being
	# briefly available, which is when peers get told they may pull.
	my $ready_file = &subs::home('~/.president/wake_ready');
	my $ready_at = (-e $ready_file) ? ((stat($ready_file))[9] || 0) : 0;
	my $ran = 0;
	my $next_due;
	my $started = 0;
	my $pending = 0;
	# Resolve the cap once: `$started >= undef` is true in Perl, so a
	# missing or zero cap silently skipped every due job on every tick.
	my $pass_cap = &subs::utility_pass_cap_value($utility_pass_cap);
	# A job's next slot only ever moves by its interval. The old check measured
	# the interval from the last completion, so every run started its interval
	# late by its own duration plus the tick: a five-minute job slipped about
	# three seconds a cycle (twelve minutes a day), and the ten-minute web fetch
	# beneath it carried that slip to every weather pull. Slots are aligned to
	# the epoch, so an hourly job keeps the same minute of the hour and a daily
	# one the same time of day; a restart rebuilds the same slot from last_run.
	foreach my $t ( sort keys %{$gb::timeouts} ) {
		next if $t =~ /^__/;
		my $u = $gb::timeouts->{$t};
		next unless $u->{'subroutine'} && $u->{'toggle'} eq 'on';
		# A job in a batch pool runs on the pool's pace; one outside every pool
		# keeps its own interval.
		my $interval = &subs::batch_interval($gb::timeouts, $t);
		$interval = $u->{'interval'} || 0 unless defined $interval;
		# navigation keeps the machine's pace, but a running appointment whose app
		# asks for fixes more often than that moves the slot up to the app's own
		# rate (floored in subs::navigation_pace) instead of waiting for the slower
		# utility interval.
		if ($t eq 'navigation' && $interval > 0) {
			my $pace = &subs::navigation_pace();
			$interval = $pace if $pace && $pace < $interval;
			# The app's GPS service reads this file for its own sampling and wake
			# interval, so editing the navigation pool in Configure -> Sys moves
			# the phone's pace too. Written only when the value changes.
			my $export = int($pace || $interval);
			if (!defined $gb::gps_pace_exported || $gb::gps_pace_exported != $export) {
				eval { write_file(&subs::home('~/.president/gps_pace'), $export); };
				$gb::gps_pace_exported = $export;
			}
		}
		next if $interval <= 0;
		# read per job: another job in this same pass may have run for minutes
		my $now = &subs::rightNow();
		my $period = $interval * 1000;
		my $slot = $utility_slots{$t};
		if (!$slot || $slot->{'interval'} != $interval) {
			# last_run advances only on success, so a persisted attempt stamp also
			# holds a failing utility to its interval instead of retrying every tick
			my $anchor = $u->{'last_run'} || 0;
			$anchor = $u->{'last_attempt'} if ($u->{'last_attempt'} || 0) > $anchor;
			$slot = $utility_slots{$t} = {
				interval => $interval,
				due => $anchor ? (int($anchor / $period) + 1) * $period : $now,
			};
		}
		# a clock stepped backwards must not park a job longer than its interval
		$slot->{'due'} = $now if $slot->{'due'} > $now + $period;
		# A peer announced that it has new rows and is briefly up: run the sync
		# pass now, through the ordinary path, so it counts as this interval's run
		# (last_run is stamped below) and the panel's dot stays good.
		my $nudged = 0;
		if ($t eq 'remote_machine_sync') {
			my $nudge = &subs::cache_get({ app => '__president', context => 'remote_nudge', subcontext => 'pending' }) || 0;
			if ($nudge && $now - $nudge < 120000) {
				$slot->{'due'} = $now;
				$nudged = 1;
			}
		}
		if ($now < $slot->{'due'}) {
			$next_due = $slot->{'due'} if !defined $next_due || $slot->{'due'} < $next_due;
			next;
		}
		$log->info('utility tick ' . $gb::utility_tick_n . ': ' . $t . ' due (interval ' . $interval . ', started ' . $started . ')') if $trace;
		# This one stays due for the next tick, not this pass: the backlog is
		# drained a couple of jobs at a time (see $utility_pass_cap).
		if ($started >= $pass_cap) {
			$pending = 1;
			$next_due = $now if !defined $next_due || $now < $next_due;
			next;
		}
		$started++;

		if ($nudged) {
			&subs::cache_set({ app => '__president', context => 'remote_nudge', subcontext => 'pending' }, 0);
			$log->info('remote sync: a peer announced new rows; running the pass now');
		}
		$u->{'last_attempt'} = $now;
		# The app's early-release reader must not mistake a running job for an
		# idle tree: drop the marker before the work starts.
		if (!$ran) {
			eval { unlink $idle_file; };
			$ran = 1;
		}
		local $SIG{ALRM} = sub { die "TIMEOUT_EXCEEDED\n" };
		my $success = 0;
		my $effect;
		eval {
			alarm($u->{'timeout'} || 90);
			$effect = $u->{'subroutine'}->();
			$success = 1;
			alarm(0);
		};
		alarm(0);
		if ($@) {
			if ($@ eq "TIMEOUT_EXCEEDED\n") {
				$log->error("Task '$t' took too long and was safely stopped.");
			} else {
				$log->error("Task '$t' threw an error but we caught it: $@");
			}
		}
		if ($success == 1) {
			$u->{'last_run'} = &subs::rightNow();
			# A job may return a short line saying what it did (or that it found
			# nothing new) - the difference a running dot cannot show. Record it, so
			# the panel can show it, and log the line.
			if (defined $effect && !ref $effect && length $effect) {
				$effect =~ s/\s+/ /g;
				$effect = substr($effect, 0, 200);
				$u->{'last_effect'} = $effect;
				$log->info("utility $t: $effect");
			}
		}
		# The next slot is on the grid, not "one interval from when this one
		# finished": a slow run or a busy tick delays this run only, never every
		# run after it. A run that overruns its whole interval skips the slot it
		# missed rather than firing twice.
		my $done = &subs::rightNow();
		$slot->{'due'} = (int($done / $period) + 1) * $period;
	}
	$log->info('utility tick ' . $gb::utility_tick_n . ': ' . scalar(keys %{$gb::timeouts}) . ' slot(s), started ' . $started . ', ran ' . $ran) if $trace;
	# A new beat is also this machine's few seconds of availability. If the rows
	# have moved since the last beat, tell the peers, so they can run their delta
	# pull while we are up. The hold keeps utility_idle unwritten until they have
	# had their chance; a peer that says it needs the rows extends it.
	if ($ready_at > ($gb::announced_beat || 0)) {
		$gb::announced_beat = $ready_at;
		# Tell the house server this machine is awake, even when its tables did
		# not move: the directory is what peers ask when a stored name goes stale.
		&subs::subprocessor(sub { eval { &AddressDirectory::report('wake'); }; }, { name => 'address report' });
		my $digest = &subs::sync_digest_map();
		my $fingerprint = md5_sum(join ';', map {
			my $table = $digest->{$_};
			$_ . ':' . ($table->{'count'} || 0) . ':' . ($table->{'sum'} || 0) . ':' . ($table->{'max'} || 0)
		} sort keys %{$digest});
		my $announced = &subs::cache_get({ app => '__president', context => 'wake', subcontext => 'announced' }) || '';
		if ($fingerprint ne $announced) {
			&subs::cache_set({ app => '__president', context => 'wake', subcontext => 'announced', warranty => '-1d' }, $fingerprint);
			&subs::cache_set({ app => '__president', context => 'wake', subcontext => 'hold', warranty => '-1d' }, &subs::rightNow() + 15000);
			&subs::wake_hold_touch();
			&subs::subprocessor(sub { &subs::remote_available_announce(); }, { name => 'remote availability' });
		}
	}
	# Nothing was due on this tick: everything this wake asked for has finished.
	# The app's receiver reads the mtime and lets the phone sleep early. Write it
	# only when a new beat has arrived since the last mark, not on every idle
	# tick - a five-second write would keep the flash busy for nothing - and only
	# when no job is about to fall due, so a release never skips a beat that is
	# already at the door. A hold defers it while peers pull the announced rows.
	if (!$ran && !$pending && (!defined $next_due || $next_due > &subs::rightNow() + 12000)) {
		my $idle_at = (-e $idle_file) ? ((stat($idle_file))[9] || 0) : 0;
		my $hold = &subs::cache_get({ app => '__president', context => 'wake', subcontext => 'hold' }) || 0;
		# A peer reading rows from us is the one reason a wake may outlive its
		# hold: never let the app sleep in the middle of a pull we are serving.
		my $pull_at = (-e $pull_file) ? ((stat($pull_file))[9] || 0) * 1000 : 0;
		my $serving = ($pull_at && &subs::rightNow() - $pull_at < 15000) ? 1 : 0;
		eval { write_file($idle_file, &subs::rightNow()); } if $ready_at > $idle_at && $hold <= &subs::rightNow() && !$serving;
	}
}

sub utility_functions() {

	$gb::utility_functions_watcher = 1;
	# Pin the cap in this process too, so nothing here can read an
	# undefined one.
	$utility_pass_cap = &subs::utility_pass_cap_value($utility_pass_cap);
	$utility_boot_at = &subs::rightNow();
	print "Starting Alarm Clock\n";

	require './perl/Alarm.pl';
	# Bring up the JawnOS BLE bridge listener (the Tasker replacement).
	&subs::ble_listener_start();
	# Keep a pristine copy of the built-in utilities so newly added ones show up
	# for installs that already have their utilities configured.
	$gb::utility_defaults = clone $gb::timeouts unless $gb::utility_defaults;
	$gb::alarm_running = 0;
	$gb::budget_running = 0;
	$gb::utility_running = 0;
	$gb::housekeeping_running = 0;
	$gb::clothesline_running = 0;

	# The last utility state we persisted, so idle ticks don't keep rewriting the
	# setting and pinging every tab. A package variable, not a `my`: the nested
	# utility_controller below is a named sub, and a `my` here is not shared with it
	# (perl warns "will not stay shared"), so it was a fresh undef on every call -
	# the guard never matched and the blob was rewritten, and every tab pinged,
	# every five seconds.
	our $utility_controls_json;
	# The last navigation toggle the worker stored, so it can name the change in
	# the log (see the store below) - the other half of tracing a job that reads
	# off with nobody touching it.
	our %utility_nav_seen;

	sub utility_controller() {
		my $data = shift;
		my ($db,$database,$sql) = &subs::database_grabber();
		if ($db) {
			my $signatorial = &subs::signatorial_designer();
			my $real_device = &subs::device_setter();
			my $controls = eval { return decode_json &subs::setting_grabber({ app => '__president', setting => 'utility_controller' }) } || {};
			my $dirty = 0;
			if (scalar keys %{$controls} == 0) {
				foreach my $dt ( ( $signatorial, @gb::device_types ) ) {
					$controls->{$dt} = clone $gb::timeouts;
				}
				$dirty = 1;
			}
			# This machine's own row, keyed by its signatorial. The runtime reads no
			# other key, so a missing row is created here.
			unless ($controls->{$signatorial}) {
				$controls->{$signatorial} = clone $gb::timeouts;
				$dirty = 1;
			}
			# pick up any utilities added since this install was configured
			if ($gb::utility_defaults) {
				foreach my $t ( keys %{$gb::utility_defaults} ) {
					unless (exists $controls->{$signatorial}->{$t}) {
						$controls->{$signatorial}->{$t} = clone $gb::utility_defaults->{$t};
						$dirty = 1;
					}
				}
			}
			# The navigation default moved from ten minutes to four when the app's
			# GPS service began writing fixes on its own. A row still carrying the
			# old default with the job switched off takes the new pace; a row the
			# person actually configured keeps its value.
			if ($controls->{$signatorial}->{'navigation'}
				&& ($controls->{$signatorial}->{'navigation'}->{'toggle'} || 'off') eq 'off'
				&& ($controls->{$signatorial}->{'navigation'}->{'interval'} || 0) == 600
				&& !$controls->{$signatorial}->{'__batch_groups'}) {
				$controls->{$signatorial}->{'navigation'}->{'interval'} = 240;
				$dirty = 1;
			}
			# A row that was never edited through Configure is only the built-in
			# defaults cloned in when it was first created. Re-keying the rows from
			# device types to signatorials left the person's switches on the old
			# device-type rows, so a machine silently reverted to the defaults
			# (every job off). When our row is still pristine, take the matching
			# device-type row's switches and intervals and record the change so it
			# sticks and stops being re-derived.
			if (!$controls->{$signatorial}->{'__settings'}->{'last_change'} && $controls->{$real_device}) {
				my $pristine = 1;
				foreach my $t ( keys %{$gb::utility_defaults} ) {
					my $def = ($gb::utility_defaults->{$t}->{'toggle'} || 'off');
					my $cur = ($controls->{$signatorial}->{$t}->{'toggle'} || 'off');
					if ($cur ne $def) { $pristine = 0; last; }
				}
				if ($pristine) {
					foreach my $t ( keys %{$gb::utility_defaults} ) {
						my $legacy = $controls->{$real_device}->{$t} or next;
						foreach my $k ( qw/toggle interval/ ) {
							next unless defined $legacy->{$k};
							$controls->{$signatorial}->{$t}->{$k} = $legacy->{$k};
						}
					}
					$controls->{$signatorial}->{'__settings'}->{'last_change'} = &subs::rightNow();
					$dirty = 1;
				}
			}
			# Prune the vestigial device-type rows: they exist only as the carry-over
			# source just above, so once no machine's row is still pristine they are
			# dead weight carried through every merge. Keep them while any row is
			# unset, so a machine that has not yet run this code can still inherit.
			if (grep { $controls->{$_} } @gb::device_types) {
				my $is_pristine = sub {
					my $row = shift;
					foreach my $t ( keys %{$gb::utility_defaults} ) {
						my $def = ($gb::utility_defaults->{$t}->{'toggle'} || 'off');
						my $cur = ($row->{$t}->{'toggle'} || 'off');
						return 0 if $cur ne $def;
					}
					return 1;
				};
				my $any_pristine = 0;
				foreach my $k ( keys %{$controls} ) {
					next if grep { $_ eq $k } @gb::device_types;
					next unless $k =~ /^[0-9a-f]{32}$/;
					if ($is_pristine->($controls->{$k})) { $any_pristine = 1; last; }
				}
				unless ($any_pristine) {
					foreach my $dt ( @gb::device_types ) {
						if ($controls->{$dt}) { delete $controls->{$dt}; $dirty = 1; }
					}
				}
			}
			# Adopt this machine's row into the runtime on first use (the process
			# starts from gb.pl's built-in defaults, which are not its config) and
			# again whenever the stored row was edited. The old check compared
			# last_change against gb.pl's (absent) value, so a row that was never
			# edited - undef > undef - was never adopted at all.
			my $row_lc = $controls->{$signatorial}->{'__settings'}->{'last_change'} || 0;
			my $cur_lc = $gb::timeouts->{'__settings'}->{'last_change'} || 0;
			if (&subs::utility_row_needs_adoption($gb::utility_adopted, $row_lc, $cur_lc)) {
				foreach my $t ( keys %{$gb::timeouts} ) {
					next if $t =~ /^__/;
					Mojo::IOLoop->remove($gb::timeouts->{$t}->{'loop'}) if $gb::timeouts->{$t}->{'loop'};
				}
				$gb::timeouts = $controls->{$signatorial};
				# `lasted_run` belongs to this process, not to the stored config: it says
				# when this runtime last actually executed a job. The controller copies
				# only last_run/last_attempt/status back into the blob, so the stored
				# value can sit for days. Adoption used to restore it verbatim, and the
				# tunnels watchdog read a days-old marker as "the worker has been stuck
				# for twelve intervals" on the first tick after every boot - resetting
				# every tunnel right when the mesh needed them. Start at now; the
				# watchdog then measures this process's own stall.
				&subs::utility_adopt_runtime($gb::timeouts, &subs::rightNow());
				$gb::utility_adopted = 1;
				$gb::utility_running = 0;
			}
			if ($gb::utility_running == 0) {
				$gb::utility_running = 1;
				&utility_definer();
				# The per-utility timers are gone: utility_runner (driven by the
				# controller tick) does the running, keyed off the persisted last_run.
				# Keep the manager interval floor set once here.
				foreach my $t ( keys %{$gb::timeouts} ) {
					if ($t eq 'manager' && (!$gb::timeouts->{$t}->{'interval'} || $gb::timeouts->{$t}->{'interval'} < (10 * 60)) ) {
						$gb::timeouts->{$t}->{'interval'} = 10 * 60;
					}
				}
				Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

			}
			my $now = &subs::rightNow();
			my $writable = $dirty ? 1 : 0;
			foreach my $t ( keys %{$controls->{$signatorial}} ) {
				# private keys (__settings, __batch_groups) are not jobs
				next if $t =~ /^__/;
				# a utility added to gb.pl since this row was written is carried in the
				# row before the runtime has adopted it, so $gb::timeouts may lack it yet
				next unless $gb::timeouts->{$t};
				if ($gb::timeouts->{$t}->{'toggle'} eq 'on') {
					# A job in a pool has the pool's pace, so that is what its dot is
					# measured against.
					my $effective = &subs::batch_interval($gb::timeouts, $t);
					$effective = $gb::timeouts->{$t}->{'interval'} unless defined $effective && $effective > 0;
					if ($now - $gb::timeouts->{$t}->{'last_run'} > $effective * 5 * 1000) {
						$controls->{$signatorial}->{$t}->{'status'} = 'bad';
						$writable = 1;
					}
					else { 
						$controls->{$signatorial}->{$t}->{'status'} = 'good';
						$writable = 1;
					}
					$controls->{$signatorial}->{$t}->{'last_run'} = $gb::timeouts->{$t}->{'last_run'};
					$controls->{$signatorial}->{$t}->{'last_attempt'} = $gb::timeouts->{$t}->{'last_attempt'};
					$controls->{$signatorial}->{$t}->{'last_effect'} = $gb::timeouts->{$t}->{'last_effect'};
					# `lasted_run` is the runtime's real-execution marker, and the signal
					# the tunnels watchdog measures. It used to stay only in memory and
					# adoption restored whatever the blob held, so the marker never aged
					# past the last write and a stall could not be told from a boot.
					$controls->{$signatorial}->{$t}->{'lasted_run'} = $gb::timeouts->{$t}->{'lasted_run'};
				}
				else {
					$controls->{$signatorial}->{$t}->{'last_run'} = undef;
					$controls->{$signatorial}->{$t}->{'status'} = undef;
				}
			}
			if ($writable == 1) {
				my $jcontrols = encode_json $controls;
				# Only persist + broadcast when something actually changed. This used
				# to rewrite the setting and message every tab several times a minute
				# even when nothing had moved.
				if (!defined $utility_controls_json || $jcontrols ne $utility_controls_json) {
					# Stamp our own row's age before persisting so a peer merging this blob
					# keeps OUR copy of our row over its staler one (merge_database merges
					# the utility blob per key by __settings.last_change), and so the
					# last-run time a peer's card shows tracks us.
					$controls->{$signatorial}->{'__settings'}->{'last_change'} = &subs::rightNow();
					# This row is the runtime's own now: record the stamp just written, or
					# the next tick sees a newer stored value and adopts its own row back
					# over the live one - throwing away the last_run/lasted_run a worker had
					# just set, and re-attaching every job's subroutine, every few seconds.
					&subs::utility_runtime_stamped($gb::timeouts, $controls->{$signatorial}->{'__settings'}->{'last_change'});
					$jcontrols = encode_json $controls;
					my $navnow = $controls->{$signatorial}->{'navigation'}->{'toggle'} // '-';
					if (($utility_nav_seen{$signatorial} // '') ne $navnow) {
						&subs::log_writer('utility worker store: navigation=' . $navnow . ' for ' . substr($signatorial, 0, 8));
						$utility_nav_seen{$signatorial} = $navnow;
					}
					$utility_controls_json = $jcontrols;
					&subs::setting_setter({ app => '__president', setting => 'utility_controller', value => $jcontrols });
					&Websocket::send('tab', { utility_controller => 'yes' });
				}
			}
		}
		else {
			
		}
		return $data;
	}


	my $timer_id;

	$timer_id = Mojo::IOLoop->recurring(5 => sub {


			my $data = &utility_controller();
			&utility_runner();

	});
	&utility_controller();
	&utility_runner();

	$gb::utility_functions_watcher = 1;
	return 1;


	sub utility_definer() {
		$gb::timeouts->{'alarm_haircut'}->{'subroutine'} = sub {
			if ($gb::alarm_haircut_running != 1) {
				$gb::alarm_haircut_running = 1;
				$gb::alarm_haircut_running = 0;
			}
			eval { &Alarm::alarm_haircut() if $config->{'environment'} eq 'production'; };
		};

		$gb::timeouts->{'budget'}->{'subroutine'} = sub {
			if ($gb::budget_running == 0) {
				$gb::budget_running = 1;
				$gb::budget_running = eval { return &Alarm::budget_watcher(); };
			}
		};

		$gb::timeouts->{'sms'}->{'subroutine'} = sub {
			return 'sms: not a mobile' unless $device eq 'mobile';
			my $r = eval { &subs::sms_list_check() };
			my $n = 0;
			$n++ while (defined $r && $r =~ /Phone: /g);
			return $n ? "sms: filed $n new message(s)" : 'sms: ran, no new messages';
		};
		$gb::timeouts->{'backups'}->{'subroutine'} = sub {
			eval {
				my ($db,$database,$sql) = &subs::database_grabber();
				if ($db) {
					my $c = &subs::controller_builder();
					my $suds = &subs::suds_grabber();
					$c->param('reason' => 'backup');
					if ($suds ne '') {
						eval { &subs::backup_now($c); };
					}
				}
			};
		};

		$gb::timeouts->{'clothesline'}->{'subroutine'} = sub {
			eval {
				if ($gb::clothesline_running == 0) {
					$gb::clothesline_running = 1;
					&subs::hang_to_dry();
					$gb::clothesline_running = 0;
				}
			};
		};
		$gb::timeouts->{'tasks'}->{'subroutine'} = sub {
			eval {
				if ($gb::tasks_running == 0) {
					$gb::tasks_running = 1;
					$gb::tasks_running = &subs::task_checker();
				}
			}
		};


		# The auto-OTA sweep. It no-ops unless a device's own Auto OTA box is
		# ticked, and it only pushes a build the staged image can prove it is.
		$gb::timeouts->{'firmware_auto_ota'}->{'subroutine'} = sub {
			my $line = eval { &subs::firmware_auto_ota() };
			return $@ ? 'firmware: sweep failed: ' . $@ : $line;
		};

		$gb::timeouts->{'headless_browser'}->{'subroutine'} = sub {
			eval { &subs::headless_browser(); };
		};

		$gb::timeouts->{'weather_observe'}->{'subroutine'} = sub {
			eval { &subs::weather_observe_tick(); };
		};

		$gb::timeouts->{'telephone_check'}->{'subroutine'} = sub {
			return 'telephone: not a mobile' unless $device eq 'mobile';
			my ($contacts, $calls) = (0, 0);
			eval {
				$contacts = &subs::telephone_contacts_check() || 0;
				$calls = &subs::telephone_call_log_check() || 0;
			};
			return "telephone: $contacts contact change(s), $calls call(s)";
		};

		$gb::timeouts->{'email_sender'}->{'subroutine'} = sub {
			eval { &subs::email_sender(); }
		};

		$gb::timeouts->{'email_receiver'}->{'subroutine'} = sub {
			eval { &subs::email_receiver('auto'); }
		};

		$gb::timeouts->{'tunnels'}->{'subroutine'} = sub {
			eval {
				my $now = &subs::rightNow();
				my $interval = &subs::batch_interval($gb::timeouts, 'tunnels') || $gb::timeouts->{'tunnels'}->{'interval'};
				# utility_runner is the schedule; this second gate only guards a call
				# from elsewhere. Allow the runner's tick of slack, or a call landing a
				# few milliseconds before the interval looked elapsed and skipped a slot.
				if ($now - ($gb::timeouts->{'tunnels'}->{'lasted_run'} || 0) >= ($interval * 1000) - 5000) {
					# An undefined marker is a fresh process, not a stall: a new install
					# has never run this worker, and adoption just set it to now.
					my $duty = &subs::tunnels_stall_duty($gb::timeouts->{'tunnels'}->{'lasted_run'}, $now, $interval);
					my $network = &subs::network_interface_reporter();
					my $addresses;
					my $old_addresses = $gb::timeouts->{'tunnels'}->{'addresses'};
					foreach my $nic ( keys %{$network} ) {
						push @{$addresses}, { ip => $network->{$nic}->{'ip'}, gw => $network->{$nic}->{'gw'} };
						if (!grep { $_->{'ip'} eq $network->{$nic}->{'ip'} && $_->{'gw'} eq $network->{$nic}->{'gw'}  } @{$old_addresses}) {
							# A network change invalidates a borrowed place, but not a fix
							# this machine's own GPS made: a phone's WiFi, cell and VPN
							# addresses can change while it stands still, and clearing
							# the row made the site type fall back to public until the
							# next fix. Only a machine with no GPS of its own loses
							# the place here.
							unless (&subs::navigation_gps_present()) {
								&subs::db_delete('continent', { type => 'temporary', signatorial => &subs::signatorial_designer() });
							}
							$duty = 'restart';
						}
					}
					$gb::timeouts->{'tunnels'}->{'network'} = $network;
					$gb::timeouts->{'tunnels'}->{'addresses'} = $addresses;
					$gb::timeouts->{'tunnels'}->{'lasted_run'} = $now;
					eval { &subs::tunnel_checker({ duty => $duty, interval => $interval }); };
				}
			};
		};
		$gb::timeouts->{'remote_machine_sync'}->{'subroutine'} = sub {
			my $now = &subs::rightNow();
			# No second interval gate here: utility_runner has already decided this slot
			# is due. A gate on `lasted_run` looked equivalent, but adoption stamps that
			# marker to "now" for a fresh process, so the first slot after every restart
			# was skipped - and on a box that restarts often, the pass could be pushed
			# back indefinitely.
			$gb::timeouts->{'remote_machine_sync'}->{'lasted_run'} = $now;
			eval {
				$gb::syncing = 1;
				my $gimme;
				my $lt = localtime( $now / 1000 );
				my $hour = $lt->strftime("%H");
				if ($hour == 4) {
					# One deep three-day reconciliation a night, but not from every
					# machine in the same minute: each machine takes its own slot in
					# the four o'clock hour from its name, so the peers stop asking
					# each other for three days of everything at once (that
					# simultaneous export is what the phone ran out of memory on).
					my $min = int($lt->strftime("%M"));
					my $slot = (unpack('%32C*', &subs::signatorial_designer()) % 5) * 12;
					if (abs($min - $slot) <= 1) {
						# The window is several minutes wide and this job ticks inside
						# it, so without a marker the deep pull started again on every
						# tick - and again after every restart of this machine. Record
						# the night before asking, so a restart during the sync cannot
						# start a second one. The signatorial in the setting name keeps
						# another machine's merged copy from standing for this one.
						my $night = $lt->strftime("%Y-%m-%d");
						my $key = 'remote_gimme_night_' . &subs::signatorial_designer();
						my $done = &subs::setting_grabber({ app => '__president', setting => $key });
						if (($done || '') ne $night) {
							&subs::setting_setter({ app => '__president', setting => $key, value => $night });
							$gimme = '3d';
						}
					}
				}
				&subs::remote_machine_negotiator({ gimme => $gimme });
				$gb::syncing = 0;
			};
		};
		# A kick for a sync that has stalled: clear a pull marker nobody owns,
		# reap an orphaned pull job, drop an inactive hub and nudge the ordinary
		# pass (which still stamps its own last_run). See subs::sync_kick.
		$gb::timeouts->{'sync_kick'}->{'subroutine'} = sub {
			return &subs::sync_kick();
		};
		# The headless relay: drain the queue a job or a CLI leaves (see
		# subs::remote_relay_queue_run), so a machine with no browser can still
		# hand a change on to its peers over the same rail the browser uses.
		$gb::timeouts->{'remote_relay'}->{'subroutine'} = sub {
			my $n = 0;
			eval { $n = &subs::remote_relay_queue_run(); };
			return $n ? "relayed $n" : undef;
		};
		# Battery sampling for the start menu's System view. This task used to
		# clock the utility worker's own CPU time - after a ten-million-iteration
		# spin loop to give the chart a signal - as if it were the machine's load.
		# Those numbers were meaningless, so only the battery readout remains.
		$gb::timeouts->{'htop'}->{'subroutine'} = sub {
			eval {
				my $device = &subs::device_setter();
				# only sample when there is a battery to report
				my $cache_change = ($device eq 'mobile' || -e '/sys/class/power_supply/BAT0/capacity') ? 1 : 0;
				if ($cache_change == 1) {
					my ($db,$database) = &subs::database_grabber();
					if ($db) {
						# PPH and the battery history live in the shared sampler; this
						# view only carries the latest reading for the System card.
						my $sample = &subs::battery_sample();
						my $cpu = { timestamp => &subs::rightNow(), battery => $sample };
						&subs::cache_set({ app => '__president', context => 'htop', subcontext => 'current', warranty => '-1d' }, { current => $cpu });
						&Websocket::send('server', { console => &Websocket::console_command('htopViewer')});
					}
				}
			};
		};

		$gb::timeouts->{'housekeeping'}->{'subroutine'} = sub {
			if ($gb::housekeeping_running == 0) {
				$gb::housekeeping_running = 1;
			#	$gb::housekeeping_running = &Alarm::housekeeping();
			}
		};
		$gb::timeouts->{'warehouse_expiry'}->{'subroutine'} = sub {
			eval {
				if ($gb::warehouse_expiry_running == 0) {
					$gb::warehouse_expiry_running = 1;
					$gb::warehouse_expiry_running = &subs::warehouse_expiry_sweep() ? 0 : 1;
				}
			};
		};
		$gb::timeouts->{'navigation'}->{'subroutine'} = sub {
			my $r = eval {
				&subs::headless_navigation();
			};
			return defined $r && !ref $r && length $r ? $r : undef;
		};

		# The code sync: fetch the authority (or a peer), fast-forward when the
		# tree is clean and strictly behind, and ask for the restart. As a utility
		# it gets the person's own pace and the slow batch's shared wake.
		$gb::timeouts->{'git_sync'}->{'subroutine'} = sub {
			eval { &subs::git_watcher_check(); };
			return undef;
		};

		# Retire agent worktrees whose work is landed. The sweep is
		# conservative on purpose: an unmerged branch, a dirty tree, a stash, an
		# open .shots checkpoint, or a process standing in the worktree is reported
		# WIP and kept, so this is safe while someone is mid-task; a landed, clean
		# one goes at the first sweep that sees it. --apply is required or it would
		# only ever report.
		$gb::timeouts->{'worktree_gc'}->{'subroutine'} = sub {
			my $repo = &subs::home('~/jawnos');
			return undef unless -d "$repo/.git" && -f "$repo/scripts/worktree_gc.pl";
			my $out = qx{cd "$repo" && $^X scripts/worktree_gc.pl --apply 2>&1};
			my ($summary) = $out =~ /^(# (?:removed|would remove).*)$/m;
			return $summary;
		};

		$gb::timeouts->{'manager'}->{'subroutine'} = sub {

		};
	}
}

1;
