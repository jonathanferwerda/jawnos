package subs;

# Evaluation: extracted from subroutines.pl (package subs). Loaded on
# demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Clone qw(clone);
use Data::Dumper;
use Date::Parse;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);
use Fcntl qw(:flock);
use File::Copy;
use File::Find;
use File::Path;
use File::Slurp;
use IPC::Open2;
use JSON::PP ();
use List::Util qw(shuffle);
use MIME::Base64;
use Math::Trig qw(cartesian_to_spherical spherical_to_cartesian great_circle_distance rad2deg deg2rad great_circle_bearing great_circle_direction great_circle_destination);
use Mojo::IOLoop;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Util qw/md5_sum xml_escape html_unescape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use POSIX ();   # mktime: a local-time epoch that still predates 1970
use Text::Unidecode;
use Time::Duration;
use Time::HiRes qw(gettimeofday time);
use Time::Local;
use Time::Piece;
use Unicode::Normalize qw(NFC);

our $device;
our $log;
our $minion;
our $say_quiet;
# The schedule a scope now has, as Minion lists it. The configure page asks per
# app, so the answer is memoised for a few seconds: one query serves a page of
# apps instead of one per app. arrange() calls this right after a write, so the
# memo is short enough that a just-made change is seen on the next repaint.
our %schedule_memo;

# The evaluation may name one relationship it is sure of. This checks the
# naming against what the briefing actually showed - the pair must be there,
# strong and not a daily habit - and then writes it the way the relational app
# itself does: the uuid goes into both apps' sc_ lists, filed under what the
# other app is (its pos, or its mab). A wrong link mislabels an app, so every
# check here is a gate, not a suggestion.
sub evaluation_linker {
	my ($app, $other, $briefing) = @_;
	return undef if !$other || $other eq $app;
	my $evidence;
	foreach my $entry ( @{ $briefing->{'related'} || [] } ) {
		next unless $entry->{'app'} eq $other;
		my $c = $entry->{'correlation'} || {};
		next if $c->{'habit'};
		next unless defined $c->{'r'} && abs($c->{'r'}) >= 0.8;
		$evidence = { r => $c->{'r'} };
		last;
	}
	unless ($evidence) {
		foreach my $entry ( @{ $briefing->{'around'} || [] } ) {
			next unless $entry->{'app'} eq $other || $entry->{'vs_app'} eq $other;
			next if $entry->{'habit'};
			next unless defined $entry->{'r'} && abs($entry->{'r'}) >= 0.8;
			$evidence = { r => $entry->{'r'} };
			last;
		}
	}
	return { app => $other, skipped => 'the pair was not certain in the briefing' } unless $evidence;
	my $rel = &evaluation_relate($app, $other);
	$rel->{'r'} = $evidence->{'r'} if $rel && !$rel->{'skipped'};
	return $rel;
}

# File one relationship, by hand or by the house's own notice: the two apps are
# joined under each other's construct (sc_), which is what the relational window
# shows and what the evaluation reads back as a link. Idempotent, and it drops
# the two buckets from the relational cache so the window redraws them.
sub evaluation_relate {
	my ($app, $other) = @_;
	return undef if !$other || $other eq $app;
	my $mine = &subs::settings_grabber({ app => $app, benign => 1 });
	my $theirs = &subs::settings_grabber({ app => $other, benign => 1 });
	my $my_construct = $mine->{'pos'} || $mine->{'mab'};
	my $their_construct = $theirs->{'pos'} || $theirs->{'mab'};
	return { app => $other, skipped => 'one of them has no construct to file under' }
		unless $my_construct && $their_construct && $mine->{'uuid'} && $theirs->{'uuid'};
	my $sc = eval { return decode_json($mine->{ 'sc_' . $their_construct }) } || [];
	return { app => $other, skipped => 'already related' }
		if grep { $_ eq $theirs->{'uuid'} } @{$sc};
	push @{$sc}, $theirs->{'uuid'};
	@{$sc} = grep { $_ ne 'all' } @{$sc};
	my $bc = eval { return decode_json($theirs->{ 'sc_' . $my_construct }) } || [];
	push @{$bc}, $mine->{'uuid'} unless grep { $_ eq $mine->{'uuid'} } @{$bc};
	@{$bc} = grep { $_ ne 'all' } @{$bc};
	&subs::setting_setter({ app => $app, setting => 'sc_' . $their_construct, value => encode_json($sc) });
	&subs::setting_setter({ app => $other, setting => 'sc_' . $my_construct, value => encode_json($bc) });
	return { app => $other, construct => $their_construct, their_construct => $my_construct };
}

