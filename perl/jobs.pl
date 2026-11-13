package jobs;

# The blocking subprocessor jobs President starts, as named subs.
#
# Each body used to be a closure in perl/President.pl. President still passes
# the same sub to subs::subprocessor, so a box with fork runs it in a child
# exactly as before; on a box without fork (Windows, JAWNOS_PORTABLE) the
# subprocessor starts the entry below by name in its own process
# (lib/JawnOS/Platform/Job.pm + perl/subprocessor_worker.pl).
#
# A name is a domain key: subprocessor_warranty_for and
# subprocessor_heartbeat_for are keyed by the exact string the call site uses,
# so a table entry here must match it letter for letter.
#
# UNIX_ONLY names are still registered (they run in a forked child on Unix) but
# a no-fork box logs that it skipped them instead of spawning a process that
# could not do anything: they drive sshd, a BLE radio, or a native whisper
# server.

use strict;
use warnings;
no warnings 'once';

use File::Slurp qw(read_file write_file);
use Mojo::IOLoop;

our %JOB;
our %UNIX_ONLY = (
	'sshd watcher' => 1,
	'ble adopt scan' => 1,
	'whisper server' => 1,
);

# `utility functions` is not in this table: it is an ordinary named job now
# (jobs::job_utility_functions), so its timers run in its own process with its
# own loop. What remains here is genuinely Unix-only.
our %NO_FORK_SKIP = (
	%UNIX_ONLY,
);

# The staged app releases (the APKs) reconcile on a slower tick: ask each
# reachable peer what it holds and pull the newest in, so every device becomes
# a holder and a source. A first pass soon after boot, then every five minutes.
# Speech is always its own process: a request may call say_it (Leave says
# goodbye) and still have to answer, and the body resets its event loop before
# it starts. On Unix say_it forks; on a box without fork this entry is what
# the subprocessor starts by name, with the words in JAWNOS_JOB_ARGS.
sub job_say_it {
	my ($args) = @_;
	&subs::say_speak($args->{'text'}, $args->{'voice'});
}

# The watch's spoken answer and the board-command senders dial a bridge or a
# board in the request path, so each is always its own process. The bodies live
# beside the request code (Say.pm, Notify.pm) and start with a loop reset; on a
# box without fork these entries are what keeps that reset out of the caller.
sub job_watch_reply_wifi {
	my ($args) = @_;
	&subs::watch_reply_wifi($args);
}

sub job_watch_reply_audio {
	my ($args) = @_;
	&subs::watch_reply_audio($args);
}

sub job_embedded_toggle_send {
	my ($args) = @_;
	&subs::embedded_toggle_send($args);
}

sub job_embedded_toggle_refresh {
	my ($args) = @_;
	&subs::embedded_toggle_refresh($args);
}

sub job_app_release_sync {
	my ($args) = @_;
	sleep 45;
	while (1) {
		&subs::subprocessor_heartbeat();
		eval { &subs::app_release_sync(); };
		sleep 300;
	}
}

