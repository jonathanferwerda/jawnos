#!/usr/bin/perl

use strict;
use warnings;
$| = 1; # Enable command autoflush

use FindBin qw($Bin);

# Change directory to the tree the script lives in (it lives in perl/)
chdir("$Bin/..") or die "Cannot change directory to $Bin/..: $!";
package President;

# The tree's lib/ must be on @INC before any `use` below can name a module that
# a package installs in lib/ instead of the system (Minion, Mojo::SQLite, a
# vendored dist). This used to sit after `use Minion`, which only worked because
# a checkout's local::lib or the distro had Minion already.
BEGIN {
	require File::Basename;
	require Cwd;
	my $dir = Cwd::abs_path(File::Basename::dirname(__FILE__));
	unshift @INC, "$dir/../lib" if $dir && -d "$dir/../lib";
}

print $0 ."\n";
print Cwd::getcwd() . "\n";
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
require JawnOS::Platform;
use JawnOS::Transport ();
use JawnOS::Platform::Ports ();

no warnings 'uninitialized'; 
# the gb globals below live in gb.pl and are written or read from every
# corner of the house; a file that touches one only once is not a typo
no warnings 'once';
my $working_dir = $0;
my $present_dir = Cwd::getcwd();

my $dump_dir = &home('~/.president');
$gb::dump_dir = $dump_dir;
#`rm -R $dump_dir/*` if -e $dump_dir;
`mkdir $dump_dir` unless -e $dump_dir;
my $server_dir = JawnOS::Platform::Paths::server_dir();
unless (-d $server_dir) {
	require File::Path;
	eval { File::Path::make_path($server_dir) };
}
my $duty_file = &home('~/.president/on_duty');
write_file($duty_file, 0);
my $status_file = &home('~/.president/status');
write_file($status_file, '') unless -e $status_file;
my $pid_file = &home('~/.president/pid');
write_file($pid_file, $$);

# The master can be SIGKILLed, and then nothing asks the tree to stop. Leave
# with it: see the note in perl/parent_guard.pl. Started here, before the heavy
# requires, so the watchdog is a small copy of this process.
require './perl/parent_guard.pl';
&parent_guard::start(tree => $$, master => JawnOS::Platform::parent_pid());
my $config_file = read_file(JawnOS::Platform::Paths::config_path());
my $config = decode_json $config_file;
our $logfile = &home($config->{'logfile'});
if (-e $logfile) {
#	`shred -u $logfile`;
}
write_file($logfile, '') if not -e $logfile;
our $log = Mojo::Log->new(path => $logfile);

# The tree's stop channel. Windows cannot signal a child cleanly (the runner's
# stop is TerminateProcess), so the master asks here and the ask becomes the
# same clean exit SIGINT performs. Served from this point, before the heavy
# requires, so a boot that stalls can still be stopped politely.
require './perl/control.pl';

sub tree_stop {
	my ($why) = @_;
	$why = 'asked over the tree control socket' unless defined $why && length $why;
	print "President stopping ($why); cleaning up...\n";
	$log->info("President stopping: $why") if $log;
	# Put back the power daemons this tree stopped before it goes away. A
	# restart or a clean quit must not leave the machine without a manager.
	eval {
		require "$FindBin::Bin/../lib/JawnOS/Domain/Power.pm";
		&subs::power_release_takeover();
	};
	my $power_error = $@;
	$log->warn('power: the takeover could not be restored on stop: ' . ($power_error =~ s/\s+/ /gr)) if $power_error;
	exit 0;
}

