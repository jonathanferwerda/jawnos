#!/usr/bin/perl

use strict;
use warnings;
$| = 1; # Enable command autoflush

use FindBin qw($Bin);

# Change directory to the script's home location
chdir($Bin) or die "Cannot change directory to $Bin: $!";
package President;
print $0 ."\n";
print `pwd` . "\n";
my $self = $$;
print "I am $self\n";
use Mojolicious::Lite;
use Mojo::IOLoop;
use Mojo::Server::Daemon;
use Mojo::Server::Morbo;
use Mojo::Server::Prefork;
use Mojo::Server::Hypnotoad;
use Data::Dumper;
use File::Slurp;
use Mojo::Util qw/md5_sum /;
use Time::Local;
use Time::Piece;
use Time::Duration;
use Date::Parse;
use Sereal::Encoder qw(encode_sereal SRL_SNAPPY SRL_ZSTD);
use Sereal::Decoder qw(decode_sereal);
my $encoder = Sereal::Encoder->new({ compress => SRL_ZSTD, compress_level => 3 });
my $decoder = Sereal::Decoder->new();
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Reactor::Poll;
use Clone qw(clone);
use Minion;
use POSIX ();
use threads 'exit' => 'threads_only';

no warnings 'uninitialized'; 
# the gb globals below live in gb.pl and are written or read from every
# corner of the house; a file that touches one only once is not a typo
no warnings 'once';
my $working_dir = $0;
my $present_dir = `pwd`;

my $dump_dir = &home('~/.president');
$gb::dump_dir = $dump_dir;
#`rm -R $dump_dir/*` if -e $dump_dir;
`mkdir $dump_dir` unless -e $dump_dir;
`mkdir ./server` unless -e './server';
my $duty_file = &home('~/.president/on_duty');
`touch $duty_file`;
write_file($duty_file, 0);
my $status_file = &home('~/.president/status');
`touch $status_file`;
my $pid_file = &home('~/.president/pid');
`touch $pid_file`;
write_file($pid_file, $$);
my $config_file = read_file('./config.json');
my $config = decode_json $config_file;
our $logfile = &home($config->{'logfile'});
if (-e $logfile) {
#	`shred -u $logfile`;
}
`touch $logfile` if not -e $logfile;
our $log = Mojo::Log->new(path => $logfile);
if ($working_dir ne $present_dir) {
	my @folder = split '/', $working_dir;
	pop @folder;
	my $new_dir = join '/', @folder;
	print 'chdir to ' . $new_dir . "\n";
	chdir $new_dir;
	print `pwd` . "\n";

}
#`espeak "president has begun"`;


my $environment = shift;

my $cache_dir = &home('~/') . '.president';
`mkdir -p $cache_dir` unless -e $cache_dir;

require './gb.pl';

# The archive root (config.json archive_dir) gets one folder per location type,
# made here if it is missing. A blank archive_dir means this machine is not an
# archive and nothing happens.
my $archive_root = &subs::archive_scaffolder();
if ($archive_root->{'enabled'}) {
	my @made = @{$archive_root->{'created'}};
	$log->info('archive root ' . $archive_root->{'dir'} . (@made ? ' created: ' . join(', ', @made) : ' already in place'));
}

$SIG{INT} = sub {
	# Do not print "President Died" here: ./jawn reads that phrase as a crash and
	# restarts the tree again, so a deliberate restart (which sends SIGINT) became
	# a restart loop on masters started before the jawn_deliberate guard. The
	# close handler and the liveness watchdog are what detect a real death.
	print "President stopping on SIGINT; cleaning up...\n";
	$log->info('President caught SIGINT') if $log;
	#`rm -R $dump_dir/*` if -e $dump_dir;
	exit 0;
};

my @sockets = qw/ws alarm/;
foreach my $s ( @sockets ) {
	unlink $gb::tmp_dir . '/' . $s;
}
my $random_number;
if (!$config->{'working_port'}) {
	$random_number = 0;
	until ($random_number > 1024 && $random_number < 60000) {
		$random_number = int(rand(59999));
	}
} else {
	$random_number = $config->{'working_port'} < 60000 ? $config->{'working_port'} : 45545;
}
my $on_duty = 0;
my $hour = localtime( &subs::rightNow() / 1000 )->strftime( "%H");

my $domain = $config->{'domain'} || '127.0.0.1';
#my $domain = '127.0.0.1';

my $device = &device_setter();
if ($device eq 'mobile') {
	# Take the lock for the boot. The wake-schedule worker below releases it as
	# soon as the Android app proves it is arming the short scheduled wakes.
	unlink &subs::home('~/.president/wake_lock_released');
	`termux-wake-lock`;
	`sshd`;
}

if ($config->{'open_browser'} eq 'yes') {
	if ($device eq 'mobile') {
		threads->create(sub() { 
			`termux-open https://127.0.0.1:$random_number/manager & `
		});
	}
	elsif ($device eq 'computer') {
		threads->create(sub() { 
			`export DISPLAY=:0`;
			my $chrome = `chromium https://$domain:$random_number/manager &`;
		});
	}
}
if ($environment) {
	if ($environment =~ /^dev/) {
		$config->{'environment'} = 'development';
	}
	elsif ($environment =~ /^pro/) {
		$config->{'environment'} = 'production';
	}

}
my $port = $random_number;
my $watch_port = $port + 2;
my $ws_port = $port + 1;
my $dock_port = $config->{'port'};
my $tty_port = $port + 3;
my $alarm_port = $port + 5;
if ($config->{'environment'} eq 'development') {
	$ws_port = $port;
	$alarm_port = $port;
}