# The slow background passes used to be one forked copy of the whole tree each.
# None is time-critical at the minute level, so one process runs them in order
# on their own slots.
sub job_slow_loops {
	my ($args) = @_;
	# crew.pl is a script President loads separately; a worker starts with the
	# library only, so load it before taking coderefs to its subs.
	require './perl/crew.pl';
	my @slow_loops = (
		{ name => 'crew advert sync', first => 45, every => 300, run => \&crew::advert_sync },
		{ name => 'crew queue tick', first => 20, every => 60, run => \&crew::tick },
		{ name => 'crest member cosign', first => 90, every => 300, run => sub { &subs::crest_member_cosig_sync(); } },
		{ name => 'ollama models sync', first => 60, every => 600, run => sub { &subs::ollama_models_sync(); } },
		{ name => 'error watch', first => 25, every => 60, run => sub { &subs::error_watch_tick(); } },
		{ name => 'guide watch', first => 40, every => 60, run => sub { &subs::guide_watch_tick(); } },
		{ name => 'records watch', first => 120, every => 7200, run => sub { &subs::records_watch_tick(); } },
		{ name => 'ai balance', first => 30, every => 600, run => sub { &subs::ai_balance_refresh(); } },
		# The thresholds set under the chart: an hour over the limit, or a runway
		# under it, becomes one Handbook note per crossing. The ledger's prune
		# rides the same turn.
		{ name => 'ai balance watch', first => 95, every => 1800, run => sub { &subs::ai_alert_tick(); } },
		{ name => 'crypto rates', first => 35, every => 1800, run => sub { &subs::crypto_rates_refresh(); } },
		# Interac e-Transfer has no API: the notification letters are the record.
		# A few-minute pass stages one for a person, or records it when the house
		# asked for that and the match is unmistakable.
		{ name => 'interac watch', first => 75, every => 300, run => sub { &subs::pay_interac_scan(); } },
		# A website assigned to an app is a session: a native browser posts its
		# site spans every half minute, and the mapped app runs while they keep
		# arriving. The tick stops the session at the last span's end after a
		# quiet gap, so closing the tab or switching apps ends the appointment.
		{ name => 'internet sites', first => 10, every => 10, run => sub { &subs::internet_site_appointment_tick(); } },
		# A game on the Gou is a session too: launch.json says it is running and
		# the input daemon's activity stamp says when a control was last touched,
		# so a paused game is not counted as play time.
		{ name => 'game play', first => 15, every => 10, run => sub { &subs::game_play_appointment_tick(); } },
		# A session whose machine died leaves a row open - a Gou battery, a
		# killed browser, a manager that was down. Close it at its last heartbeat.
		{ name => 'session housekeeping', first => 30, every => 60, run => sub { &subs::session_housekeeping_tick(); } },
		# The cable changed: apply the plan saved for the source now in use. The
		# tick is idempotent (the applied row makes it a no-op) so a machine on
		# mains pays one battery read per minute and no sysfs write.
		{ name => 'power watch', first => 25, every => 60, run => sub { &subs::power_plan_tick(); } },
	);
	my $started = time;
	my %due = map { $_->{'name'} => $started + $_->{'first'} } @slow_loops;
	while (1) {
		&subs::subprocessor_heartbeat();
		my $now = time;
		foreach my $loop ( @slow_loops ) {
			next if $now < $due{ $loop->{'name'} };
			$due{ $loop->{'name'} } = $now + $loop->{'every'};
			eval { $loop->{'run'}->(); };
		}
		sleep 5;
	}
}

# The start menu's System card: every peer's battery and the embedded boards
# the house can see. Two minutes is the house pace, but a System card on screen
# asks for quick passes (levels_fast_request): sleep in slices and answer it
# within seconds, so a phone plugged in a moment ago updates.
sub job_house_levels {
	my ($args) = @_;
	sleep 20;
	while (1) {
		&subs::subprocessor_heartbeat();
		my $fast = &subs::cache_get({ app => '__president', context => 'levels', subcontext => 'fast' }) || 0;
		my $wanted = ($fast && &subs::rightNow() - $fast < 90000) ? 1 : 0;
		eval { &subs::house_levels_sync({ fast => $wanted }); };
		my $synced = &subs::rightNow();
		while (1) {
			sleep 5;
			my $now = &subs::rightNow();
			last if $now - $synced >= 120000;
			$fast = &subs::cache_get({ app => '__president', context => 'levels', subcontext => 'fast' }) || 0;
			last if $fast && $now - $fast < 90000 && $now - $synced >= 8000;
		}
	}
}

# mDNS is how a device names itself the moment it joins: fold what the local
# network advertises (_jawnos._tcp, plus a printer on _ipp._tcp) into this
# machine's device row on a short tick.
sub job_device_mdns_sync {
	my ($args) = @_;
	sleep 12;
	while (1) {
		&subs::subprocessor_heartbeat();
		eval { &subs::device_mdns_sync(); };
		sleep 15;
	}
}

# The printer's document feeder, watched on the machine that owns the scanner.
# A receipt dropped in is a loaded edge: the house gets one notice and an open
# Market window claims the scan. The state is stored, so paper left in the tray
# warns once; removing it and loading the next is a new edge.
sub job_adf_receipt_watch {
	my ($args) = @_;
	sleep 25;
	while (1) {
		&subs::subprocessor_heartbeat();
		eval { &subs::adf_receipt_watch(); };
		sleep 15;
	}
}

# Advertise this House machine on the LAN. An embedded device browses
# _jawnos-house._tcp when the homebase it was handed stops answering, so it
# can move to another computer/mobile/server that is actually up.
sub job_house_advertise {
	my ($args) = @_;
	sleep 5;
	while (1) {
		&subs::subprocessor_heartbeat();
		eval { &subs::house_advertise_supervise(); };
		sleep 30;
	}
}