# Assemble the relationships the house is sure enough of, without a hand on each:
# the event scan's strongest neighbours of one app are filed straight away, so
# drawing them is the exception rather than the rule. The bar is high (a strong
# lift over chance, seen often) and an already-related pair is skipped, so a run
# only ever adds and never churns.
sub evaluation_autolink {
	my ($app, $since, $cap, $candidates) = @_;
	return [] unless $app && $app ne '__president';
	$cap ||= 8;
	$since ||= &subs::rightNow() - 60 * 86400000;
	$candidates ||= &subs::evaluation_context_scan($app, $since, 30 * 60000, 16);
	my @filed;
	foreach my $entry ( @{$candidates} ) {
		last if scalar @filed >= $cap;
		next unless ($entry->{'lift'} + 0) >= 3 && ($entry->{'hits'} + 0) >= 5;
		my $rel = &evaluation_relate($app, $entry->{'app'});
		next if !$rel || $rel->{'skipped'};
		$rel->{'lift'} = $entry->{'lift'};
		$rel->{'hits'} = $entry->{'hits'};
		push @filed, $rel;
	}
	return \@filed;
}

# The relational window reads the settings rows directly; a change to either end
# of a relationship is already in those rows when the next board is built.

# Undo a relationship, both ways, whoever made it. Symmetric with
# evaluation_relate so a link the house filed and one drawn by hand are taken
# apart the same way.
sub evaluation_unrelate {
	my ($app, $other) = @_;
	return { app => $other, skipped => 'nothing to undo' } if !$other || $other eq $app;
	my $mine = &subs::settings_grabber({ app => $app, benign => 1 });
	my $theirs = &subs::settings_grabber({ app => $other, benign => 1 });
	my $my_construct = $mine->{'pos'} || $mine->{'mab'};
	my $their_construct = $theirs->{'pos'} || $theirs->{'mab'};
	return { app => $other, skipped => 'one of them has no construct' }
		unless $my_construct && $their_construct && $mine->{'uuid'} && $theirs->{'uuid'};
	my $sc = eval { return decode_json($mine->{ 'sc_' . $their_construct }) } || [];
	my $bc = eval { return decode_json($theirs->{ 'sc_' . $my_construct }) } || [];
	return { app => $other, skipped => 'not related' }
		unless grep { $_ eq $theirs->{'uuid'} } @{$sc} or grep { $_ eq $mine->{'uuid'} } @{$bc};
	@{$sc} = grep { $_ ne $theirs->{'uuid'} } @{$sc};
	@{$bc} = grep { $_ ne $mine->{'uuid'} } @{$bc};
	&subs::setting_setter({ app => $app, setting => 'sc_' . $their_construct, value => encode_json($sc) });
	&subs::setting_setter({ app => $other, setting => 'sc_' . $my_construct, value => encode_json($bc) });
	return { app => $other, removed => 1 };
}