# A worker's Perl heap grows with the work it does and is never handed back to
# the OS, so on a handheld it only accumulates until Android's low-memory killer
# reclaims the whole tree. `accepts` ends a worker once it has taken that many
# connections; the prefork `spare` starts the replacement before the old worker
# stops, so nothing is dropped and the grown heap leaves with it. A server keeps
# the module default, where a long-lived connection is worth more than the heap.
# The spawn hook names each worker (with its PURPOSE, readable only in the worker)
# and the pid, so a ballooning worker can be attributed rather than guessed.
sub prefork_tune {
	my ($prefork, %opt) = @_;
	# Recycle workers so a grown heap dies with its worker instead of living
	# forever. `accepts` ends a worker once it has taken that many connections and
	# prefork starts a lean replacement before the old one stops. A phone already
	# needs this (Android's low-memory killer); a desktop benefits just as much -
	# it grew a main worker to 116MB, three times a fresh one.
	#
	# A server whose connections are long-lived and load-bearing asks to be left
	# alone with keep_alive: the websocket worker's sockets ARE the product, the
	# alarm server holds wake connections, and a teletype session is a terminal
	# someone is sitting in - ending those would drop live work to save a heap
	# nobody is watching. A server (device) also keeps the module default.
	$prefork->accepts(500) if $device eq 'mobile' || (!$opt{'keep_alive'} && $device ne 'server');
	$prefork->on(spawn => sub {
		my ($self, $pid) = @_;
		$log->info('worker spawn purpose=' . ($ENV{PURPOSE} || '?') . " pid=$pid");
	});
	return $prefork;
}

# ---- add a main worker when they are all busy --------------------------------
# A worker serves one request at a time, and a model answer or a mail fetch can
# hold it for minutes. Every main worker keeps a marker under
# ~/.president/busy while it is inside a request (subs::request_busy_change).
# This supervisor watches those markers: when every worker in the pool has been
# busy for two seconds it sends TTIN, which Mojo::Server::Prefork's manager
# answers by adding a worker; when the pool has been quiet for half a minute it
# sends TTOU and retires one. The phone may grow by one worker, a desktop or
# server by two. The supervisor is a child of the prefork manager (the process
# that becomes the manager when run() is called) so its signal names the manager
# directly and it retires with it.
sub prefork_autoscale {
	my ($prefork, %opt) = @_;
	my $min = $opt{'min'} || $prefork->workers;
	my $max = $opt{'max'} || $min + 2;
	return $prefork if $max <= $min;
	my $dir = &subs::home('~/.president/busy');
	eval { mkdir $dir unless -d $dir; };
	my $parent = $$;
	my $pid = fork();
	unless (defined $pid) {
		$log->error('autoscale: cannot fork: ' . $!);
		return $prefork;
	}
	return $prefork if $pid;   # the prefork manager carries on
	# ---- supervisor child ----
	$0 = 'jawn autoscale';
	$SIG{$_} = 'DEFAULT' for qw/INT TERM HUP CHLD/;
	my ($current, $high, $low) = ($min, 0, 0);
	while (1) {
		sleep 1;
		last unless kill 0, $parent;
		my $busy = 0;
		if (opendir(my $dh, $dir)) {
			foreach my $name ( grep { /^\d+$/ } readdir $dh ) {
				my $file = "$dir/$name";
				my $age = time - ((stat($file))[9] || 0);
				# a worker that died leaves its marker; a request lost by a live
				# worker is aged out rather than left to keep a worker forever
				unless (kill 0, int($name)) { unlink $file; next; }
				if ($age > 1800) { unlink $file; next; }
				$busy++;
			}
			closedir $dh;
		}
		# Mojo's `spare` only widens the pool while a worker is stopping
		# gracefully; in steady state the pool is exactly `workers`.
		my $pool = $current;
		if ($busy >= $pool) { $high++ } else { $high = 0 }
		if ($high >= 2 && $current < $max) {
			kill 'TTIN', $parent;
			$current++;
			$high = 0;
			$low = 0;
			$log->info('autoscale: all ' . $pool . ' main workers busy; raising to ' . $current);
		}
		if ($busy <= $current - 1) { $low++ } else { $low = 0 }
		if ($low >= 30 && $current > $min) {
			kill 'TTOU', $parent;
			$current--;
			$low = 0;
			$high = 0;
			$log->info('autoscale: main workers quiet; back to ' . $current);
		}
	}
	POSIX::_exit(0);
}