# sshd: the login service the house dials on 8022. Kept up here, in President,
# once per tree; the heartbeat is what makes it survive a worker restart.
sub job_sshd_watcher {
	my ($args) = @_;
	while (1) {
		&subs::subprocessor_heartbeat();
		eval { &subs::sshd_start(); };
		sleep 60;
	}
}

# A peer joining a network says so with a small signed broadcast on that LAN.
# The listener refreshes the peer's address on every machine that hears it and
# wakes the reconnector, so the mesh resumes within seconds.
sub job_lan_presence_beacon {
	my ($args) = @_;
	sleep 6;
	while (1) {
		&subs::subprocessor_heartbeat();
		eval { &subs::lan_presence_send(); };
		sleep 5;
	}
}

sub job_lan_presence_listener {
	my ($args) = @_;
	sleep 3;
	while (1) {
		&subs::subprocessor_heartbeat();
		eval { &subs::lan_presence_listen(); };
		sleep 5;
	}
}

# The listener only leaves a cache stamp; this loop runs the mesh sync in its
# own process so the listener is never blocked behind a pull.
sub job_lan_mesh_wake {
	my ($args) = @_;
	sleep 7;
	while (1) {
		&subs::subprocessor_heartbeat();
		# A wake is the phone's start/stop reaching the mesh: poll twice a
		# second so the websockets come back without a visible pause.
		select(undef, undef, undef, 0.5);
		my $wake = &subs::cache_get({ app => '__president', context => 'lan', subcontext => 'wake' });
		next unless $wake;
		&subs::cache_delete({ app => '__president', context => 'lan', subcontext => 'wake' });
		eval { &subs::remote_machine_negotiator({}); };
	}
}

# A device that has never been on WiFi cannot be named by mDNS, so scan the
# radio for a board whose address is unknown and connect, letting it name
# itself over the link. A scan holds the radio for eight seconds.
sub job_ble_adopt_scan {
	my ($args) = @_;
	sleep 40;
	while (1) {
		&subs::subprocessor_heartbeat();
		eval { &subs::ble_adopt_scan(); };
		sleep 300;
	}
}

# The Android app's scheduled wake holds the CPU for a short window each
# navigation interval. Once the app has proved it is arming them (wake_ready is
# fresh), release the permanent Termux lock; take it back if the scheduler
# stops or the person switches the schedule off.
sub job_wake_schedule {
	my ($args) = @_;
	sleep 20;
	my $ready_file = &subs::home('~/.president/wake_ready');
	my $released_file = &subs::home('~/.president/wake_lock_released');
	my $music_file = &subs::home('~/.president/music_stream_wake');
	# Music.pl may not be loaded in this worker, so the state path is
	# built here rather than through its helper.
	my $music_state_file = &subs::home('~/.president/music_stream.json');
	# A count with no stream behind it would otherwise keep the permanent
	# lock forever. Repair it once at start and let the release path below
	# do the actual unlock, so the lock is never dropped from here.
	if (-e $music_file && !-e $music_state_file) { write_file($music_file, 0); }
	while (1) {
		&subs::subprocessor_heartbeat();
		eval {
			my $setting = &subs::setting_grabber({ app => '__president', setting => 'wake_schedule' });
			$setting = 'on' unless defined $setting && $setting =~ /\S/;
			my $ready = (-e $ready_file && (time - (stat($ready_file))[9] < 3600)) ? 1 : 0;
			# only a stream the state file still describes holds the lock
			my $music = (-e $music_file && -e $music_state_file) ? (read_file($music_file) + 0) : 0;
			if ($setting eq 'on' && $ready && !$music) {
				unless (-e $released_file) {
					&subs::device_call('power.wake_unlock');
					# A track that started between the check and the unlock
					# must keep its lock; the same live-count rule applies.
					my $m2 = (-e $music_file && -e $music_state_file) ? (read_file($music_file) + 0) : 0;
					if ($m2 > 0) {
						&subs::device_call('power.wake_lock');
					}
					write_file($released_file, time());
					$subs::log->info('wake schedule: app scheduler ready; released the permanent wake lock');
				}
			}
			elsif ($setting ne 'on' || !$ready) {
				if (-e $released_file) {
					unless ($music) {
						&subs::device_call('power.wake_lock');
					}
					unlink $released_file;
					$subs::log->info('wake schedule: taking the permanent wake lock back');
				}
			}
		};
		sleep 60;
	}
}