# Take the relationships back that no longer hold up, whoever drew them: for
# each app this one is related to, keep it only if the house can still see why -
# the event scan still puts it nearby, or a condition it runs under is still
# tied to the app - and drop the rest. Nothing is judged until the app has run
# enough to be read, and only a few go in a run, so a link is removed when it
# has truly gone quiet and not on a single thin night.
sub evaluation_prune {
	my ($app, $since, $cap) = @_;
	return [] unless $app && $app ne '__president';
	$cap ||= 4;
	$since ||= &subs::rightNow() - 60 * 86400000;
	my $count = &subs::db_query('select count(*) as n from appointments where app = ? and cast(timestamp as integer) >= ?', $app, $since)->hashes->[0]->{'n'} + 0;
	return [] if $count < 10;
	my $mine = &subs::settings_grabber({ app => $app, benign => 1 });
	my @related;
	foreach my $key ( grep { /^sc_/ } keys %{$mine} ) {
		my $uuids = eval { return decode_json $mine->{$key} } || [];
		foreach my $u ( @{$uuids} ) {
			next if !$u || $u eq 'all';
			my $s = &subs::settings_grabber({ uuid => $u });
			push @related, $s->{'app'} if $s->{'app'};
		}
	}
	return [] unless scalar @related;
	my %lift = map { $_->{'app'} => ($_->{'lift'} + 0) } @{ &subs::evaluation_context_scan($app, $since, 30 * 60000, 24) };
	my %cond = map { $_->{'app'} => 1 } grep { abs($_->{'z'}) >= 1.5 && (($_->{'confidence'} // '') ne 'around') } @{ &subs::evaluation_conditions($app, $since, 24) };
	my @removed;
	foreach my $other ( @related ) {
		last if scalar @removed >= $cap;
		next if ($lift{$other} // 0) >= 1.5;
		next if $cond{$other};
		my $r = &evaluation_unrelate($app, $other);
		push @removed, $other if $r && $r->{'removed'};
	}
	return \@removed;
}

# the machine whose worker runs the nightly evaluations; blank means every
# machine that reconciles keeps its own queue
sub evaluation_machine {
	return &subs::setting_grabber({ app => '__president', setting => 'evaluation_machine' }) || '';
}

# The nightly evaluation is one Minion schedule per scope, named for the scope.
# The schedule is the mechanism, but it does not survive the launcher: jawn
# clears ~/.president at startup. So the wish lives in a setting too, and the
# worker restores the schedules from the settings at boot - see
# nightly_evaluation_reconcile. Minion reads cron expressions in UTC, and
# 0 7 * * * is the small hours of the house: 3am EDT, 2am EST.
sub nightly_evaluation_name {
	my ($app) = @_;
	$app = '__president' unless $app && $app ne '';
	return 'nightly_evaluation_' . $app;
}

sub nightly_evaluation_schedule {
	my ($app) = @_;
	$app = '__president' unless $app && $app ne '';
	my $now = time;
	return $schedule_memo{$app}->{'schedule'} if exists $schedule_memo{$app} && $schedule_memo{$app}->{'at'} > $now - 3;
	my $listed = eval { return &subs::minion_grabber()->list_schedules(0, 1, { names => [ &subs::nightly_evaluation_name($app) ] }) } || {};
	my $schedule = ($listed->{'schedules'} || [])->[0];
	$schedule_memo{$app} = { at => $now, schedule => $schedule };
	return $schedule;
}

# the days the nightly runs, as a comma list of cron weekdays (0 is Sunday);
# nothing picked means every night
sub nightly_evaluation_days {
	my ($app) = @_;
	$app = '__president' unless $app && $app ne '';
	my $days = &subs::setting_grabber({ app => $app, setting => 'nightly_evaluation_days' });
	# '0' is Sunday and is a value, not nothing: "|| ''" would drop it
	$days = '' unless defined $days;
	return [ grep { /^[0-6]$/ } split /\s*,\s*/, $days ];
}

# The cadence a scope runs on its own: off, hourly, daily, weekly, monthly,
# yearly, or each_run (evaluated whenever the appointment itself runs). The old
# nightly checkbox is read as daily, so a house that has not been reconfigured
# keeps its nights. The timed cadences become a cron the worker carries out;
# each_run has no schedule and rides the appointment writer instead.
sub evaluation_cadence {
	my ($app) = @_;
	$app = '__president' unless $app && $app ne '';
	my $c = &subs::setting_grabber({ app => $app, setting => 'evaluation_cadence' });
	return $c if defined $c && grep { $_ eq $c } qw/off hourly daily weekly monthly yearly each_run/;
	return 'daily' if (&subs::setting_grabber({ app => $app, setting => 'nightly_evaluation' }) || '') eq 'on';
	return 'off';
}

# Minion reads cron in UTC, and 0 7 * * ... is the small hours of the house
# (3am EDT, 2am EST). The days select narrows daily and weekly; nothing picked
# means every night for daily and Sunday for weekly. Each scope gets its own
# minute from its name, so the whole house does not hand the model twenty runs
# at the same instant (which is what made a nightly batch time out).
sub evaluation_schedule_cron {
	my ($app, $cadence) = @_;
	$cadence = &subs::evaluation_cadence($app) unless defined $cadence;
	return undef unless defined $cadence && $cadence ne 'off' && $cadence ne 'each_run';
	# an explicit "none" clears the daily/weekly schedule; a blank value is the
	# old wish for every night, and monthly/yearly/hourly ignore the days anyway
	my $scope = ($app && $app ne '') ? $app : '__president';
	my $days_setting = &subs::setting_grabber({ app => $scope, setting => 'nightly_evaluation_days' });
	return undef if defined $days_setting && $days_setting =~ /^\s*none\s*$/i && ($cadence eq 'daily' || $cadence eq 'weekly');
	my @days = @{ &subs::nightly_evaluation_days($app) };
	my $minute = 0;
	if ($scope ne '__president') {
		$minute += ord($_) for split //, $scope;
		$minute %= 60;
	}
	return "$minute * * * *" if $cadence eq 'hourly';
	return "$minute 7 * * " . (scalar @days ? join(',', @days) : '*') if $cadence eq 'daily';
	return "$minute 7 * * " . (scalar @days ? join(',', @days) : '0') if $cadence eq 'weekly';
	return "$minute 7 1 * *" if $cadence eq 'monthly';
	return "$minute 7 1 1 *" if $cadence eq 'yearly';
	return undef;
}

# How often a scope wants a report, in milliseconds. Zero for the cadences with
# no interval to catch up (off, each_run).
sub evaluation_cadence_interval {
	my ($cadence) = @_;
	return 3600 * 1000 if $cadence eq 'hourly';
	return 86400 * 1000 if $cadence eq 'daily';
	return 7 * 86400000 if $cadence eq 'weekly';
	return 30 * 86400000 if $cadence eq 'monthly';
	return 365 * 86400000 if $cadence eq 'yearly';
	return 0;
}

# carry out one scope's cadence: schedule its cron, or clear it (off, each_run)
sub evaluation_schedule_arrange {
	my ($app) = @_;
	$app = '__president' unless $app && $app ne '';
	my $minion = &subs::minion_grabber();
	my $name = &subs::nightly_evaluation_name($app);
	# Only the server keeps an automatic schedule. Anywhere else the wish is
	# stored (the cadence setting is shared) and the server's reconcile turns it
	# into a schedule; a machine that used to have one loses it here.
	unless (&evaluation_auto_here()) {
		$minion->unschedule($name);
		delete $schedule_memo{$app};
		return;
	}
	my $cron = &subs::evaluation_schedule_cron($app);
	if ($cron) {
		# one retry, in case the model was only briefly unreachable
		$minion->schedule($name, $cron, 'appointment_evaluation', [ { app => $app } ], { attempts => 2 });
	}
	else {
		$minion->unschedule($name);
	}
	# a change here is a change the next read should see, not the memo
	delete $schedule_memo{$app};
}

# the controls write both halves: the setting remembers the wish, the schedule
# carries it out, and the answer reports the schedule that now exists
sub evaluation_cadence_apply {
	my ($app, $cadence) = @_;
	$app = '__president' unless $app && $app ne '';
	$cadence = 'off' unless defined $cadence && grep { $_ eq $cadence } qw/off hourly daily weekly monthly yearly each_run/;
	&subs::setting_setter({ app => $app, setting => 'evaluation_cadence', value => $cadence });
	&subs::evaluation_schedule_arrange($app);
	return &subs::nightly_evaluation_schedule($app);
}

# the old on/off checkbox, kept for anything that still speaks it
sub nightly_evaluation_apply {
	my ($app, $on) = @_;
	return &subs::evaluation_cadence_apply($app, $on ? 'daily' : 'off');
}

# Every run fires the evaluation when the scope's cadence is each_run. A Minion
# lock throttles a burst of runs to one evaluation per window (300s), so a
# morning of records does not queue a morning of model calls. Only a completed
# run counts - a one-shot ('usual') or the end of a start/stop pair ('stop') -
# and never a spawned child.
# Where an evaluation may start by itself.
#
# A run re-reads the whole history across five windows and then holds a model
# call. Measured on the phone that is seconds of gathering and minutes of one
# core once the call is under way, which is the wrong work for a handheld that
# is usually on battery. Automatic runs are the server's; a phone, tablet or
# laptop still runs one when a person presses Evaluate (that path calls
# evaluation_agent directly), it just never starts one on its own. The controls
# still record a cadence anywhere - the setting is house-wide and the server's
# reconcile is what turns it into a schedule.
sub evaluation_auto_here {
	return (&subs::device_setter() eq 'server') ? 1 : 0;
}

sub evaluation_run_trigger {
	my ($app, $appt) = @_;
	return unless $app && $app ne '__president';
	return unless ref $appt eq 'HASH';
	my $type = $appt->{'type'} || '';
	return unless $type eq 'usual' || $type eq 'stop';
	return if $appt->{'source_uuid'};
	return unless &evaluation_auto_here();
	return unless &subs::evaluation_cadence($app) eq 'each_run';
	my $minion = &subs::minion_grabber();
	return unless $minion->lock('evaluation_each_run_' . $app, 300);
	$minion->enqueue('appointment_evaluation' => [ { app => $app, each_run => 1 } ] => { attempts => 2 });
	return 1;
}

# The queue under ~/.president does not outlive the launcher, but the settings
# do. At boot this reads the wishes back, puts the schedules that are wanted
# back, and drops any nightly schedule the settings no longer ask for. Held in
# an eval because a boot that cannot reach the queue or the settings must not
# take the worker down with it.
sub nightly_evaluation_reconcile {
	eval {
		# Automatic evaluation is the server's job (see evaluation_auto_here). A
		# machine that is not the server keeps its queue empty of these schedules,
		# so a wake cannot hand a handheld a core for minutes; the catch-up below
		# is skipped for the same reason.
		unless (&evaluation_auto_here()) {
			my $minion = &subs::minion_grabber();
			my $listed = $minion->list_schedules(0, 1000) || {};
			foreach my $sch ( @{ $listed->{'schedules'} || [] } ) {
				next unless ($sch->{'name'} // '') =~ /^nightly_evaluation_/;
				$minion->unschedule($sch->{'name'});
			}
			return;
		}
		# Every machine that reaches here is the server. It keeps the schedules.
		# every scope ever given a cadence, or the old nightly checkbox: the
		# effective cadence decides which of them wants a schedule
		my %scope;
		foreach my $setting ( qw/evaluation_cadence nightly_evaluation/ ) {
			my $rows = &subs::db_select('settings', undef, { setting => $setting, device => &subs::device_setter() })->hashes || [];
			foreach my $row ( @{$rows} ) {
				$scope{ ($row->{'app'} && $row->{'app'} ne '') ? $row->{'app'} : '__president' } = 1;
			}
		}
		my %wanted;
		foreach my $app ( keys %scope ) {
			my $cadence = &subs::evaluation_cadence($app);
			$wanted{$app} = 1 if $cadence ne 'off' && $cadence ne 'each_run';
		}
		my $listed = &subs::minion_grabber()->list_schedules(0, 1000) || {};
		my %present;
		foreach my $sch ( @{ $listed->{'schedules'} || [] } ) {
			next unless $sch->{'name'} =~ /^nightly_evaluation_/;
			$present{$sch->{'name'}} = 1;
		}
		foreach my $app ( keys %wanted ) {
			# schedule() is an upsert by name (and keeping the same expression
			# keeps the firing time), so asking for every wanted scope also
			# retunes one whose cadence changed while nobody was looking
			&subs::evaluation_schedule_arrange($app);
		}
		foreach my $name ( keys %present ) {
			my ($app) = $name =~ /^nightly_evaluation_(.*)$/;
			next if $wanted{$app};
			&subs::minion_grabber()->unschedule($name);
		}
		# The queue under ~/.president is wiped at boot, so schedule() computes
		# the next future occurrence and a run that came due while the machine was
		# asleep or restarting is never made up. A scope whose last stored report
		# is older than its cadence gets one run now, spread over a few minutes so
		# a wake does not start every scope at once. Only a machine that can reach
		# the evaluation agent queues the catch-up; an unequipped phone stays out.
		if (&subs::evaluation_agent_ready()) {
			my $catchup_minion = &subs::minion_grabber();
			my $now_ms = &subs::rightNow();
			my $boot_ms = &subs::ai_job_boot_ms();
			my $queued = 0;
			foreach my $app ( sort keys %wanted ) {
				my $cadence = &subs::evaluation_cadence($app);
				my $interval = &subs::evaluation_cadence_interval($cadence);
				next unless $interval;
				my $key = 'eval:' . $app;
				my $row = eval { &subs::db_select('ai_jobs', undef, { job => $key })->hashes->[0] };
				my $dead_own = 0;
				if ($row && (($row->{'at'} || 0) + 0) > ($now_ms - 30 * 60 * 1000)) {
					# A claim this machine left behind before the last boot is not a
					# live run; a crashed night must not block its own catch-up.
					$dead_own = $boot_ms
						&& (($row->{'owner'} // '') eq &subs::ai_house_me())
						&& (($row->{'state'} // '') eq 'running')
						&& (($row->{'at'} || 0) + 0) < $boot_ms;
					next unless $dead_own;
				}
				my $report = eval { decode_json(&subs::setting_grabber({ app => $app, setting => 'evaluation_report' }) || '') } || {};
				my $last = ($report->{'timestamp'} || 0) + 0;
				next if $last && ($now_ms - $last) < $interval * 1.15;
				# one machine queues the catch-up: the same election the job uses,
				# so a ready phone and a ready laptop do not both enqueue every scope.
				# A dead claim of our own is not a live runner, so we queue it ourselves.
				my $chosen = $dead_own ? &subs::ai_house_me() : eval { &subs::ai_job_runner($key, 10 * 60 * 1000, 1, 0) };
				next unless defined $chosen && $chosen eq &subs::ai_house_me();
				# the five-minute reconcile must not queue the same catch-up again
				# while the first one is still waiting behind the worker's delay; hold
				# the lock for the cadence (capped at six hours) so a failed run is not
				# retried every half hour
				my $lock_for = int($interval / 1000);
				$lock_for = 6 * 3600 if $lock_for > 6 * 3600;
				next unless $catchup_minion->lock('evaluation_catchup_' . $app, $lock_for);
				$catchup_minion->enqueue('appointment_evaluation' => [ { app => $app, catchup => 1 } ] => { attempts => 2, delay => 15 * $queued });
				$queued++;
			}
		}
	};
	return;
}

# The worker half of the nightly checkbox: the same agent the evaluate button
# runs, so a fresh report is in the cache before the house wakes.
sub appointment_evaluation_job {
	my ($job, $data) = @_;
	my $app = $data->{'app'} || '__president';
	# A job queued before this machine stopped scheduling (a restart, or a policy
	# change with one still waiting behind the worker's delay) must not run here.
	unless (&evaluation_auto_here()) {
		$job->finish({ app => $app, skipped => 'automatic evaluations run on the server' });
		return;
	}
	my $key = 'eval:' . $app;
	my $me = &ai_house_me();
	my $here = &subs::setting_grabber({ app => 'me', setting => 'my_name' }) || '';
	my $each_run = $data->{'each_run'} ? 1 : 0;
	my $dispatch_mode = 0;
	my $settings = &subs::settings_grabber({ app => 'mail', settings => [ 'eval_assistant' ] });
	my $model = $settings->{'eval_assistant'};
	# A machine that cannot reach the evaluation agent must not claim the night,
	# queue a dispatch, or leave a failed note: that is how a tablet with no model
	# ended up announcing an error every hour. Probe before any claim, so only a
	# working machine becomes a candidate and a capable peer is asked instead.
	unless (&subs::evaluation_agent_ready()) {
		$log->info('evaluation ' . $app . ': no reachable evaluation agent on this machine; standing down') if defined $log;
		$job->finish({ app => $app, skipped => 'no evaluation agent reachable here' });
		return;
	}
	if (!$each_run) {
		if (&ai_house_server_known()) {
			# The server is the dispatcher: a worker runs only the assignment
			# addressed to it. A partition that cannot see the server has no fresh
			# assignment and stands down, so the split house does not run twice.
			$dispatch_mode = 1;
			unless (&ai_job_dispatch_claim($key)) {
				# A retry of this machine's own crashed attempt, or a dispatcher
				# that is asleep/restarting/unequipped. The own claim is taken back
				# first; otherwise a ready worker may take the run when no live
				# assignment exists.
				if (&ai_job_own_claim($key, $me)) {
					# keep the dispatch lease: settle marks a dispatch failed
				}
				elsif (&ai_job_may_run($key, 10 * 60 * 1000, 1, 0)) {
					$dispatch_mode = 0;
				}
				else {
					$job->finish({ app => $app, skipped => 'not addressed to this machine, or already running' });
					return;
				}
			}
		}
		else {
			# no server in the house: a majority of the roster elects, and a
			# minority partition stands down rather than run the report again
			unless (&ai_house_quorum_ok(1)) {
				&subs::evaluation_run_record($app, { timestamp => &subs::rightNow(), machine => $here, model => '', outcome => 'skipped', note => 'no quorum in this partition' });
				$job->finish({ app => $app, skipped => 'no quorum for the evaluation' });
				return;
			}
			# The named machine is a preference within the quorum; the stable hash
			# spreads the rest, and a machine that goes quiet drops out.
			my $named = &subs::evaluation_machine();
			my $named_ready = length($named) && &ai_house_machine_ready($named, 1);
			if ($named && $named ne $me && $named_ready) {
				$job->finish({ app => $app, skipped => 'the chosen evaluation machine is on it' });
				return;
			}
			if ($named && $named eq $me && $named_ready) {
				&ai_job_claim($key);
			}
			elsif (!&ai_job_may_run($key, 10 * 60 * 1000, 1, 0)) {
				# the election found a live claim; if it is this machine's own
				# crashed attempt, the retry takes it back
				unless (&ai_job_own_claim($key, $me)) {
					$job->finish({ app => $app, skipped => 'another machine runs this evaluation' });
					return;
				}
			}
		}
	}
	else {
		# an each_run evaluation belongs to the appointment that ran, on the
		# machine that recorded it; it is not a scheduled dispatch
		&ai_job_claim($key);
	}
	# the claim written above stays a 'running' lease while the model works, so a
	# long report does not open the job to a second machine halfway through. The
	# run is background work: a model failure is recorded, but must not speak on
	# whichever device happened to carry it.
	local $subs::say_quiet = 1;
	my $report = &subs::evaluation_agent($app);
	if ($report->{'error'}) {
		&ai_job_settle($key, $me, $dispatch_mode, 'failed');
		&subs::evaluation_run_record($app, { timestamp => &subs::rightNow(), machine => $here, model => $model, outcome => 'failed', note => substr($report->{'error'}, 0, 120) });
		$job->fail($report->{'error'});
		return;
	}
	&subs::evaluation_run_record($app, { timestamp => &subs::rightNow(), machine => $here, model => $model, outcome => 'ran' });
	&ai_job_note($key);
	$job->finish({ app => $app, timestamp => $report->{'timestamp'} });
}

# Close a claim that could not be carried. A dispatched assignment is marked
# failed so the dispatcher stops addressing it and the next cadence reassigns;
# an elected run releases the row so a retry or a peer can take it.
sub ai_job_settle {
	my ($job, $me, $dispatch_mode, $state) = @_;
	return unless length($job // '');
	if ($dispatch_mode) {
		eval { &subs::db_update('ai_jobs', { state => ($state || 'failed') }, { job => $job, owner => $me }) };
	}
	else {
		eval { &subs::db_delete('ai_jobs', { job => $job, owner => $me }) };
	}
}

# A durable note of what each night did, per scope: which machine ran it, when,
# with which model, and - when the run stepped aside - why. The queue is
# per-machine and the wish is shared, so without it the only witness to a night
# that did nothing was the absence of a report.
sub evaluation_run_record {
	my ($app, $entry) = @_;
	$app = '__president' unless $app && $app ne '';
	my $log = eval { return decode_json(&subs::setting_grabber({ app => $app, setting => 'evaluation_runs' }) || '') } || [];
	unshift @{$log}, $entry;
	splice(@{$log}, 30) if scalar @{$log} > 30;
	&subs::setting_setter({ app => $app, setting => 'evaluation_runs', value => encode_json($log) });
	return $log;
}

# Text to an image: the Plat Image-generation model, and the bytes it answered
# with. Cloudflare's @cf text-to-image models run at the run/{model} endpoint and
# answer with the picture itself; any other model goes through the chat layer,
# whose image parts are collected here. Returns ($bytes, $mime, $error).
sub ai_text_to_image {
	my ($data) = @_;
	my $prompt = $data->{'prompt'} || '';
	return (undef, undef, 'no prompt') unless length $prompt;
	my @key_settings = &subs::ai_key_settings();
	my $settings = &subs::settings_grabber({ app => 'mail', settings => [ 'text_to_image_assistant', 'cloudflare_account', 'cloudflare_token', @key_settings ] });
	my $model = $data->{'model'} || $settings->{'text_to_image_assistant'};
	return (undef, undef, 'no image model is set (Configure, Plat, Image generation)') unless $model;
	my $ua = Mojo::UserAgent->new(connect_timeout => 10, inactivity_timeout => 300, request_timeout => 600);
	if ($model =~ /^\@cf/) {
		my $account = $settings->{'cloudflare_account'};
		my $token = eval { &subs::note_decrypter(&subs::suds_grabber(), $settings->{'cloudflare_token'}) } || $settings->{'cloudflare_token'};
		return (undef, undef, 'no Cloudflare account is set (Configure, Plat, Provider access)') unless $account;
		return (undef, undef, 'no Cloudflare token is set (Configure, Plat, Provider access)') unless $token;
		my $url = 'https://api.cloudflare.com/client/v4/accounts/' . $account . '/ai/run/' . $model;
		my $payload = { prompt => $prompt };
		$payload->{'negative_prompt'} = $data->{'negative_prompt'} if $data->{'negative_prompt'};
		$payload->{'width'} = int($data->{'width'}) if $data->{'width'};
		$payload->{'height'} = int($data->{'height'}) if $data->{'height'};
		my $tx = $ua->post($url => {
			'Authorization' => 'Bearer ' . $token,
			'Content-Type'  => 'application/json'
		} => json => $payload);
		if ($tx->error) {
			my $detail = '';
			if (my $res = $tx->res) { $detail = ' ' . substr(($res->body || ''), 0, 300); }
			return (undef, undef, 'could not reach Cloudflare: ' . $tx->error->{'message'} . $detail);
		}
		my $res = $tx->res;
		unless ($res->is_success) {
			my $body = $res->body || '';
			if ($res->code == 402 || $body =~ /(insufficient|credit|billing|payment|balance|quota)/i) {
				&ai_bucket_mark_unavailable(&ai_model_bucket($model), $res->code . ' ' . $body);
			}
			else {
				my $retry_after = $res->headers->header('retry-after');
				my ($pause, $why) = &ai_limit_pause($res->code, $retry_after, $body);
				&ai_bucket_mark_unavailable(&ai_model_bucket($model), $res->code . ' ' . ($why || ''), $pause) if defined $pause;
			}
			return (undef, undef, 'the image model answered ' . $res->code . ': ' . substr($body, 0, 200));
		}
		my $binary = $res->body;
		return (undef, undef, 'the image model returned nothing') unless defined $binary && length $binary;
		return ($binary, 'image/png', undef);
	}
	# any other model: whatever the chat layer hands back as an image part (a
	# multimodal model that draws, or a URL to fetch). The chat layer has no size
	# field, so a canvas is asked for in the prompt - a model that draws listens to
	# it or ignores it, and a locally hosted one is where this path is headed
	my $ask = $prompt;
	if ($data->{'width'} && $data->{'height'}) {
		$ask .= ' Produce the image at ' . int($data->{'width'}) . ' by ' . int($data->{'height'}) . ' pixels.';
	}
	my ($parts, $err) = &ai_chat_parts($model, [ { role => 'user', content => $ask } ]);
	return (undef, undef, $err || 'the model returned nothing readable') if $err;
	foreach my $part ( @{$parts || []} ) {
		next unless ($part->{'type'} || '') eq 'image';
		if ($part->{'data'}) {
			my $bytes = MIME::Base64::decode_base64($part->{'data'});
			return ($bytes, $part->{'mime'} || 'image/png', undef) if $bytes && length $bytes;
		}
		elsif ($part->{'url'}) {
			my $fetch = $ua->get($part->{'url'});
			my $bytes = $fetch->res->body;
			return ($bytes, $fetch->res->headers->content_type || 'image/png', undef) if $bytes && length $bytes;
		}
	}
	return (undef, undef, 'the model answered without an image');
}

# The audio/video twin of ai_text_to_image's generic path: the chosen generation
# model is asked for the media and the first part of the right kind it returns is
# the answer. Pen uses this so a described audio/video prompt is filed by the
# agent that takes care of that kind.
sub ai_text_to_media {
	my ($kind, $data) = @_;
	my $prompt = $data->{'prompt'} || '';
	return (undef, undef, 'no prompt') unless length $prompt;
	my $setting = ($kind eq 'audio' ? 'text_to_audio_assistant' : 'text_to_video_assistant');
	my $label = ($kind eq 'audio' ? 'Audio' : 'Video');
	my $model = $data->{'model'} || &subs::setting_grabber({ app => 'mail', setting => $setting });
	return (undef, undef, "no $kind model is set (Configure, Plat, $label generation)") unless $model;
	# a dedicated video provider (Google Veo) runs a job on its side and is polled,
	# not asked as a chat turn; the chat layer is the fallback for everything else
	return &ai_text_to_video_veo($model, $prompt, $data) if $kind eq 'video' && $model =~ /^(?:google:)?veo/i;
	my $ua = Mojo::UserAgent->new(connect_timeout => 10, inactivity_timeout => 300, request_timeout => 600);
	my $ask = $prompt;
	if ($kind eq 'video' && $data->{'width'} && $data->{'height'}) {
		$ask .= ' Produce the video at ' . int($data->{'width'}) . ' by ' . int($data->{'height'}) . ' pixels.';
	}
	my ($parts, $err) = &ai_chat_parts($model, [ { role => 'user', content => $ask } ]);
	return (undef, undef, $err || 'the model returned nothing readable') if $err;
	foreach my $part ( @{$parts || []} ) {
		next unless ($part->{'type'} || '') eq $kind;
		if ($part->{'data'}) {
			my $bytes = MIME::Base64::decode_base64($part->{'data'});
			return ($bytes, $part->{'mime'}, undef) if $bytes && length $bytes;
		}
		elsif ($part->{'url'}) {
			my $fetch = $ua->get($part->{'url'});
			my $bytes = $fetch->res->body;
			return ($bytes, $fetch->res->headers->content_type || '', undef) if $bytes && length $bytes;
		}
	}
	return (undef, undef, "the model answered without $kind");
}

# Google Veo, the video-generation job: submit a prompt, poll the long-running
# operation until it is done, then fetch the file it names. Returns
# ($bytes, $mime, $error), the same shape as the other generators.
sub ai_text_to_video_veo {
	my ($model, $prompt, $data) = @_;
	my @key_settings = &subs::ai_key_settings();
	my $settings = &subs::settings_grabber({ app => 'mail', settings => [ @key_settings ] });
	my $key = eval { &subs::note_decrypter(&subs::suds_grabber(), $settings->{'google_key'}) } || $settings->{'google_key'};
	return (undef, undef, 'no Google key is set (Configure, Plat, Provider access)') unless $key;
	my $name = $model; $name =~ s/^google://;
	my $ua = Mojo::UserAgent->new(connect_timeout => 10, inactivity_timeout => 120, request_timeout => 600);
	my $base = 'https://generativelanguage.googleapis.com/v1beta';
	my $payload = { instances => [ { prompt => $prompt } ] };
	$payload->{'parameters'}->{'aspectRatio'} = $data->{'aspect_ratio'} if $data->{'aspect_ratio'};
	my $submit = $ua->post($base . '/models/' . $name . ':predictLongRunning?key=' . url_escape($key) => json => $payload);
	return (undef, undef, 'could not reach the video model: ' . $submit->error->{'message'}) if $submit->error;
	my $body = eval { return $submit->res->json } || {};
	my $op = $body->{'name'};
	return (undef, undef, 'the video model did not start a job: ' . substr($submit->res->body || '', 0, 200)) unless $op;
	# poll the operation; a Veo render is minutes, so give it a long leash
	my $video_uri;
	for (my $i = 0; $i < 90; $i++) {
		sleep 5 if $i;
		my $poll = $ua->get($base . '/' . $op . '?key=' . url_escape($key));
		next if $poll->error;
		my $pb = eval { return $poll->res->json } || {};
		next unless $pb->{'done'};
		if ($pb->{'error'}) { return (undef, undef, 'the video model failed: ' . ($pb->{'error'}->{'message'} || 'unknown')); }
		$video_uri = $pb->{'response'}->{'generateVideoResponse'}->{'generatedSamples'}->[0]->{'video'}->{'uri'}
			|| $pb->{'response'}->{'generatedVideos'}->[0]->{'video'}->{'uri'};
		last;
	}
	return (undef, undef, 'the video model did not finish in time') unless $video_uri;
	my $sep = (index($video_uri, '?') >= 0) ? '&' : '?';
	my $fetch = $ua->get($video_uri . $sep . 'key=' . url_escape($key));
	return (undef, undef, 'could not download the video: ' . $fetch->error->{'message'}) if $fetch->error;
	my $bytes = $fetch->res->body;
	return (undef, undef, 'the video model returned nothing') unless defined $bytes && length $bytes;
	return ($bytes, $fetch->res->headers->content_type || 'video/mp4', undef);
}

1;