my @threads;
sub manager_starter() {
	my $ws_tty_port = $tty_port + 1;
	$ENV{PORT_AHOY} = $random_number;
	$ENV{PORT_MSG} = $ws_port;
	$ENV{PORT_BELL} = $alarm_port;
	$ENV{PORT_BESTOW} = $tty_port;
	$ENV{PORT_DOCK} = $dock_port;
	$ENV{PORT_COMS} = $ws_tty_port;
	$ENV{PORT_ARM} = $watch_port;
	$ENV{PORT_ENV} = $config->{'environment'};
	$ENV{cookie_name} = 'president';

	my $certs = "";

	if (-e './server/fullchain.pem' && -e './server/privkey.pem') {
		$certs = "?cert=./server/fullchain.pem&key=./server/privkey.pem";
	}
	my $time_count = 0;
	my $now = &subs::rightNow();
	write_file($duty_file, $now);
	# A fresh President has no remote sync in flight; the tree that just died may
	# have left the "running" lock behind (this machine's servers restart every
	# few minutes under memory pressure), which blocked the next sync for minutes.
	&subs::setting_setter({ app => '__president', setting => 'remote_upgrade', value => '' });
	# Job rows left 'running' by the tree that just died are not live: no worker
	# from it can own one now. Age them out so the sync counters read true.
	my $reaped_jobs = &subs::sync_jobs_reap(0);
	$log->info('sync jobs reaped: ' . $reaped_jobs) if $reaped_jobs;
	# Data backfills run at boot, so a code sync followed by the restart the
	# sync itself triggers heals the data without waiting for a login. Ones whose
	# prerequisites are not ready yet are left for the login / merge pass.
	&subs::run_backfills();
	# A house that has a paper recovery code starts gated (padlock row, General,
	# Enforce). The marker makes it a default: Turn the gate off stays off.
	&subs::padlock_seed_default();
	# Freeze the code revision here, at boot, so /manager/version reports what this
	# process is actually running. The forked servers inherit this memo, so an
	# on-disk change does not move the answer until the next restart.
	&subs::code_revision();
	# Code sync used to be a one-minute loop here. It is the `git_sync` utility
	# now: Configure -> Sys paces it, it rides the slow batch, and a wake that is
	# already running the mesh fetch does not need a separate timer every minute.

	# The staged app releases (the APKs) reconcile on a slower tick: ask each
	# reachable peer what it holds and pull the newest in, so every device becomes
	# a holder and a source. The code watcher above keeps the Perl tree current;
	# this keeps the app blob current. A first pass soon after boot, then every
	# five minutes.
	&subs::subprocessor(sub {
		sleep 45;
		while (1) {
			eval { &subs::app_release_sync(); };
			sleep 300;
		}
	}, { name => 'app release sync' });

	# Each machine signs the house crest with its peer key and hands that signature
	# to the other machines, which keep it on the sender's roster row. Every
	# machine posts to every peer, so each one's People panel (and the card it
	# hands out) can list the backers it has heard from. A pass soon after boot,
	# then every five minutes.
	&subs::subprocessor(sub {
		sleep 90;
		while (1) {
			eval { &subs::crest_member_cosig_sync(); };
			sleep 300;
		}
	}, { name => 'crest member cosign' });

	# The start menu's System card: every peer's battery and the embedded boards
	# the house can see. The peers answer /manager/health; the boards answer
	# /device_query. Both are cached, so the card never waits on a sleeping board.
	&subs::subprocessor(sub {
		sleep 20;
		while (1) {
			# Two minutes is the house pace, but a System card on screen asks for
			# quick passes (levels_fast_request): sleep in slices and answer it
			# within seconds, so a phone plugged in a moment ago updates.
			my $fast = &subs::cache_get({ app => '__president', context => 'levels', subcontext => 'fast' }) || 0;
			my $wanted = ($fast && &subs::rightNow() - $fast < 90000) ? 1 : 0;
			eval { &subs::house_levels_sync({ fast => $wanted }); };
			my $synced = &subs::rightNow();
			while (1) {
				sleep 2;
				my $now = &subs::rightNow();
				last if $now - $synced >= 120000;
				$fast = &subs::cache_get({ app => '__president', context => 'levels', subcontext => 'fast' }) || 0;
				last if $fast && $now - $fast < 90000 && $now - $synced >= 8000;
			}
		}
	}, { name => 'house levels' });

	# mDNS is how a device names itself the moment it joins: fold what the local
	# network advertises (_jawnos._tcp, plus a printer on _ipp._tcp) into this
	# machine's device row on a short tick, so a plugged-in watch, deck or pico
	# appears with its purpose and abilities without anyone pressing Scan.
	&subs::subprocessor(sub {
		sleep 12;
		while (1) {
			eval { &subs::device_mdns_sync(); };
			sleep 15;
		}
	}, { name => 'device mdns sync' });

	# Advertise this House machine on the LAN. An embedded device browses
	# _jawnos-house._tcp when the homebase it was handed stops answering, so it
	# can move to another computer/mobile/server that is actually up instead of
	# going dark until someone runs Now Me again. The TXT carries the ports it
	# dials (arm/coms/bestow), not just the main one. Avahi renames the instance
	# if two machines share a name, which is fine: devices read the TXT.
	&subs::subprocessor(sub {
		sleep 5;
		while (1) {
			eval { &subs::house_advertise_supervise(); };
			sleep 30;
		}
	}, { name => 'house advertise' });

	# A peer joining a network - the house wifi, a friend's, a hotspot - says so
	# with a small signed broadcast on that LAN. The listener refreshes the peer's
	# address on every machine that hears it and wakes the reconnector, so the
	# mesh resumes within seconds instead of waiting for the next tunnel check.
	# This is the path the phone and tablet use: Termux has no avahi, so mDNS
	# alone never reaches them.
	&subs::subprocessor(sub {
		sleep 6;
		while (1) {
			eval { &subs::lan_presence_send(); };
			sleep 5;
		}
	}, { name => 'lan presence beacon' });

	&subs::subprocessor(sub {
		sleep 3;
		while (1) {
			eval { &subs::lan_presence_listen(); };
			sleep 5;
		}
	}, { name => 'lan presence listener' });

	# The listener only leaves a cache stamp; this loop runs the mesh sync in its
	# own process so the listener is never blocked behind a pull.
	&subs::subprocessor(sub {
		sleep 7;
		while (1) {
			sleep 2;
			my $wake = &subs::cache_get({ app => '__president', context => 'lan', subcontext => 'wake' });
			next unless $wake;
			&subs::cache_delete({ app => '__president', context => 'lan', subcontext => 'wake' });
			eval { &subs::remote_machine_negotiator({}); };
		}
	}, { name => 'lan mesh wake' });

	# A device that has never been on WiFi cannot be named by mDNS, and the tree
	# holds no address for it, so nothing ever connects and it stays invisible while
	# it sits on the desk. Every JawnOS board advertises the Nordic UART service, so
	# scan the radio for one whose address is unknown and connect, letting it name
	# itself over the link - the "plug it in and it is known" path, with no wifi at
	# all. Slower than the mDNS tick, since it holds the radio for a few seconds.
	&subs::subprocessor(sub {
		sleep 40;
		while (1) {
			eval { &subs::ble_adopt_scan(); };
			sleep 30;
		}
	}, { name => 'ble adopt scan' });

	# The Android app's scheduled wake (JawnWakeReceiver) holds the CPU for a
	# short window each navigation interval. Once the app has proved it is
	# arming them (wake_ready is fresh), release the permanent Termux lock a
	# handheld used to need; take it back if the scheduler stops or the person
	# switches the schedule off. Music's own count file keeps its stream lock
	# safe: never release while a track is playing.
	if ($device eq 'mobile') {
		&subs::subprocessor(sub {
			sleep 20;
			my $ready_file = &subs::home('~/.president/wake_ready');
			my $released_file = &subs::home('~/.president/wake_lock_released');
			my $music_file = &subs::home('~/.president/music_stream_wake');
			while (1) {
				eval {
					my $setting = &subs::setting_grabber({ app => '__president', setting => 'wake_schedule' });
					$setting = 'on' unless defined $setting && $setting =~ /\S/;
					my $ready = (-e $ready_file && (time - (stat($ready_file))[9] < 3600)) ? 1 : 0;
					my $music = (-e $music_file) ? (read_file($music_file) + 0) : 0;
					if ($setting eq 'on' && $ready && !$music) {
						unless (-e $released_file) {
							`termux-wake-unlock`;
							# A track that started between the check and the unlock
							# must keep its lock.
							my $m2 = (-e $music_file) ? (read_file($music_file) + 0) : 0;
							`termux-wake-lock` if $m2 > 0;
							write_file($released_file, time());
							$log->info('wake schedule: app scheduler ready; released the permanent wake lock');
						}
					}
					elsif ($setting ne 'on' || !$ready) {
						if (-e $released_file) {
							`termux-wake-lock` unless $music;
							unlink $released_file;
							$log->info('wake schedule: taking the permanent wake lock back');
						}
					}
				};
				sleep 60;
			}
		}, { name => 'wake schedule' });
	}

	# A peer's Ollama model list is cached on a slower tick, so Plat can offer
	# models by the machine they run on without waiting on the network.
	&subs::subprocessor(sub {
		sleep 60;
		while (1) {
			eval { &subs::ollama_models_sync(); };
			sleep 600;
		}
	}, { name => 'ollama models sync' });

	# The error watch tails the tree's own output (the pty stream jawn tees into
	# ~/pty.log, plus ~/manager.log) and stages a proposed fix per new error,
	# for a person to apply from the IDE's coding chatbox. Off until Configure
	# -> Plat switches it on; a first pass soon after boot, then every minute.
	&subs::subprocessor(sub {
		sleep 25;
		while (1) {
			eval { &subs::error_watch_tick(); };
			sleep 60;
		}
	}, { name => 'error watch' });

	# The guide watch reads the Guide's saved conversations (the same rows the
	# Agents list reads back) for a turn that went nowhere - a thing not found, a
	# command that could not run, a closing line that says so - and stages each
	# like an error, so the same Coding agent adjusts the Guide's own training
	# through the same propose/Apply loop. Off until Configure -> Plat ticks
	# Watch the Guide; its first pass only takes a baseline.
	&subs::subprocessor(sub {
		sleep 40;
		while (1) {
			eval { &subs::guide_watch_tick(); };
			sleep 60;
		}
	}, { name => 'guide watch' });

	# The records watch audits the appointments table for the fault class that
	# corrupts the person's numbers (one stop press closes one session) and stages
	# each finding for review, the same shape as the error watch. It runs on a slow
	# cadence - the sweep predates the fix by weeks, so a two-hourly pass is plenty.
	# Off until Configure -> Plat ticks Records.
	&subs::subprocessor(sub {
		sleep 120;
		while (1) {
			eval { &subs::records_watch_tick(); };
			sleep 7200;
		}
	}, { name => 'records watch' });

	# The voice models ride the same mesh as the APKs, but they change rarely, so
	# this is a single pass after boot rather than a loop: a device that lacks a
	# voice pulls it in and can then serve it. Opening Configure -> Misc refreshes
	# them on demand (see the misc_setting_list route).
	&subs::subprocessor(sub {
		sleep 50;
		eval { &subs::voice_sync(); };
	}, { name => 'voice sync' });

	# A warm whisper.cpp server on loopback keeps the speech model loaded, so a
	# clip skips the per-call model load the one-shot CLI pays. A machine without
	# the binary or a model simply checks again later; whisper_transcribe falls
	# back to the CLI or the cloud when the port is quiet. The server logs to its
	# own file so a long-running tree's manager.log does not grow with every clip.
	&subs::subprocessor(sub {
		sleep 30;
		while (1) {
			my $bin   = &subs::home('~/whisper.cpp/build/bin/whisper-server');
			my $model = &subs::home('~/whisper.cpp/models/ggml-tiny.bin');
			$model = &subs::home('~/whisper.cpp/models/ggml-base.bin') unless -e $model;
			if (-x $bin && -e $model) {
				my $port = &subs::whisper_server_port();
				# A server already listening there (started by hand, or this loop's
				# own previous run not yet gone) is left alone.
				require IO::Socket::INET;
				my $probe = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'tcp', Timeout => 1);
				if ($probe) {
					close $probe;
					sleep 60;
					next;
				}
				my $log = &subs::home('~/whisper-server.log');
				my $log_fh;
				open($log_fh, '>>', $log);
				my $pid = fork();
				if (!$pid) {
					open(STDOUT, '>&', $log_fh) if $log_fh;
					open(STDERR, '>&', $log_fh) if $log_fh;
					exec($bin, '-m', $model, '--host', '127.0.0.1', '--port', $port, '--convert');
					exit 1;
				}
				waitpid($pid, 0) if $pid > 0;
				close($log_fh) if $log_fh;
				sleep 15;
			}
			else {
				sleep 300;
			}
		}
	}, { name => 'whisper server' });

	# The provider balances shown in Configure -> Sys. Only OpenRouter and DeepSeek
	# publish an account balance, so this reads what it can and caches it for the
	# page to show; a page load never waits on a provider. First pass soon after
	# boot, then every ten minutes.
	&subs::subprocessor(sub {
		sleep 30;
		while (1) {
			eval { &subs::ai_balance_refresh(); };
			sleep 600;
		}
	}, { name => 'ai balance' });

	# The cached fiat and coin rates every currency conversion reads. One keyless
	# Coinbase call every half hour keeps both the fiat exchanges and the wallets
	# current; the loop leaves the last snapshot alone when it cannot reach a
	# source, and does nothing at all while crypto is turned off.
	&subs::subprocessor(sub {
		sleep 35;
		while (1) {
			eval { &subs::crypto_rates_refresh(); };
			sleep 1800;
		}
	}, { name => 'crypto rates' });

	$ENV{'MOJO_MAX_LINE_SIZE'} = "64000";
	if ($config->{'environment'} eq 'development') {
		&subs::subprocessor(sub {
		#  $SIG{'KILL'} = sub { threads->exit(); };
			print "Starting Locker Server on port " . $dock_port . "\n";
			$ENV{MOJO_LISTEN} = 'https://*:' . $dock_port . $certs;
			$ENV{PURPOSE} = 'locker';
			my $morbo = Mojo::Server::Morbo->new;
			$morbo->backend->watch(['./', './templates']);
			$morbo = $morbo->daemon(Mojo::Server::Daemon->new);
			$morbo->run('./Manager.pl');
		}, { name => 'Dev Locker Server' });
		if ($ENV{PORT_AHOY} != $ENV{PORT_MSG}) {
			&subs::subprocessor(sub {
			#  $SIG{'KILL'} = sub { threads->exit(); };
				print "Starting WS Server on port " . $ws_port . "\n";
				$ENV{MOJO_LISTEN} = 'https://*:' . $ws_port . $certs;
				$ENV{PURPOSE} = 'websocket';
				my $morbo = Mojo::Server::Morbo->new;
				$morbo->backend->watch(['./', './templates']);
				$morbo = $morbo->daemon(Mojo::Server::Daemon->new);
				$morbo->run('./Manager.pl');
			}, { name => 'Dev WS Server' });
		}
		&subs::subprocessor(sub {
		#  $SIG{'KILL'} = sub { threads->exit(); };
			print "Starting Main Server on port " . $port . "\n";
			$ENV{MOJO_LISTEN} = 'https://*:' . $port . $certs;
			$ENV{PURPOSE} = 'main';
			my $morbo = Mojo::Server::Morbo->new;
			$morbo = $morbo->daemon(Mojo::Server::Daemon->new);
			$morbo->backend->watch(['./', './templates']);
			$morbo->run('./Manager.pl');
		}, { name => 'Dev Main Server' });
	}
	elsif ($config->{'environment'} eq 'production') {

		&subs::subprocessor(sub {
		 # $SIG{'KILL'} = sub { threads->exit(); };
			print "Starting Pro Locker Server on port " . $dock_port . "\n";
			$ENV{MOJO_LISTEN} = 'https://*:' . $dock_port . $certs;
			$ENV{PURPOSE} = 'locker';
			my $prefork = &prefork_tune(Mojo::Server::Prefork->new(listen => [ $ENV{MOJO_LISTEN} ]));
			$prefork->heartbeat_timeout(200);
			$prefork->load_app('./Manager.pl');
			$prefork->workers(1);
			$prefork->run;
			$log->info('after locker server');
		}, { name => 'Pro Locker Server' });

		&subs::subprocessor(sub {
		#  $SIG{'KILL'} = sub { threads->exit(); };
			print "Starting Pro WS Server on port " . $ws_port . "\n";
			$ENV{MOJO_LISTEN} = 'https://*:' . $ws_port . $certs;
			$ENV{PURPOSE} = 'websocket';
			my $prefork = &prefork_tune(Mojo::Server::Prefork->new(listen => [ $ENV{MOJO_LISTEN} ]), keep_alive => 1);
			$prefork->heartbeat_timeout(200);
			$prefork->load_app('./Manager.pl');
			$prefork->workers(1);
			$prefork->run;
			$log->info('after ws server');
		}, { name => 'Pro WS Server' });

		&subs::subprocessor(sub {
		#  $SIG{'KILL'} = sub { threads->exit(); };
			print "Starting Pro Prefork Main Server on port " . $port . "\n";
			$ENV{MOJO_LISTEN} = 'https://*:' . $port . $certs;
			$ENV{PURPOSE} = 'main';
			my $prefork = &prefork_tune(Mojo::Server::Prefork->new(listen => [ $ENV{MOJO_LISTEN} ]));
			$prefork->heartbeat_timeout(200);
			$prefork->load_app('./Manager.pl');
			# A handheld runs this whole tree in a few hundred MB that Android's
			# low-memory killer reclaims the moment the device tightens; the extra
			# prefork workers are a server's concurrency, not a phone's. Two is the
			# phone's resting count; the autoscaler adds one more while every worker
			# is busy. A desktop rests at three and a server at four, each growing by
			# two under a burst. `main_workers` in config.json overrides the resting
			# count when a machine wants a different one.
			my $configured_workers = (defined $config->{'main_workers'} && $config->{'main_workers'} =~ /^\d+$/ && $config->{'main_workers'} > 0)
				? int($config->{'main_workers'}) : 0;
			my $main_workers = $configured_workers || ($device eq 'mobile' ? 2 : ($device eq 'server' ? 4 : 3));
			$prefork->workers($main_workers);
			&prefork_autoscale($prefork, min => $main_workers, max => $main_workers + ($device eq 'mobile' ? 1 : 2));
			$prefork->run;
			$log->info('after main server');
		}, { name => 'Pro Main Server' });
		&subs::subprocessor(sub {
		 # $SIG{'KILL'} = sub { threads->exit(); };
			print "Starting Pro Prefork Alarm Server on port " . $alarm_port . "\n";
			$ENV{MOJO_LISTEN} = 'https://*:' . $alarm_port . $certs;
			$ENV{PURPOSE} = 'alarm';
			my $prefork = &prefork_tune(Mojo::Server::Prefork->new(listen => [ $ENV{MOJO_LISTEN} ]), keep_alive => 1);
			$prefork->heartbeat_timeout(200);
			$prefork->load_app('./Alarm.pl');
			$prefork->workers(1);
			$prefork->run;
			$log->info('after alarm server');
		}, { name => 'Pro Alarm Server' });

	}
	else {
		print "I have no environment!\n";
	}

	if ($device ne 'server') {
		&subs::subprocessor(sub {
		#  $SIG{'KILL'} = sub { threads->exit(); };
			$ENV{PURPOSE} = "watch";
			$ENV{MOJO_LISTEN} = 'https://*:' . $watch_port . $certs;
			if ($config->{'environment'} eq 'development') {
				print "Starting Development Watch Server on $watch_port\n";
				my $morbo = Mojo::Server::Morbo->new;
				$morbo = $morbo->daemon(Mojo::Server::Daemon->new);
				$morbo->run('./watch.pl');
			}
			elsif ($config->{'environment'} eq 'production') {
				print "Starting Pro Watch Server on port " . $watch_port . "\n";
				my $prefork = &prefork_tune(Mojo::Server::Prefork->new(listen => [ $ENV{MOJO_LISTEN} ]));
				$prefork->heartbeat_timeout(200);
				$prefork->load_app('./watch.pl');
				$prefork->workers($device eq 'mobile' ? 1 : ($device eq 'server' ? 2 : 1));
				$prefork->run;
			}
		}, { name => 'Watch Server' });

		&subs::subprocessor(sub {
		 # $SIG{'KILL'} = sub { threads->exit(); };
			$ENV{PURPOSE} = "teletype";
			$ENV{MOJO_LISTEN} = 'https://*:' . $tty_port . $certs;
			if ($config->{'environment'} eq 'development') {
				print "Starting Development TTY Server on $tty_port\n";
				my $morbo = Mojo::Server::Morbo->new;
				$morbo = $morbo->daemon(Mojo::Server::Daemon->new);
				$morbo->run('./teletype.pl');
			}
			elsif ($config->{'environment'} eq 'production') {
				print "Starting Pro TTY Server on port " . $tty_port . "\n";
				my $prefork = &prefork_tune(Mojo::Server::Prefork->new(listen => [ $ENV{MOJO_LISTEN} ]), keep_alive => 1);
				$prefork->heartbeat_timeout(200);
				$prefork->load_app('./teletype.pl');
				$prefork->workers($device eq 'mobile' ? 1 : ($device eq 'server' ? 3 : 2));
				$prefork->run;
			}
		}, { name => 'TTY Server' });
		&subs::subprocessor(sub {
		#  $SIG{'KILL'} = sub { threads->exit(); };
			# The deck's control channel carries keystrokes, pointer movement and
			# button presses, so it is TLS like every other listener. This is the
			# wss port handed to a device as PORT_COMS / now_me's twshomebase.
			$ENV{PURPOSE} = "teletype";
			$ENV{MOJO_LISTEN} = 'https://*:' . $ws_tty_port . $certs;
			if ($config->{'environment'} eq 'development') {
				print "Starting Development TTYwss Server on $ws_tty_port\n";
				my $morbo = Mojo::Server::Morbo->new;
				$morbo = $morbo->daemon(Mojo::Server::Daemon->new);
				$morbo->run('./teletype.pl');
			}
			elsif ($config->{'environment'} eq 'production') {
				print "Starting Pro TTYwss Server on port " . $ws_tty_port . "\n";
				my $prefork = &prefork_tune(Mojo::Server::Prefork->new(listen => [ $ENV{MOJO_LISTEN} ]), keep_alive => 1);
				$prefork->heartbeat_timeout(200);
				$prefork->load_app('./teletype.pl');
				$prefork->workers(1);
				$prefork->run;
			}
		}, { name => 'TTY WS Server' });
	}




	my $uthr;
	my @results;
	my $f_status = read_file($status_file);
	my $socket_watch = &socket_watch($dump_dir . '/memory');
	if (-e $status_file) {

		write_file($status_file, 'good');
		print "wrote status good\n";
	}
	if (`ollama -v` =~ /client version is/) {
		&subs::subprocessor(sub {
			`OLLAMA_IGPU_ENABLE=1 OLLAMA_VULKAN=1 HIP_VISIBLE_DEVICES=-1 OLLAMA_NOHISTORY=1 ollama serve`;
		});
	}
	&subs::subprocessor(sub {

		Mojo::IOLoop->timer(2 => sub {
			&utility_functions();
		});
		Mojo::IOLoop->recurring(2 => sub {
			if ($gb::utility_functions_watcher == 0) {

				$gb::utility_functions_watcher = 1;
				$log->info('starting utility functions');

			}
#			my $is_running = defined Mojo::IOLoop->acceptor($socket_watch) ? 1 : 0;


			my $f_status = read_file($status_file);
			if ($f_status eq '') {
				write_file($status_file, 'good');
				print "wrote status good\n";
			}

		});
		Mojo::IOLoop->start;
	}, { name => 'utility functions' });

	# The archive queue's worker. Jobs are enqueued from the web process into
	# the same SQLite file under ~/.president; one at a time, so a slow link is
	# never asked for two files at once and the queue keeps its order.
	&subs::subprocessor(sub {
		my $minion = &subs::minion_grabber();
		# the launcher clears the queue at startup and the nightly evaluation
		# wishes live in the settings: put their schedules back
		&subs::nightly_evaluation_reconcile();
		my $worker = $minion->worker;
		$worker->status->{jobs} = 1;
		$worker->run;
	}, { name => 'Minion Worker' });

	# The evaluation schedules live in this machine's queue, but the cadence that
	# asks for them is a shared setting. Re-read the wishes every few minutes so a
	# machine that stays up learns of a cadence changed on a peer, and so every
	# machine holds the schedules that let it take the night over when the chosen
	# machine is quiet.
	&subs::subprocessor(sub {
		sleep 120;
		while (1) {
			eval { &subs::nightly_evaluation_reconcile(); };
			sleep 300;
		}
	}, { name => 'evaluation schedules' });

	# The evaluation dispatch: the server assigns each scheduled run to a ready
	# worker a few minutes before it is due, and every machine turns an assignment
	# addressed to it into a queued job. The ledger travels with the ordinary sync,
	# so a partition that cannot see the dispatcher has no fresh assignment and
	# stands down instead of running the same report twice.
	&subs::subprocessor(sub {
		sleep 45;
		while (1) {
			eval { &subs::evaluation_dispatch_tick(); };
			sleep 60;
		}
	}, { name => 'evaluation dispatch' });
	Mojo::IOLoop->start;
	END {
		print "quitting now!\n";
		print "They dead\n";
	}
}