# The house address book: this machine reports where it is when it boots and
# whenever its own interfaces change. The wake report in utility_runner covers
# a phone's scheduled beats; this covers a laptop moving between networks.
sub job_address_directory {
	my ($args) = @_;
	require './perl/AddressDirectory.pl';
	sleep 30;
	eval { &AddressDirectory::report('boot'); };
	my $last = eval { &AddressDirectory::fingerprint() } || '';
	while (1) {
		&subs::subprocessor_heartbeat();
		sleep 60;
		my $now = eval { &AddressDirectory::fingerprint() } || '';
		next if $now eq $last;
		$last = $now;
		eval { &AddressDirectory::report('network'); };
	}
}

# The voice models ride the same mesh as the APKs, but they change rarely, so
# this is a single pass after boot rather than a loop.
sub job_voice_sync {
	my ($args) = @_;
	sleep 50;
	eval { &subs::voice_sync(); };
}

# The warm whisper.cpp server keeps the speech model loaded, so a clip skips
# the per-call model load the one-shot CLI pays. The server is started by
# demand: any transcription request touches ~/.president/whisper-want, and
# this loop starts the server while that marker is fresh and stops the one it
# started once the house has been quiet for ten minutes.
sub job_whisper_server {
	my ($args) = @_;
	my $idle_limit = 600;      # ten quiet minutes, then the model goes back
	my $want_at = 0;           # when a transcription last asked for the server
	my $server_pid = 0;        # the one this loop started (0: none of ours)
	# A server started by the tree this one replaced outlived it, and the
	# demand logic below would adopt it as "already up" and hold the model for
	# good (see whisper_server_stop_orphans). Clear those before the first look.
	my $orphans = &subs::whisper_server_stop_orphans();
	$subs::log->info("whisper: stopped $orphans orphaned server(s)") if $orphans && $subs::log;
	while (1) {
		&subs::subprocessor_heartbeat();
		my $want = &subs::whisper_server_wanted();
		$want_at = $want if $want > $want_at;
		my $recent = ($want_at && (time - $want_at) <= 120) ? 1 : 0;
		my $idle   = ($want_at && (time - $want_at) > $idle_limit) ? 1 : 0;
		# Reap a server that died on its own, or its pid would sit as a zombie
		# and the "is it up" answer below would be about a dead process.
		if ($server_pid) {
			my $reaped = waitpid($server_pid, POSIX::WNOHANG());
			$server_pid = 0 if $reaped == $server_pid || $reaped == -1;
		}
		require IO::Socket::INET;
		my $port = &subs::whisper_server_port();
		my $probe = IO::Socket::INET->new(
			PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'tcp', Timeout => 1);
		my $up = $probe ? 1 : 0;
		close $probe if $probe;
		my $bin   = &subs::whisper_server_bin();
		my $model = &subs::whisper_model_file('tiny');
		$model = &subs::whisper_model_file('base') unless length $model && -e $model;
		if (!$up && !$server_pid && $recent && -x $bin && -e $model) {
			my $log = &subs::home('~/whisper-server.log');
			my $log_fh;
			open($log_fh, '>>', $log);
			my $pid = fork();
			if (defined $pid && $pid == 0) {
				open(STDOUT, '>&', $log_fh) if $log_fh;
				open(STDERR, '>&', $log_fh) if $log_fh;
				exec($bin, '-m', $model, '--host', '127.0.0.1', '--port', $port, '--convert')
					or POSIX::_exit(1);
			}
			close($log_fh) if $log_fh;
			$server_pid = $pid if defined $pid && $pid > 0;
		}
		# A server somebody started by hand is left alone: this loop stops only
		# the one it started itself.
		elsif ($up && $server_pid && $idle) {
			kill 'TERM', $server_pid;
			my $gone = 0;
			for (1 .. 50) {
				$gone = 1 if waitpid($server_pid, POSIX::WNOHANG()) != 0;
				last if $gone;
				select(undef, undef, undef, 0.1);
			}
			if (!$gone) {
				kill 'KILL', $server_pid;
				waitpid($server_pid, 0);
			}
			$server_pid = 0;
		}
		# A model load is a second or two: look again soon while the house is
		# talking, and coast otherwise.
		sleep($recent ? 5 : 30);
	}
}

# The archive queue's worker. Jobs are enqueued from the web process into the
# same SQLite file under ~/.president; one at a time, so a slow link is never
# asked for two files at once and the queue keeps its order.
sub job_minion_worker {
	my ($args) = @_;
	my $minion = &subs::minion_grabber();
	# the launcher clears the queue at startup and the nightly evaluation
	# wishes live in the settings: put their schedules back
	&subs::nightly_evaluation_reconcile();
	# The CloudSync sweep is NOT armed here. Minion::Worker::run resets the event
	# loop as its first act, which drops a timer armed before it - so the sweep
	# never fired and a change made while nobody pressed Sync waited for ever.
	# It has its own process below.
	my $worker = $minion->worker;
	$worker->status->{jobs} = 1;
	$worker->run;
}