sub serve_tree_stop {
	my $args = JawnOS::Transport::server_args('tree') or return;
	# A tree that was killed leaves its socket behind; Mojo will not bind over it.
	unlink $args->{'path'} if $args->{'path'} && -e $args->{'path'};
	Mojo::IOLoop->server($args => sub {
		my ($loop, $stream, $id) = @_;
		$stream->handle->autoflush(1);
		my $buf = '';
		$stream->on(read => sub {
			my ($stream, $bytes) = @_;
			$buf .= $bytes;
			while ($buf =~ s/^([^\n]*)\n//) {
				my $out = &control::tree_handle($1, {
					pid => $$,
					version => ($config->{'version'} // ''),
					transport => JawnOS::Transport::tcp() ? 'tcp' : 'unix',
				});
				if (($out->{'action'} || '') eq 'stop') {
					$stream->write(encode_json({ ok => 1, cmd => 'stop' }) . "\n");
					Mojo::IOLoop->next_tick(sub { &tree_stop($out->{'reason'}) });
				}
				elsif (my $reply = $out->{'reply'}) {
					$stream->write(encode_json($reply) . "\n");
				}
			}
		});
	});
}

&serve_tree_stop();
if ($working_dir ne $present_dir) {
	# this file lives in perl/, so the tree is one level above the script.
	# FindBin exported $Bin into main, but this code runs in package President.
	my $new_dir = "$FindBin::Bin/..";
	print 'chdir to ' . $new_dir . "\n";
	chdir $new_dir;
	print Cwd::getcwd() . "\n";

}
#`espeak "president has begun"`;


my $environment = shift;

my $cache_dir = &home('~/') . '.president';
`mkdir -p $cache_dir` unless -e $cache_dir;

require './perl/gb.pl';
require './perl/AddressDirectory.pl';
# The Crew: this machine's abilities and the house's job placement. It calls
# &subs::... at run time and needs nothing loaded before it.
require './perl/crew.pl';
# The blocking jobs live here so a box without fork can start each by name in
# its own process; President passes the same sub to subprocessor as before.
require './perl/jobs.pl';
# The utility scheduler's bodies, loaded here so the forked child has them.
# (A worker loads the same file in perl/subprocessor_worker.pl.)
require './perl/utility_jobs.pl';

# The archive root (config.json archive_dir) gets one folder per location type,
# made here if it is missing. A blank archive_dir means this machine is not an
# archive and nothing happens.
my $archive_root = &subs::archive_scaffolder();
if ($archive_root->{'enabled'}) {
	my @made = @{$archive_root->{'created'}};
	$log->info('archive root ' . $archive_root->{'dir'} . (@made ? ' created: ' . join(', ', @made) : ' already in place'));
}

# A crash (or a SIGKILL) leaves the power takeover ledger behind. If this tree
# is not managing power - the person unchecked it, or turned it off before the
# crash - put the daemons back now. If it is managing, they are meant to stay
# stopped, and the first slow tick re-takes them after a boot.
eval {
	require "$FindBin::Bin/../lib/JawnOS/Domain/Power.pm";
	my $power_config = &subs::power_config();
	&subs::power_release_takeover() unless $power_config->{'manage'};
};
my $stale_power_error = $@;
$log->warn('power: the previous takeover could not be restored: ' . ($stale_power_error =~ s/\s+/ /gr)) if $stale_power_error;

$SIG{INT} = sub {
	# Do not print "President Died" here: ./jawn reads that phrase as a crash and
	# restarts the tree again, so a deliberate restart (which sends SIGINT) became
	# a restart loop on masters started before the jawn_deliberate guard. The
	# close handler and the liveness watchdog are what detect a real death.
	&tree_stop('SIGINT');
};

my @sockets = qw/ws alarm/;
foreach my $s ( @sockets ) {
	unlink $gb::tmp_dir . '/' . $s;
}
my $random_number = JawnOS::Platform::Ports::base(
	working_port => $config->{'working_port'},
	random       => 1,
);
my $on_duty = 0;
my $hour = localtime( &subs::rightNow() / 1000 )->strftime( "%H");

my $domain = $config->{'domain'} || '127.0.0.1';
#my $domain = '127.0.0.1';

my $device = &device_setter();
if ($device eq 'mobile') {
	# Take the lock for the boot. The wake-schedule worker below releases it as
	# soon as the Android app proves it is arming the short scheduled wakes.
	unlink &subs::home('~/.president/wake_lock_released');
	&subs::device_call('power.wake_lock');
	# sshd is started once per tree, below, by the 'sshd watcher' subprocessor - not
	# from a worker: Manager.pl is loaded into every worker of every server, so a
	# start there ran per worker and rested on whichever one happened to spawn it.
	# A bare `sshd` here also started a daemon with Termux's paths, and key auth
	# never worked (the phone, 2026-10-31).
}

if ($config->{'open_browser'} eq 'yes') {
	my $url = "https://127.0.0.1:$random_number/manager";
	if ($device eq 'mobile') {
		&subs::device_call('open.url', { url => $url });
	}
	elsif ($device eq 'computer') {
		# A detached open is enough, and removing `use threads` leaves the
		# no-fork Windows path with one concurrency model instead of two.
		if ($^O eq 'MSWin32') {
			system(1, 'cmd.exe', '/c', 'start', '', $url);
		}
		elsif ($^O eq 'darwin') {
			system(1, 'open', $url);
		}
		else {
			local $ENV{'DISPLAY'} = ':0';
			system(1, 'sh', '-c', 'chromium "$0" >/dev/null 2>&1 &', $url);
		}
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
# Mojolicious reads MOJO_MODE when each app object is built, and its default is
# development: with the hub configured as production the public listener still
# answered a failure with a stack trace. Manager.pl and Alarm.pl are separate
# processes, so set the mode here and let them inherit it. An empty value leaves
# the default alone.
if (defined $config->{'environment'} && $config->{'environment'} =~ /\S/) {
	$ENV{MOJO_MODE} = $config->{'environment'};
}
my $port = $random_number;
my $watch_port = $port + JawnOS::Platform::Ports::offset('watch');
my $ws_port = $port + JawnOS::Platform::Ports::offset('ws');
my $dock_port = $config->{'port'};
my $tty_port = $port + JawnOS::Platform::Ports::offset('bestow');
my $alarm_port = $port + JawnOS::Platform::Ports::offset('bell');
# The peer listener carries the house-CA leaf (scripts/house_ca.pl). It is a
# second listener, not a second certificate on the main one: a listener presents
# one certificate, and the main port must keep the public wildcard for browsers.
# The offset skips +1 (ws), +2 (watch), +3 (tty), +4 (tty ws) and +5 (alarm).
my $peer_port = JawnOS::Platform::Ports::port_for('peer', base => $port);
my $peer_certs = "";
if (-e "$server_dir/peer-fullchain.pem" && -e "$server_dir/peer-privkey.pem") {
	$peer_certs = "?cert=$server_dir/peer-fullchain.pem&key=$server_dir/peer-privkey.pem";
}
if ($config->{'environment'} eq 'development') {
	$ws_port = $port;
	$alarm_port = $port;
}

# The app's WebView cannot take the house's self-signed certificate for a
# WebSocket: onReceivedSslError trusts it for page loads only, and a handshake
# never reaches that callback. The socket server therefore also listens plainly
# on loopback. Chromium treats 127.0.0.1 as trustworthy, so the https page may
# open ws:// there; the page carries a short-lived token because a Secure
# session cookie is not sent on a ws:// handshake.
my $ws_plain_port = JawnOS::Platform::Ports::port_for(
	'ws_plain', base => $port, ws_port => $ws_port,
);


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
	# Workers leave with their manager at once where prctl exists (see
	# perl/parent_guard.pl); this heartbeat is the fallback on a platform that
	# has no PR_SET_PDEATHSIG, so a dead manager is noticed in a second rather
	# than the module's default of five. A worker still holding the listening
	# socket is a dead tree's port kept open.
	$prefork->heartbeat_interval(1);
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
	# The module logs a bare "Worker $pid stopped"; a purpose on the way out is
	# what tells the next reader which pool lost a worker, and a run of these
	# with no matching spawn is how a pool emptying presents itself.
	$prefork->on(reap => sub {
		my ($self, $pid) = @_;
		$log->info('worker exit purpose=' . ($ENV{PURPOSE} || '?') . " pid=$pid");
	});
	return $prefork;
}

# One place that starts an HTTP server, so portable mode can choose a
# single-process Daemon instead of Prefork without repeating the decision at
# every listener. Native behaviour is unchanged: the same prefork_tune, the
# same worker count, the same autoscale.
sub run_server {
	my ($app, $listeners, %opt) = @_;
	$ENV{'PURPOSE'} = $opt{'purpose'} if defined $opt{'purpose'};
	if (JawnOS::Platform::portable()) {
		my $daemon = Mojo::Server::Daemon->new(listen => $listeners);
		$daemon->load_app($app);
		$daemon->run;
		return;
	}
	# The floored subclass refuses a TTOU that would take `workers` below the
	# resting pool (prefork_autoscale.pl). Without it a shrink that outran the
	# real pool reached zero, and a zero-worker manager never spawns again.
	my $prefork = &prefork_tune(
		President::PoolPrefork->new(
			listen      => $listeners,
			min_workers => $opt{'autoscale_min'} || $opt{'workers'} || 1,
		),
		keep_alive => ($opt{'keep_alive'} ? 1 : 0),
	);
	$prefork->heartbeat_timeout(200);
	$prefork->load_app($app);
	$prefork->workers($opt{'workers'} || 1);
	&prefork_autoscale($prefork,
		min => $opt{'autoscale_min'},
		max => $opt{'autoscale_max'},
	) if $opt{'autoscale_min'};
	$prefork->run;
	return;
}

# Development keeps Morbo's file watcher on a native POSIX box; portable mode
# has no fork to spare, so it uses the same single Daemon as production.
sub run_dev_server {
	my ($app, %opt) = @_;
	$ENV{'PURPOSE'} = $opt{'purpose'} if defined $opt{'purpose'};
	if (JawnOS::Platform::portable()) {
		&run_server($app, [ split /,/, $ENV{'MOJO_LISTEN'} ], purpose => $opt{'purpose'});
		return;
	}
	my $morbo = Mojo::Server::Morbo->new;
	$morbo = $morbo->daemon(Mojo::Server::Daemon->new);
	$morbo->backend->watch(['./', './templates']) if $opt{'watch'};
	$morbo->run($app);
	return;
}

require './perl/President/prefork_autoscale.pl';

my @threads;

# One place that starts a server, so Windows (no fork) can spawn a real child
# while a box with fork keeps the subprocessor behaviour it has always had.
our @server_processes;
sub server_process {
	my ($app, $listeners, %opt) = @_;
	my @listen = ref $listeners eq 'ARRAY' ? @$listeners : split /,/, (defined $listeners ? $listeners : '');
	if (JawnOS::Platform::use_fork()) {
		return &subs::subprocessor(sub {
			$ENV{PURPOSE} = $opt{'purpose'} if $opt{'purpose'};
			$ENV{MOJO_LISTEN} = join ',', @listen if @listen;
			$opt{'dev'} ? &run_dev_server($app, purpose => $opt{'purpose'}, watch => $opt{'watch'})
			            : &run_server($app, \@listen, %opt);
		}, { name => $opt{'name'} });
	}
	require JawnOS::Platform::Server;
	my $child = JawnOS::Platform::Server::spawn(
		app => $app, purpose => $opt{'purpose'}, listen => \@listen, name => $opt{'name'},
	);
	push @server_processes, $child if $child;
	print 'Started ' . ($opt{'name'} || $opt{'purpose'} || 'server') . ' as pid ' . ($child->{'pid'} || '?') . "\n" if $child;
	return $child;
}
# On Windows the master cannot kill President's children when it stops
# President, so take each one down as this process leaves.
END { foreach my $c (@server_processes) { eval { $c->{'runner'}->stop } if $c } }
# A fatal exit is an exit too: put back the power daemons this tree took over.
# A SIGKILL never runs here; the next start's stale-ledger restore covers that.
END {
	eval {
		require "$FindBin::Bin/../lib/JawnOS/Domain/Power.pm";
		&subs::power_release_takeover();
	};
}

sub manager_starter() {
	my $ws_tty_port = $port + JawnOS::Platform::Ports::offset('coms');
	$ENV{PORT_AHOY} = $random_number;
	$ENV{PORT_MSG} = $ws_port;
	$ENV{PORT_WS_PLAIN} = $ws_plain_port if $config->{'environment'} eq 'production';
	$ENV{PORT_BELL} = $alarm_port;
	$ENV{PORT_BESTOW} = $tty_port;
	$ENV{PORT_DOCK} = $dock_port;
	# The port a board's own firmware serves on, not a door of ours. The sketches
	# in jp/, jt/ and jw/ hardcode 3000, so this is 3000 unless config.json says
	# otherwise - and it stays 3000 when PORT_DOCK moves off the entry port.
	$ENV{PORT_BOARD} = $config->{'board_port'} || 3000;
	$ENV{PORT_COMS} = $ws_tty_port;
	$ENV{PORT_ARM} = $watch_port;
	$ENV{PORT_PEER} = $peer_port if $peer_certs ne '';
	$ENV{PORT_ENV} = $config->{'environment'};
	$ENV{cookie_name} = 'president';

	# A fresh install has no certificate; issue a local self-signed one so the
	# TLS listeners can bind instead of dying before the panel is reachable.
	my $local_tls = eval {
		require JawnOS::Platform::TLS;
		JawnOS::Platform::TLS::ensure_local_cert(dir => $server_dir);
	};
	$log->error('local TLS: ' . $local_tls->{'error'})
		if $local_tls && $local_tls->{'error'};
	my $certs = "";

	if (-e "$server_dir/fullchain.pem" && -e "$server_dir/privkey.pem") {
		$certs = "?cert=$server_dir/fullchain.pem&key=$server_dir/privkey.pem";
	}
	# The door a board dials presents the house-CA leaf when there is one: its
	# SAN carries the LAN address the device used, which the public wildcard
	# certificate cannot. The dock, main, alarm and teletype doors keep $certs
	# for browsers.
	my $device_certs = $peer_certs ne '' ? $peer_certs : $certs;
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
	# The native surfaces (the launcher and the lock screen) read the desk's paint
	# from the settings table, not the WebSocket. Record it at boot so a machine
	# that has never seen a theme change still wears the one in charge (a running
	# appointment's, else the Misc choice).
	eval {
		my (undef, undef, $native_bg, $native_bundle, $native_name, $native_appointment) = &subs::theme_state();
		&subs::native_theme_record({
			background => $native_bg,
			accent => (ref $native_bundle eq 'HASH' ? $native_bundle->{'accent'} : ''),
			appointment => $native_appointment,
			theme => $native_name,
			signature => &subs::theme_signature()
		});
	};
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
	# Skipped on a controller: it keeps no APK store of its own, and every resident
	# loop is another ~16 MB PSS copy of this tree on a 1.8 GB box.
	unless ($device eq 'controller') {
		&subs::subprocessor(\&jobs::job_app_release_sync, { name => 'app release sync' });
	}

	# The slow background passes used to be one forked copy of the whole tree
	# each: seven processes mostly asleep, about fifty megabytes of private heap
	# apiece on a phone. None is time-critical at the minute level, so one
	# process runs them in order on their own slots. The app release sync keeps
	# its own process (pulling a 35MB APK can hold it for minutes), as do the
	# short-tick discovery loops and the servers with live connections.
	# Skipped on a controller: it runs no crew, crest, model, watch, balance or
	# crypto pass, and this one process is another ~16 MB PSS copy of the tree.
	unless ($device eq 'controller') {
		&subs::subprocessor(\&jobs::job_slow_loops, { name => 'slow loops' });
	}

	# The start menu's System card: every peer's battery and the embedded boards
	# the house can see. The peers answer /manager/health; the boards answer
	# /device_query. Both are cached, so the card never waits on a sleeping board.
	# Skipped on a controller: it polls no peers or boards, so the System card's
	# levels sync is another resident copy of the tree it never needs.
	unless ($device eq 'controller') {
		&subs::subprocessor(\&jobs::job_house_levels, { name => 'house levels' });
	}

	# mDNS is how a device names itself the moment it joins: fold what the local
	# network advertises (_jawnos._tcp, plus a printer on _ipp._tcp) into this
	# machine's device row on a short tick, so a plugged-in watch, deck or pico
	# appears with its purpose and abilities without anyone pressing Scan.
	&subs::subprocessor(\&jobs::job_device_mdns_sync, { name => 'device mdns sync' });

	# Advertise this House machine on the LAN. An embedded device browses
	# _jawnos-house._tcp when the homebase it was handed stops answering, so it
	# can move to another computer/mobile/server that is actually up instead of
	# going dark until someone runs Now Me again. The TXT carries the ports it
	# dials (arm/coms/bestow), not just the main one. Avahi renames the instance
	# if two machines share a name, which is fine: devices read the TXT.
	&subs::subprocessor(\&jobs::job_house_advertise, { name => 'house advertise' });

	# sshd: the login service the house dials on 8022. It is started and kept up
	# here, in President, once per tree - not in a worker, which would start a
	# daemon per worker and have it die with that worker's process group. The
	# heartbeat is what makes it survive a worker restart: the manager notices a
	# stopped subprocessor child and starts this loop again, and the loop probes
	# before it starts, so a daemon that is already up is left alone.
	# subs::sshd_start is a no-op on a machine that is not the Android app (see
	# subs::sshd_platform), and it does nothing at all when the prefix has no
	# sshd_config to read.
	&subs::subprocessor(\&jobs::job_sshd_watcher, { name => 'sshd watcher' });

	# A peer joining a network - the house wifi, a friend's, a hotspot - says so
	# with a small signed broadcast on that LAN. The listener refreshes the peer's
	# address on every machine that hears it and wakes the reconnector, so the
	# mesh resumes within seconds instead of waiting for the next tunnel check.
	# This is the path the phone and tablet use: Termux has no avahi, so mDNS
	# alone never reaches them.
	&subs::subprocessor(\&jobs::job_lan_presence_beacon, { name => 'lan presence beacon', fork => 1 });

	&subs::subprocessor(\&jobs::job_lan_presence_listener, { name => 'lan presence listener', fork => 1 });

	# The listener only leaves a cache stamp; this loop runs the mesh sync in its
	# own process so the listener is never blocked behind a pull.
	&subs::subprocessor(\&jobs::job_lan_mesh_wake, { name => 'lan mesh wake', fork => 1 });

	# A device that has never been on WiFi cannot be named by mDNS, and the tree
	# holds no address for it, so nothing ever connects and it stays invisible while
	# it sits on the desk. Every JawnOS board advertises the Nordic UART service, so
	# scan the radio for one whose address is unknown and connect, letting it name
	# itself over the link - the "plug it in and it is known" path, with no wifi at
	# all. This is discovery of an UNKNOWN board only: a watch that is already
	# linked reconnects on its own (the BLE bridge holds that link), so a slower
	# heartbeat costs nothing at the moment someone says "hey jawn". A scan holds
	# the radio for eight seconds, and the old thirty-second beat was most of the
	# phone's Bluetooth drain.
	# Skipped on a controller: it owns no BLE bridge to adopt an unknown board for,
	# and holding the radio is another resident copy of the tree.
	unless ($device eq 'controller') {
		&subs::subprocessor(\&jobs::job_ble_adopt_scan, { name => 'ble adopt scan', fork => 1 });
	}

	# The Android app's scheduled wake (JawnWakeReceiver) holds the CPU for a
	# short window each navigation interval. Once the app has proved it is
	# arming them (wake_ready is fresh), release the permanent Termux lock a
	# handheld used to need; take it back if the scheduler stops or the person
	# switches the schedule off. Music's own count file keeps its stream lock
	# safe: never release while a track is playing.
	#
	# The count only describes a stream while Music's state file exists: that
	# file is written when a stream starts and removed when it stops, so its
	# absence means no stream is being received and any count left in the wake
	# file is stale (a restart or crash mid-stream never decrements it).
	if ($device eq 'mobile') {
		&subs::subprocessor(\&jobs::job_wake_schedule, { name => 'wake schedule' });
	}

	# The house address book: this machine reports where it is when it boots and
	# whenever its own interfaces change. The wake report in utility_runner covers
	# a phone's scheduled beats; this covers a laptop moving between networks.
	&subs::subprocessor(\&jobs::job_address_directory, { name => 'address directory' });









	# The voice models ride the same mesh as the APKs, but they change rarely, so
	# this is a single pass after boot rather than a loop: a device that lacks a
	# voice pulls it in and can then serve it. Opening Configure -> Misc refreshes
	# them on demand (see the misc_setting_list route).
	&subs::subprocessor(\&jobs::job_voice_sync, { name => 'voice sync' });

	# The warm whisper.cpp server keeps the speech model loaded, so a clip skips
	# the per-call model load the one-shot CLI pays - but a machine that takes no
	# dictation and no call should not pay for the model either: at ggml-tiny it
	# is 147 MB resident, measured on the Gou's 1.8 GB. So the server is started
	# by demand. Any transcription request touches ~/.president/whisper-want
	# (subs::whisper_server_wanted); this loop starts the server while that marker
	# is fresh and stops the one it started once the house has been quiet for ten
	# minutes. whisper_local_transcribe still falls back to the CLI while the port
	# is quiet, so no request waits on this loop. A machine without the binary or
	# a model simply finds nothing to start until one is installed. The server
	# logs to its own file so a long-running tree's manager.log does not grow with
	# every clip. This loop is the only thing that ever forks it, and the loop
	# holds none of the pool's listeners - that is why it is started here and not
	# from a request worker, whose child would inherit them.
	&subs::subprocessor(\&jobs::job_whisper_server, { name => 'whisper server' });





	$ENV{'MOJO_MAX_LINE_SIZE'} = "64000";
	if ($config->{'environment'} eq 'development') {
		print "Starting Locker Server on port " . $dock_port . "\n";
		&server_process('./perl/Manager.pl', [ 'https://*:' . $dock_port . $certs ],
			purpose => 'locker', name => 'Dev Locker Server', dev => 1, watch => 1);
		if ($ENV{PORT_AHOY} != $ENV{PORT_MSG}) {
			print "Starting WS Server on port " . $ws_port . "\n";
			&server_process('./perl/Manager.pl', [ 'https://*:' . $ws_port . $device_certs ],
				purpose => 'websocket', name => 'Dev WS Server', dev => 1, watch => 1);
		}
		print "Starting Main Server on port " . $port . "\n";
		my @dev_main_listeners = ('https://*:' . $port . $certs,
			($peer_certs ne '' ? ('https://*:' . $peer_port . $peer_certs) : ()));
		&server_process('./perl/Manager.pl', \@dev_main_listeners,
			purpose => 'main', name => 'Dev Main Server', dev => 1, watch => 1);
	}
	elsif ($config->{'environment'} eq 'production') {

		# The locker is the local ticket desk: app_ticket.pl mints the forever
		# ticket on this port (config.json's `port`), the app opens
		# .shots/ticket.txt on it, and JawnFirstRun waits for it, so a handheld
		# needs it exactly as a desktop does. v0.1.2169 removed it with the tty
		# servers and the phone could no longer sign in; the master's watchdog,
		# which asks every configured port, then restarted the healthy tree
		# every 90 seconds.
		print "Starting Pro Locker Server on port " . $dock_port . "\n";
		&server_process('./perl/Manager.pl', [ 'https://*:' . $dock_port . $certs ],
			purpose => 'locker', name => 'Pro Locker Server', workers => 1);
		$log->info('after locker server');

		print "Starting Pro WS Server on port " . $ws_port . "\n";
		my @ws_listeners = ( 'https://*:' . $ws_port . $device_certs, 'http://127.0.0.1:' . $ws_plain_port );
		# The peer listener lives on the socket server in production: it is
		# the worker that already holds long-lived connections, and the same
		# app answers the peer routes there.
		push @ws_listeners, 'https://*:' . $peer_port . $peer_certs if $peer_certs ne '';
		&server_process('./perl/Manager.pl', \@ws_listeners,
			purpose => 'websocket', name => 'Pro WS Server', workers => 1, keep_alive => 1);
		$log->info('after ws server');

		print "Starting Pro Prefork Main Server on port " . $port . "\n";
		# A handheld runs this whole tree in a few hundred MB that Android's
		# low-memory killer reclaims the moment the device tightens, so the pool
		# stays small - but not one. A worker serves one request at a time, and on
		# a phone the single worker was busy for 30-60s every couple of minutes
		# (the log's autoscale lines), which queued the whole panel behind it:
		# the "Manager is frozen" after picking the phone up. Two resting workers
		# mean one slow request never holds the screen. Unlike a desktop, a phone
		# does not grow the pool: every extra worker was a fork of a 100 MB+
		# process, and that spike is what Android's killer reaped the tree for.
		# A burst waits behind the two instead; a desktop rests at three and a
		# server at four, each growing by two. `main_workers` in config.json
		# overrides the resting count when a machine wants another.
		my $configured_workers = (defined $config->{'main_workers'} && $config->{'main_workers'} =~ /^\d+$/ && $config->{'main_workers'} > 0)
			? int($config->{'main_workers'}) : 0;
		my $main_workers = $configured_workers || ($device eq 'controller' ? 2 : ($device eq 'mobile' ? 2 : ($device eq 'server' ? 4 : 3)));
		# A burst pool: `main_workers` is where the pool rests and
		# `main_workers_max` is the ceiling an interactive burst may reach.
		# Without a configured ceiling the old rule stands: a phone and a
		# controller rest, a desktop and a server grow by two.
		my $configured_max = (defined $config->{'main_workers_max'} && $config->{'main_workers_max'} =~ /^\d+$/ && $config->{'main_workers_max'} > 0)
			? int($config->{'main_workers_max'}) : 0;
		my $main_workers_max = $configured_max
			|| (($device eq 'mobile' || $device eq 'controller') ? $main_workers : $main_workers + 2);
		$main_workers_max = $main_workers if $main_workers_max < $main_workers;
		&server_process('./perl/Manager.pl', [ 'https://*:' . $port . $certs ],
			purpose => 'main', name => 'Pro Main Server',
			workers => $main_workers,
			autoscale_min => $main_workers,
			autoscale_max => $main_workers_max);
		$log->info('after main server');
		# A controller answers no alarm, runs no terminal and keeps no window
		# fleet, so none of these listeners has a client on it.
		unless ($device eq 'controller') {
			print "Starting Pro Prefork Alarm Server on port " . $alarm_port . "\n";
			&server_process('./perl/Alarm.pl', [ 'https://*:' . $alarm_port . $certs ],
				purpose => 'alarm', name => 'Pro Alarm Server', workers => 1, keep_alive => 1);
			$log->info('after alarm server');
		}

	}
	else {
		print "I have no environment!\n";
	}

	# A controller is a handheld with no terminal and no watch: treat it like a
	# server here, so the watch, teletype and tty-ws servers never start.
	if ($device ne 'server' && $device ne 'controller') {
		if ($config->{'environment'} eq 'development') {
			print "Starting Development Watch Server on $watch_port\n";
			&server_process('./perl/watch.pl', [ 'https://*:' . $watch_port . $device_certs ],
				purpose => 'watch', name => 'Watch Server', dev => 1);
		}
		elsif ($config->{'environment'} eq 'production') {
			print "Starting Pro Watch Server on port " . $watch_port . "\n";
			&server_process('./perl/watch.pl', [ 'https://*:' . $watch_port . $device_certs ],
				purpose => 'watch', name => 'Watch Server',
				workers => $device eq 'mobile' ? 1 : ($device eq 'server' ? 2 : 1));
		}

		# A handheld is not a Linux deck: a teletype session needs a shell on the
		# machine it runs on, and Android offers none. Both listeners were a whole
		# app each for a door nothing on a phone opens.
		if ($device ne 'mobile') {
			if ($config->{'environment'} eq 'development') {
				print "Starting Development TTY Server on $tty_port\n";
				&server_process('./perl/teletype.pl', [ 'https://*:' . $tty_port . $device_certs ],
					purpose => 'teletype', name => 'TTY Server', dev => 1);
			}
			elsif ($config->{'environment'} eq 'production') {
				print "Starting Pro TTY Server on port " . $tty_port . "\n";
				&server_process('./perl/teletype.pl', [ 'https://*:' . $tty_port . $device_certs ],
					purpose => 'teletype', name => 'TTY Server',
					workers => $device eq 'mobile' ? 1 : ($device eq 'server' ? 3 : 2), keep_alive => 1);
			}
			# The deck's control channel carries keystrokes, pointer movement and
			# button presses, so it is TLS like every other listener. This is the
			# wss port handed to a device as PORT_COMS / now_me's twshomebase.
			if ($config->{'environment'} eq 'development') {
				print "Starting Development TTYwss Server on $ws_tty_port\n";
				&server_process('./perl/teletype.pl', [ 'https://*:' . $ws_tty_port . $device_certs ],
					purpose => 'teletype', name => 'TTY WS Server', dev => 1);
			}
			elsif ($config->{'environment'} eq 'production') {
				print "Starting Pro TTYwss Server on port " . $ws_tty_port . "\n";
				&server_process('./perl/teletype.pl', [ 'https://*:' . $ws_tty_port . $device_certs ],
					purpose => 'teletype', name => 'TTY WS Server', workers => 1, keep_alive => 1);
			}
		}
	}




	my $uthr;
	my @results;
	# The Bluetooth SCO gateway. A machine that has the helper built (the laptop
	# now, the Odroid Go in a bag later) also has an adapter to hold the link;
	# one that does not pays nothing and answers "not built" on the routes.
	if (-x './perl/sco/sco_helper') {
		# Only the machine the house named as the gateway listens on the
		# network and arms the phone's calls. Another helper box in the same
		# house (a dev machine, a spare laptop) would otherwise mint a second
		# sco_token and re-arm the same plan every few minutes. A machine named
		# in ivr_machine is the gateway; no name means this one, and an explicit
		# sco_gateway keeps the older remote-puck arrangement.
		my $ivr_machine = eval { &subs::phone_ivr_grab('ivr_machine') } || '';
		my $self_sig = eval { &subs::signatorial_designer() } || '';
		my $sco_named = eval { &subs::setting_grabber({ app => 'misc', setting => 'sco_gateway', device => 'all', benign => 1 }) } || '';
		my $is_gateway = !length($ivr_machine) || (length($self_sig) && $ivr_machine eq $self_sig) || length($sco_named);
		# The network face is what lets a phone with no helper of its own use
		# this machine's adapter. The port is the house's; the secret is one
		# value for the house, minted once here, and never logged. Sco.pl
		# refuses a line on that face without it.
		my $sco_port = eval { &subs::setting_grabber({ app => 'misc', setting => 'sco_port', device => 'all', benign => 1 }) } || '';
		$sco_port = 45700 unless $sco_port =~ /^\d{1,5}$/ && $sco_port > 0 && $sco_port < 65536;
		my $sco_token = eval { &subs::setting_grabber({ app => 'misc', setting => 'sco_token', device => 'all', benign => 1 }) } || '';
		unless (length $sco_token || !$is_gateway) {
			$sco_token = eval {
				require Crypt::PRNG;
				Crypt::PRNG::random_bytes_hex(16);
			} || &subs::random_string_creator(32);
			eval { &subs::setting_setter({ app => 'misc', setting => 'sco_token', value => $sco_token, device => 'all' }) };
		}
		# A token no device can read would expose a face nobody can use.
		my $stored_token = eval { &subs::setting_grabber({ app => 'misc', setting => 'sco_token', device => 'all', benign => 1 }) } || '';
		my @sco_face = ($is_gateway && length($sco_token) && $stored_token eq $sco_token)
			? ('--listen', '0.0.0.0:' . $sco_port, '--token', $sco_token)
			: ();
		$log->error('sco gateway: could not store the house sco_token; the network face is off')
			unless @sco_face || !$is_gateway;
		&subs::subprocessor(sub {
			$ENV{PURPOSE} = 'sco';
			# Sco.pl reads @ARGV, so the face is handed to it in its own
			# child; the master's arguments belong to ./jawn.
			local @ARGV = @sco_face;
			require './perl/Sco.pl';
		}, { name => 'SCO Gateway' });
		# Reception keeps that gateway armed from the phone's own settings, so a
		# caller is answered even when no page is open anywhere. It runs only
		# on the gateway, so one plan has one armer.
		if ($is_gateway) {
			&subs::subprocessor(sub {
				$ENV{PURPOSE} = 'reception';
				require './perl/Reception.pl';
			}, { name => 'Phone Reception' });
		}
	}
	my $f_status = read_file($status_file);
	my $socket_watch = &socket_watch($dump_dir . '/memory');
	if (-e $status_file) {

		write_file($status_file, 'good');
		print "wrote status good\n";
	}
	# Skipped on a controller: serving a model is another resident process on a
	# box that only shows a launcher and bridges calls.
	unless ($device eq 'controller') {
		my $ollama = JawnOS::Platform::tool_path('ollama');
		if ($ollama && `"$ollama" -v` =~ /client version is/) {
			&subs::subprocessor(sub {
				`OLLAMA_IGPU_ENABLE=1 OLLAMA_VULKAN=1 HIP_VISIBLE_DEVICES=-1 OLLAMA_NOHISTORY=1 ollama serve`;
			}, { name => 'ollama serve' });
		}
	}
	# The scheduler behind the alarms, navigation and sync slots. It reads
	# President's own $gb state and runs in its own process like the rest: a box
	# with fork keeps that child and its own loop, and a box without fork starts
	# perl/subprocessor_worker.pl by name. The environment the bodies read is
	# stamped here so the forked child inherits it; a worker fills the same
	# globals from subroutines.pl (see jobs::job_utility_functions).
	$President::config = $config;
	$President::device = $device;
	&subs::subprocessor(\&jobs::job_utility_functions, { name => 'utility functions' });

	# The archive queue's worker. Jobs are enqueued from the web process into
	# the same SQLite file under ~/.president; one at a time, so a slow link is
	# never asked for two files at once and the queue keeps its order.
	# Skipped on a controller: the archive queue's worker is another full copy of
	# the tree, and a 1.8 GB launcher has no archiving to do.
	unless ($device eq 'controller') {
		&subs::subprocessor(\&jobs::job_minion_worker, { name => 'Minion Worker' });
		# The CloudSync sweep runs in its own child: the Minion worker's loop
		# reset would drop a timer armed in it, and a folder changed while no
		# Folders window is open has to reach the other machines on its own.
		&subs::subprocessor(\&jobs::job_cloud_sync_sweep, { name => 'cloud sync sweep' });
	}

	# The evaluation schedules live in this machine's queue, but the cadence that
	# asks for them is a shared setting. Re-read the wishes every few minutes so a
	# machine that stays up learns of a cadence changed on a peer, and so every
	# machine holds the schedules that let it take the night over when the chosen
	# machine is quiet.
	# Skipped on a controller: it takes no part in the evaluation night, and each
	# loop is another resident copy of the tree.
	unless ($device eq 'controller') {
		&subs::subprocessor(\&jobs::job_evaluation_schedules, { name => 'evaluation schedules' });
	}

	# The evaluation dispatch: the server assigns each scheduled run to a ready
	# worker a few minutes before it is due, and every machine turns an assignment
	# addressed to it into a queued job. The ledger travels with the ordinary sync,
	# so a partition that cannot see the dispatcher has no fresh assignment and
	# stands down instead of running the same report twice.
	# Skipped on a controller: it takes no part in the evaluation night, and each
	# loop is another resident copy of the tree.
	unless ($device eq 'controller') {
		&subs::subprocessor(\&jobs::job_evaluation_dispatch, { name => 'evaluation dispatch' });
	}
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

require './perl/President/get_internal_db.pl';



sub socket_watch() {
	my ($watch_file) = @_;
	my %buffers;
	eval {
		my $args = JawnOS::Transport::server_args('memory', path => $watch_file);
		my $server;
		if ($args) {
			$server = Mojo::IOLoop->server($args => sub {
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
	        next unless ref $query eq 'HASH';
	        next if JawnOS::Transport::tcp()
	            && !JawnOS::Transport::token_ok($query->{'token'});


					
          my $duty = $query->{'duty'} // '';
					if ($duty eq 'ai') {

						$log->info('A.I. Called');

						# The query carries the person's words (and possibly a key): name its
						# shape, never its content.
						$log->info('A.I. query fields: ' . join(',', sort keys %{$query}));






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
	}
	return $server;
}
}

require './perl/President/utility_stopper.pl';

&manager_starter();





# Resolve ~ once; this used to shell out to `echo $HOME` on every call.
my $home_dir;
sub home() {
	my ($inhabitant) = @_;
	unless (defined $home_dir) {
		$home_dir = JawnOS::Platform::Paths::home();
	}
	$inhabitant =~ s/~/$home_dir/;
	return $inhabitant;
}

sub device_setter() {
	my $device = 'computer';
	if ($config->{'device'}) {
		$device = $config->{'device'};
	}
	elsif ($^O eq 'MSWin32' || $^O eq 'darwin') {
		$device = 'computer';
	}
	elsif (-e '/system/bin/init' || $ENV{'ANDROID_ROOT'} || $ENV{'TERMUX_VERSION'}) {
		$device = 'mobile';
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