# Only the database's path is kept here. The process opens no database handle
# any more: the mirror that copied the database into RAM is retired, so the
# web process and the device scripts stay its readers and writers.
our $current_db_path;

sub get_internal_db {
    # The machine's one database, at its fixed install path. No handle is opened
    # here on purpose: the web process, pen.pl and the device scripts are the
    # database's readers and writers, and a handle held open in this process only
    # pinned the WAL and kept a stale copy of the data around.
    return $current_db_path if $current_db_path && -e $current_db_path;

    my $database = &subs::database_path();
    if ($database && -e $database && -s $database > 5000) {
        $current_db_path = $database;
        $log->info('using ' . $database);
        return $current_db_path;
    }
    return undef;
}



sub socket_watch() {
	my ($watch_file) = @_;
	my %buffers;
	eval {
		my $server = Mojo::IOLoop->server({ path => $watch_file } => sub {
			my ($loop,$stream,$id) = @_;
			$stream->handle->autoflush(1);
			$stream->high_water_mark(8 * 1024 * 1024);

			$buffers{$id} = '';
			$stream->on(read => sub {

				my ($stream, $bytes) = @_;

				$buffers{$id} .= $bytes;

				while (1) {
					last if length($buffers{$id}) < 4;

					# 1. Peek at the first 4 bytes without removing them
					my $payload_length = unpack('N', substr($buffers{$id}, 0, 4));

					# 2. Check if the entire packet (4 bytes header + data blob) is present
					last if length($buffers{$id}) < (4 + $payload_length);

					# 3. NOW remove the 4 bytes header from the front of the string
					substr($buffers{$id}, 0, 4, ''); 

					# 4. Extract the exact length of the binary blob safely
					my $sereal_blob = substr($buffers{$id}, 0, $payload_length, '');
	        
	        my $query = eval { $decoder->decode($sereal_blob) };
	        if ($@) {
            warn "Worker $$: Failed to parse Sereal: $@";
            next;
	        }


					
          my $duty = $query->{'duty'} // '';
					if ($duty eq 'ai') {

						$log->info('A.I. Called');

						$log->info(Dumper $query);






					}
					elsif ($duty eq 'db_file_get') {
						# Resolve the latest active database path string
						my $db_path = get_internal_db();
						
						# Send the absolute file path straight back up the wire!
						eval {
								my $jwsm = $encoder->encode({ success => 1, data => { path => $db_path || '' } });
								my $packet = pack('N', length($jwsm)) . $jwsm;
								$stream->write($packet => sub{});
						};
					}
					else {
						# The mirror is retired: cache duties and raw database duties used to
						# run here against a RAM copy. The cache now reads and writes the
						# database in the calling process, so the only job left is to answer
						# - quickly - that this duty is not served any more, so a stray caller
						# fails fast instead of waiting out its socket timeout.
						eval {
							my $jwsm = $encoder->encode({ error => "no duty '$duty' here" });
							my $packet = pack('N', length($jwsm)) . $jwsm;
							$stream->write($packet => sub{});
						};
					}


					if ($@) { warn "Worker $$: Failed to send 'stop' state: $@" }
				}
				if (length($buffers{$id}) == 0) {
					$buffers{$id} = ''; # Clears out underlying allocated C-buffers in Perl's core
				}
			});
			$stream->on(close => sub {
				delete $buffers{$id};
			});
		});
		return $server;
	}
}