# CloudSync folders are watched by a machine, not a browser tab: a change made
# while no Folders window is open still reaches the other machines. It is a
# subprocessor of its own because the Minion worker's run resets the event loop
# and would drop any timer armed before it (see job_minion_worker).
sub job_cloud_sync_sweep {
	&subs::cloud_sync_sweep_start();
	Mojo::IOLoop->start;
}

# The evaluation schedules live in this machine's queue, but the cadence that
# asks for them is a shared setting. Re-read the wishes every few minutes so a
# machine that stays up learns of a cadence changed on a peer.
sub job_evaluation_schedules {
	my ($args) = @_;
	sleep 120;
	while (1) {
		&subs::subprocessor_heartbeat();
		eval { &subs::nightly_evaluation_reconcile(); };
		sleep 300;
	}
}

# The evaluation dispatch: the server assigns each scheduled run to a ready
# worker a few minutes before it is due, and every machine turns an assignment
# addressed to it into a queued job.
sub job_evaluation_dispatch {
	my ($args) = @_;
	sleep 45;
	while (1) {
		&subs::subprocessor_heartbeat();
		eval { &subs::evaluation_dispatch_tick(); };
		eval { &subs::where_audit_tick(); };
		sleep 60;
	}
}

# The utility scheduler: alarms, navigation, sync and the rest run from the
# timers this registers, so it must own a process and a loop of its own. On
# Unix subs::subprocessor forks it as before; on a box without fork the named
# job starts perl/subprocessor_worker.pl. The bodies live in
# perl/utility_jobs.pl; the two entry points that host this job (President.pl
# and perl/subprocessor_worker.pl) load it, so jobs.pl stays a leaf in the
# require graph (Calendar.pm requires jobs.pl).
sub job_utility_functions {
	my ($args) = @_;
	# A forked child inherited these from President; a worker fills them from
	# subroutines.pl. utility_jobs.pl declares the same package variables.
	$President::config = $subs::config unless $President::config;
	$President::device = $subs::device unless defined $President::device;
	$President::log = $subs::log unless $President::log;
	my $status_file = &subs::home('~/.president/status');
	Mojo::IOLoop->timer(2 => sub {
		&President::utility_functions();
	});
	Mojo::IOLoop->recurring(2 => sub {
		&subs::subprocessor_heartbeat();
		if ($gb::utility_functions_watcher == 0) {
			$gb::utility_functions_watcher = 1;
			$President::log->info('starting utility functions');
		}
		my $f_status = read_file($status_file);
		if ($f_status eq '') {
			write_file($status_file, 'good');
			print "wrote status good\n";
		}
	});
	Mojo::IOLoop->start;
}

%JOB = (
	'app release sync' => \&job_app_release_sync,
	'slow loops' => \&job_slow_loops,
	'utility functions' => \&job_utility_functions,
	'house levels' => \&job_house_levels,
	'device mdns sync' => \&job_device_mdns_sync,
	'adf receipt watch' => \&job_adf_receipt_watch,
	'house advertise' => \&job_house_advertise,
	'sshd watcher' => \&job_sshd_watcher,
	'lan presence beacon' => \&job_lan_presence_beacon,
	'lan presence listener' => \&job_lan_presence_listener,
	'lan mesh wake' => \&job_lan_mesh_wake,
	'ble adopt scan' => \&job_ble_adopt_scan,
	'wake schedule' => \&job_wake_schedule,
	'address directory' => \&job_address_directory,
	'say it' => \&job_say_it,
	'watch reply wifi' => \&job_watch_reply_wifi,
	'watch reply audio' => \&job_watch_reply_audio,
	'embedded toggle sender' => \&job_embedded_toggle_send,
	'embedded toggle refresh' => \&job_embedded_toggle_refresh,
	'voice sync' => \&job_voice_sync,
	'whisper server' => \&job_whisper_server,
	'Minion Worker' => \&job_minion_worker,
	'cloud sync sweep' => \&job_cloud_sync_sweep,
	'evaluation schedules' => \&job_evaluation_schedules,
	'evaluation dispatch' => \&job_evaluation_dispatch,
);

1;