sub utility_stopper() {
	foreach my $t ( keys %{$gb::timeouts} ) {
		next if $t =~ /^__/;
		Mojo::IOLoop->remove($gb::timeouts->{$t}->{'loop'}) if $gb::timeouts->{$t}->{'loop'};
		$gb::timeouts->{$t}->{'subroutine'} = undef if $gb::timeouts->{$t}->{'subroutine'};
	}
	$log->info('Loop is crashing at ' . localtime(&subs::rightNow() / 1000 )->strftime('%a %D %I:%M:%S%P'));

	$gb::utility_functions_watcher = 0;
}

&manager_starter();

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
sub utility_runner() {
	return if $gb::utility_functions_watcher == 0;
	# The app's scheduled wake wants to know when the due work is done so it can
	# release the CPU before its 45s backstop. It is written only after a tick
	# that ran nothing, and removed as soon as a job starts, so a reader can tell
	# "everything due has finished" from "the tree is down or still working".
	my $idle_file = &subs::home('~/.president/utility_idle');
	my $ran = 0;
	my $next_due;
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
		if ($now < $slot->{'due'}) {
			$next_due = $slot->{'due'} if !defined $next_due || $slot->{'due'} < $next_due;
			next;
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
	# Nothing was due on this tick: everything this wake asked for has finished.
	# The app's receiver reads the mtime and lets the phone sleep early. Write it
	# only when a new beat has arrived since the last mark, not on every idle
	# tick - a five-second write would keep the flash busy for nothing - and only
	# when no job is about to fall due, so a release never skips a beat that is
	# already at the door.
	if (!$ran && (!defined $next_due || $next_due > &subs::rightNow() + 12000)) {
		my $ready_at = (-e &subs::home('~/.president/wake_ready')) ? ((stat(&subs::home('~/.president/wake_ready')))[9] || 0) : 0;
		my $idle_at = (-e $idle_file) ? ((stat($idle_file))[9] || 0) : 0;
		eval { write_file($idle_file, &subs::rightNow()); } if $ready_at > $idle_at;
	}
}

sub utility_functions() {

	$gb::utility_functions_watcher = 1;
	print "Starting Alarm Clock\n";

	require './Alarm.pl';
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
			if (!$gb::utility_adopted || $row_lc > $cur_lc) {
				foreach my $t ( keys %{$gb::timeouts} ) {
					next if $t =~ /^__/;
					Mojo::IOLoop->remove($gb::timeouts->{$t}->{'loop'}) if $gb::timeouts->{$t}->{'loop'};
				}
				$gb::timeouts = $controls->{$signatorial};
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


		$gb::timeouts->{'headless_browser'}->{'subroutine'} = sub {
			eval { &subs::headless_browser(); };
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
				if ($now - $gb::timeouts->{'tunnels'}->{'lasted_run'} >= ($interval * 1000) - 5000) {
					my $duty;
					if ($now - $gb::timeouts->{'tunnels'}->{'lasted_run'} > ($interval * 1000 * 12)) {
						$duty = 'restart';
					}
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
			my $interval = &subs::batch_interval($gb::timeouts, 'remote_machine_sync') || $gb::timeouts->{'remote_machine_sync'}->{'interval'};
			# utility_runner already holds this to its interval; the tolerance keeps
			# a call that lands a few milliseconds early from skipping a whole slot.
			if ($now - $gb::timeouts->{'remote_machine_sync'}->{'lasted_run'} >= ($interval * 1000) - 5000) {
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
			}
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
						&Websocket::send('server', { console => 'htopViewer();' });
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

		$gb::timeouts->{'manager'}->{'subroutine'} = sub {

		};
	}
}




# Resolve ~ once; this used to shell out to `echo $HOME` on every call.
my $home_dir;
sub home() {
	my ($inhabitant) = @_;
	unless (defined $home_dir) {
		$home_dir = $ENV{HOME};
		if (!defined $home_dir || $home_dir eq '') {
			$home_dir = (getpwuid($<))[7] || '';
		}
	}
	$inhabitant =~ s/~/$home_dir/;
	return $inhabitant;
}

sub device_setter() {
	my $device = 'computer';
	if ($config->{'device'}) {
		$device = $config->{'device'};
	}
	else {
		my $uname = `uname -a`;
		if ($uname =~ /Android/gi) {
			$device = 'mobile';
		}
		elsif ($uname =~ /Debian/gi) {
			$device = 'server';
		}
	}
	return $device;
}


