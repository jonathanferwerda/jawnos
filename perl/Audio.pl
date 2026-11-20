#!/usr/bin/perl

# Audio: keep this machine's one audio engine running.
#
# The engine (perl/audio/jawn-audio, built by scripts/build_engine.pl) is
# optional: a machine with no Rust toolchain has no binary and Studio falls back
# to the browser. But on a machine that has one, something has to own it, or the
# first crash leaves the card silent until a person notices. This is that
# owner: one supervisor per machine, one child per supervisor.
#
# It is deliberately NOT started by a web request. A request that forks a daemon
# leaves a process no worker owns and no restart stops. President starts it
# beside Sco.pl and Reception.pl when the engine binary is staged, as a real
# child (`fork => 1`), so the master owns it and a restart stops it.
#
# The five decisions that matter:
#
#   adopt    a supervisor killed with SIGKILL leaves its engine behind, still
#            holding ~/.president/audio.sock. Before spawning, a `status`
#            command is sent over that socket: if it answers ok:true the engine
#            is live and is adopted instead of starting a second one. A bare
#            connect proves only that something listens; the command proves it
#            speaks this protocol and is healthy. The status file then names no
#            child pid and says adopted true, and the socket is polled. The
#            supervisor spawns its own engine only once the adopted one stops
#            answering. A socket file with nothing behind it is a stale crash
#            remnant: it is removed and an engine is started as usual.
#   orphan   a socket that does not answer can still have an older or wedged
#            engine behind it. Before spawning, /proc/<pid>/cmdline is scanned
#            for this binary with `--serve` on this socket. Such a process is
#            asked to quit over the socket and waited for; when it does not go
#            (the boot wipe removes the socket file it would be reached on) the
#            same TERM-then-KILL ladder that ends this supervisor's own child
#            applies to it, and only then is an engine started. A process that
#            is not this binary on this socket is never signalled, and no
#            second engine is ever started. A refused spawn never ends the
#            supervisor: it records why and retries.
#   lock     an flock on ~/.president/audio.lock. A second supervisor says one
#            sentence and exits 1 instead of starting a second engine on the
#            same socket. flock is held by the kernel for the life of the open
#            file description, so a SIGKILL releases it; the lock file itself is
#            never unlinked, because unlinking it would let a third supervisor
#            create a different inode and run beside the second.
#   backoff  1, 2, 5, 10, 30 seconds, indexed by consecutive quick failures. An
#            engine that ran for LONG_RUN seconds is treated as healthy, so its
#            next crash starts the ladder again at 1s. A crash loop is slowed
#            rather than allowed to spin.
#   status   ~/.president/audio.json, written atomically (temp file + rename)
#            after every start and every exit, so --status never reads half a
#            file. The child's pid is null while it is down, so --check is 1
#            during a backoff even though the supervisor is alive.
#   signals  TERM and INT set a flag; the loop stops the child (TERM, then KILL
#            after a grace), reaps it, unlinks the status file and exits 0. A
#            clean exit leaves no detached engine behind.
#
# A missing binary is reported once, not once per retry: the engine stays
# optional, and the supervisor waits at the backoff cap rather than spinning.
use strict;
use warnings;

use Cwd qw(abs_path);
use Errno qw(EPERM);
use Fcntl qw(:flock F_GETFD F_SETFD FD_CLOEXEC);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use JSON::PP ();
use POSIX ();
use Socket qw(SOCK_STREAM);
use Sys::Hostname ();
use Time::HiRes qw(sleep time);

# The ladder, and the two slow paths. A one-second poll is fast enough to notice
# a signal while a child is running and cheap enough to be invisible.
my @RESTART_DELAYS = (1, 2, 5, 10, 30);
my $LONG_RUN       = 30;
my $MISSING_RETRY  = 30;
my $STOP_GRACE     = 5;
my $POLL           = 0.25;
# A live engine answers in microseconds; one second is long enough to tell a
# healthy engine from a wedged one without making a crash take long to notice.
my $PROBE_TIMEOUT  = 1;
my $ADOPT_POLL     = 1;
# How long a supervisor waits for an engine it found but did not start to leave
# before deciding it cannot safely spawn a second one.
my $ORPHAN_GRACE   = 5;

my $script     = abs_path(__FILE__) // __FILE__;
my $script_dir = dirname($script);
my $root       = dirname($script_dir);

# The system-mix lifecycle lives in the tree's lib/ because the manager uses
# the same module when the switch changes. The supervisor is run from this
# tree, so the absolute path is stable; a build without it simply has no
# system mix to make.
my $system_mix_loaded = 0;
sub load_system_mix {
	return $system_mix_loaded if $system_mix_loaded;
	my $path = "$root/lib/JawnOS/Audio/SystemMix.pm";
	return 0 unless -f $path;
	unshift @INC, "$root/lib";
	require $path;
	$system_mix_loaded = 1;
	return 1;
}

# The engine's path rules and the one-time migration out of the wiped run
# directory live in the tree's lib/ beside SystemMix. Loaded by absolute path
# for the same reason: the supervisor is run from this tree.
my $engine_loaded = 0;
sub load_engine {
	return $engine_loaded if $engine_loaded;
	my $path = "$root/lib/JawnOS/Audio/Engine.pm";
	return 0 unless -f $path;
	unshift @INC, "$root/lib";
	require $path;
	$engine_loaded = 1;
	return 1;
}

sub home_dir {
	my $home = $ENV{'HOME'};
	return $home if defined $home && length $home;
	my $passwd = eval { (getpwuid($<))[7] };
	return $passwd if defined $passwd && length $passwd;
	return '.';
}

# This machine's name, from the core Sys::Hostname rather than a shell-out, so
# a supervisor started with no --machine still names the host it owns.
sub host_name {
	my $name = eval { Sys::Hostname::hostname() };
	return $name if defined $name && length $name;
	return 'local';
}

my $home        = home_dir();
my $state_dir   = "$home/.president";
my $status_path = "$state_dir/audio.json";
my $lock_path   = "$state_dir/audio.lock";

# Flags, then the environment, then the defaults. The environment names are the
# ones the engine and JawnOS::Audio::Engine already read, so a supervisor, a
# probe and a test can point at one path without a second convention.
sub pick {
	my ($flag, $env, $default) = @_;
	return $flag if defined $flag && length $flag;
	my $from_env = $ENV{$env};
	return $from_env if defined $from_env && length $from_env;
	return $default;
}

sub usage {
	return <<'USAGE';
Usage: perl perl/Audio.pl [options]
   or: perl perl/Audio.pl --status
   or: perl perl/Audio.pl --check

Keeps this machine's one audio engine (perl/audio/jawn-audio --serve) running.
It restarts the engine when it exits, at 1, 2, 5, 10 and then 30 second
intervals, and refuses to run beside a second supervisor.

On start it adopts a live engine left on the socket by a killed supervisor
(a `status` command over that socket must answer with "ok": true) instead of
starting a second one, and starts its own only after the adopted engine stops
answering. An engine that is alive but does not answer is identified by its
command line, asked to quit, and sent TERM then KILL if it will not. A socket
file with nothing behind it is removed and replaced. A clean stop asks an
adopted engine to quit, so no engine is left behind.

Options:
  --backend NAME   audio backend: null, alsa, pipewire or jack (default alsa)
  --device NAME    ALSA PCM name (default hw:1,0)
  --period N       period/block size in frames (default 64)
  --buffer N       buffer size in frames (default 256)
  --socket PATH    control socket (default ~/.president/audio.sock)
  --binary PATH    engine binary (default perl/audio/jawn-audio under this tree)
  --plan PATH      the saved-plan wrapper the engine restores from at startup
                   (default $XDG_STATE_HOME/jawnos/audio/audio-plan.json,
                   else ~/.local/state/jawnos/audio/audio-plan.json)
  --machine NAME   which machine this supervisor owns (default the host name)
  --system-device NAME  capture the machine's own mix from this source instead
                   of the supervisor-made jawn_system.monitor
  --handset-device NAME  the reception mixer's call source a `handset` plan
                   source taps (default jawn_call_in.monitor)
  --status         print ~/.president/audio.json and exit
  --check          exit 0 while the supervisor and its engine are alive,
                   1 otherwise (an adopted engine counts while it answers)
  --help           this text

Config, highest precedence first: these flags, then JAWNOS_AUDIO_SOCKET,
JAWNOS_AUDIO_BINARY, JAWNOS_AUDIO_BACKEND, JAWNOS_AUDIO_DEVICE,
JAWNOS_AUDIO_PERIOD, JAWNOS_AUDIO_BUFFER, JAWNOS_AUDIO_PLAN,
JAWNOS_AUDIO_MACHINE, JAWNOS_AUDIO_SYSTEM_DEVICE and
JAWNOS_AUDIO_HANDSET_DEVICE, then the defaults above.

The status file is written while the supervisor runs and removed on a clean
stop. Its keys are: pid (the engine child, null while it is down or while an
engine is adopted), adopted (true while an engine found at start is answering),
adopted_since (when that adoption began), supervisor_pid, socket, binary,
backend, device, period, buffer, plan, machine, system_device,
handset_device, started_at, engine_started_at, restarts, last_exit,
consecutive_restarts, backoff and updated_at.
USAGE
}

sub fatal {
	my ($message) = @_;
	print STDERR "audio supervisor: $message\n";
	exit 2;
}

# --- engine probe ---------------------------------------------------------------

# One request, one reply, both bounded. A bare connect would prove only that
# something listens; a stale or wedged socket can pass that. Asking for status
# proves the peer speaks the engine's line protocol and still answers. A
# timeout, a closed connection and a reply that is not an ok object are all the
# same answer here: no live engine.
sub engine_command {
	my ($path, $request) = @_;
	return undef unless defined $path && length $path && -S $path;
	require IO::Socket::UNIX;
	require IO::Select;
	my $socket = eval {
		IO::Socket::UNIX->new(
			Type    => SOCK_STREAM,
			Peer    => $path,
			Timeout => $PROBE_TIMEOUT,
		)
	};
	return undef unless $socket;
	$socket->autoflush(1);

	my $line = eval { JSON::PP->new->canonical->encode($request) };
	unless (defined $line && length $line) {
		close $socket;
		return undef;
	}
	unless (eval { $socket->print($line . "\n") }) {
		close $socket;
		return undef;
	}

	my $reply;
	my $select = IO::Select->new($socket);
	if ($select->can_read($PROBE_TIMEOUT)) {
		local $/ = "\n";
		$reply = <$socket>;
	}
	close $socket;
	return undef unless defined $reply && length $reply;

	my $data = eval { JSON::PP->new->decode($reply) };
	return ref $data eq 'HASH' ? $data : undef;
}

# The socket is a live engine only when its status answer is ok. The engine's
# idle status is {"ok":true,"take":0,"state":"idle"}, so an ok object is also
# the engine's own way of saying it is ready for another command.
sub engine_answers {
	my ($path) = @_;
	my $reply = engine_command($path, { cmd => 'status' });
	return 0 unless $reply && $reply->{'ok'};
	return $reply;
}

# --- command line -------------------------------------------------------------

my (%given, $mode);
$mode = 'run';
my @argv = @ARGV;
while (@argv) {
	my $arg = shift @argv;
	if ($arg eq '--help' || $arg eq '-h') {
		print usage();
		exit 0;
	}
	elsif ($arg eq '--status') { $mode = 'status' }
	elsif ($arg eq '--check')  { $mode = 'check' }
	elsif ($arg =~ /^--(socket|binary|backend|device|period|buffer|plan|machine|system-device|handset-device)$/) {
		my $name = $1;
		fatal("--$name needs a value") unless @argv;
		$given{$name} = shift @argv;
	}
	elsif ($arg =~ /^--(socket|binary|backend|device|period|buffer|plan|machine|system-device|handset-device)=(.*)$/s) {
		$given{$1} = $2;
	}
	else {
		fatal("unknown argument: $arg (try --help)");
	}
}

my $socket  = pick($given{'socket'},  'JAWNOS_AUDIO_SOCKET',  "$state_dir/audio.sock");
my $binary  = pick($given{'binary'},  'JAWNOS_AUDIO_BINARY',  "$root/perl/audio/jawn-audio");
my $backend = pick($given{'backend'}, 'JAWNOS_AUDIO_BACKEND', 'alsa');
my $device  = pick($given{'device'},  'JAWNOS_AUDIO_DEVICE',  'hw:1,0');
my $period  = pick($given{'period'},  'JAWNOS_AUDIO_PERIOD',  '64');
my $buffer  = pick($given{'buffer'},  'JAWNOS_AUDIO_BUFFER',  '256');
# The plan, the picker's pair and the system-mix state are durable: they
# live under the XDG state dir, outside ~/.president, which ./jawn wipes at
# boot. The socket, the status file and the lock stay in the run dir.
my $default_plan = "$home/.local/state/jawnos/audio/audio-plan.json";
$default_plan = JawnOS::Audio::Engine::audio_engine_plan_path() if load_engine();
my $plan    = pick($given{'plan'},    'JAWNOS_AUDIO_PLAN',    $default_plan);
my $audio_dir = dirname($plan);
my $machine = pick($given{'machine'}, 'JAWNOS_AUDIO_MACHINE', host_name());
my $system_device = pick($given{'system-device'}, 'JAWNOS_AUDIO_SYSTEM_DEVICE', '');
my $handset_device = pick($given{'handset-device'}, 'JAWNOS_AUDIO_HANDSET_DEVICE', '');

fatal('--socket wants a path') unless length $socket;
fatal('--binary wants a path') unless length $binary;
fatal('--backend wants a name') unless length $backend;
fatal('--device wants a name') unless length $device;
fatal('--period wants a positive whole number of frames')
	unless $period =~ /\A[1-9][0-9]*\z/;
fatal('--buffer wants a positive whole number of frames')
	unless $buffer =~ /\A[1-9][0-9]*\z/;
fatal('--plan wants a path') unless length $plan;
fatal('--machine wants a name') unless length $machine;
fatal('--system-device wants a source name')
	if length $system_device && $system_device !~ /\A[A-Za-z0-9_.:,-]+\z/;
fatal('--handset-device wants a source name')
	if length $handset_device && $handset_device !~ /\A[A-Za-z0-9_.:,-]+\z/;

# A handset source is opt-in in the plan, and the engine already defaults the
# source to `jawn_call_in.monitor`. The supervisor records the effective value
# but passes the flag only when a person named one: an older staged binary that
# predates the flag must keep starting, and the engine still binds the default.
my $handset_given = ( defined $given{'handset-device'} && length $given{'handset-device'} )
	|| ( defined $ENV{'JAWNOS_AUDIO_HANDSET_DEVICE'} && length $ENV{'JAWNOS_AUDIO_HANDSET_DEVICE'} )
	? 1 : 0;
unless ( length $handset_device ) {
	no warnings 'once';    # the constant is read from the module that owns it
	$handset_device = load_system_mix()
		? ( $JawnOS::Audio::SystemMix::handset_source // '' ) : '';
	$handset_device = 'jawn_call_in.monitor' unless length $handset_device;
}

# --- status and check ---------------------------------------------------------

sub read_status {
	return undef unless -s $status_path;
	open(my $fh, '<', $status_path) or return undef;
	local $/;
	my $raw = <$fh>;
	close $fh;
	my $data = eval { JSON::PP->new->decode($raw) };
	return ref $data eq 'HASH' ? $data : undef;
}

sub pid_alive {
	my ($pid) = @_;
	return 0 unless defined $pid && $pid =~ /\A[0-9]+\z/ && $pid > 0;
	return 1 if kill(0, $pid);
	# A process owned by another user exists but cannot be signalled.
	return $! == EPERM ? 1 : 0;
}

if ($mode eq 'status') {
	my $data = read_status();
	unless ($data) {
		print STDERR "audio supervisor: no status file at $status_path\n";
		exit 1;
	}
	print JSON::PP->new->canonical->pretty->encode($data);
	exit 0;
}

if ($mode eq 'check') {
	my $data = read_status() or exit 1;
	# The supervisor must be the one that wrote the file. An adopted engine has
	# no child pid, so liveness there is the socket's answer rather than a kill.
	exit 1 unless pid_alive($data->{'supervisor_pid'});
	if ($data->{'adopted'}) {
		my $path = $data->{'socket'};
		$path = $socket unless defined $path && length $path;
		exit(engine_answers($path) ? 0 : 1);
	}
	exit(pid_alive($data->{'pid'}) ? 0 : 1);
}

# --- one supervisor per machine ----------------------------------------------

make_path($state_dir) unless -d $state_dir;
fatal("cannot create $state_dir: $!") unless -d $state_dir;
make_path($audio_dir) unless -d $audio_dir;
fatal("cannot create $audio_dir: $!") unless -d $audio_dir;
open(my $lock, '>>', $lock_path)
	or fatal("cannot open the lock $lock_path: $!");
# Close the lock in the child's exec rather than only in fork: an inherited
# descriptor would keep the lock held after the supervisor is gone.
my $lock_flags = fcntl($lock, F_GETFD, 0);
fcntl($lock, F_SETFD, ($lock_flags // 0) | FD_CLOEXEC) if defined $lock_flags;
unless (flock($lock, LOCK_EX | LOCK_NB)) {
	print STDERR "audio supervisor: another audio supervisor already holds $lock_path; not starting a second one\n";
	exit 1;
}

# One-time move out of the run directory the old build used. The boot wipe
# would otherwise delete a plan (and the system-mix state beside it) written
# before the restart; a file already at the durable path wins. A hand-run
# --plan or JAWNOS_AUDIO_PLAN is never migrated into, so a test cannot pull a
# real file into its tempdir.
load_engine()
	&& JawnOS::Audio::Engine::audio_engine_plan_migrate();

# --- state --------------------------------------------------------------------

my $supervisor_pid   = $$;
my $supervisor_start = time;
my $child_pid;
my $child_started;
my $restarts              = 0;
my $consecutive_restarts  = 0;
my $backoff               = 0;
my $last_exit;
my $missing_said          = 0;
my $stop                  = 0;
my $next_start            = 0;
my $adopted;
my $adopted_since;
my $adopted_mismatch;
my $adopted_note;
my $next_probe            = 0;
my $next_sync             = 0;
my $active_system_device  = undef;
my $active_system_mode    = undef;
# The output a PipeWire engine must play through instead of `default`, which
# would be our own sink once the mix has moved it.
my $active_playback_device = undef;
# Why the last spawn attempt started no engine, for the status file and the
# retry below. Never a reason to stop supervising.
my $spawn_refused;

sub write_status {
	my $data = {
		pid                  => $child_pid,
		adopted              => $adopted ? JSON::PP::true : JSON::PP::false,
		adopted_since        => defined $adopted_since ? int($adopted_since) : undef,
		adopted_mismatch     => $adopted_mismatch ? JSON::PP::true : JSON::PP::false,
		adopted_note         => $adopted_note,
		supervisor_pid       => $supervisor_pid,
		socket               => $socket,
		binary               => $binary,
		backend              => $backend,
		device               => $device,
		mode                 => $active_system_mode,
		period               => 0 + $period,
		buffer               => 0 + $buffer,
		plan                 => $plan,
		machine              => $machine,
		system_device        => $active_system_device,
		handset_device       => $handset_device,
		started_at           => int($supervisor_start),
		engine_started_at    => defined $child_started ? int($child_started) : undef,
		restarts             => $restarts,
		last_exit            => $last_exit,
		consecutive_restarts => $consecutive_restarts,
		backoff              => $backoff,
		updated_at           => int(time),
	};
	my $json = JSON::PP->new->canonical->encode($data);
	my $tmp  = "$status_path.$$.tmp";
	my $fh;
	unless (open($fh, '>', $tmp)) {
		warn "audio supervisor: cannot write $tmp: $!\n";
		return;
	}
	print {$fh} $json, "\n";
	close $fh;
	rename($tmp, $status_path)
		or do {
			warn "audio supervisor: cannot replace $status_path: $!\n";
			unlink $tmp;
		};
	return 1;
}

sub describe_wait {
	my ($raw) = @_;
	return 'signal ' . POSIX::WTERMSIG($raw) if POSIX::WIFSIGNALED($raw);
	return 'exit ' . POSIX::WEXITSTATUS($raw) if POSIX::WIFEXITED($raw);
	return "status $raw";
}

# --- an engine this supervisor cannot see -------------------------------------

sub read_cmdline {
	my ($pid) = @_;
	open(my $fh, '<:raw', "/proc/$pid/cmdline") or return undef;
	local $/;
	my $raw = <$fh>;
	close $fh;
	return undef unless defined $raw && length $raw;
	return [ split /\0/, $raw ];
}

# Is this process the engine binary? A native engine is argv[0]; a script is
# reached through its interpreter, so its path is argv[1]. `/proc/<pid>/exe`
# also covers a staged binary that was replaced or deleted while it ran.
sub runs_binary {
	my ($pid, $args, $binary) = @_;
	my $abs = abs_path($binary);
	for my $index (0, 1) {
		my $arg = $args->[$index];
		next unless defined $arg && length $arg;
		return 1 if $arg eq $binary;
		return 1 if defined $abs && $arg eq $abs;
	}
	my $exe = readlink("/proc/$pid/exe");
	return 1 if defined $exe && defined $abs && $exe eq $abs;
	return 0;
}

sub serves_socket {
	my ($args, $socket) = @_;
	my ($serve, $path) = (0, undef);
	for (my $i = 0; $i < @$args; $i++) {
		my $arg = $args->[$i];
		next unless defined $arg;
		$serve = 1 if $arg eq '--serve';
		if ($arg eq '--socket') {
			$path = $args->[$i + 1];
			$i++;
		}
		elsif ($arg =~ /\A--socket=(.*)\z/s) { $path = $1 }
	}
	return 0 unless $serve && defined $path;
	return $path eq $socket ? 1 : 0;
}

# Every process running this engine binary with `--serve` on this socket,
# except this supervisor and its own child. The adopt probe at startup only
# sees an engine that answers `status`; an older or wedged one keeps playing
# and capturing while its socket looks like a stale file.
sub orphan_engines {
	my ($socket, $binary) = @_;
	opendir(my $dh, '/proc') or return ();
	my @found;
	for my $entry (readdir $dh) {
		next unless $entry =~ /\A([0-9]+)\z/;
		my $pid = 0 + $1;
		next if $pid == $$;
		next if defined $child_pid && $pid == $child_pid;
		my $args = read_cmdline($pid) or next;
		next unless @$args;
		next unless runs_binary($pid, $args, $binary);
		next unless serves_socket($args, $socket);
		push @found, $pid;
	}
	closedir $dh;
	return @found;
}

# A zombie is gone for our purpose: it holds no socket and never will. Its
# parent reaps it, and some parents are slow (a container's PID 1 may never). A
# pid with no readable /proc entry keeps the alive answer - only a state this
# supervisor can actually read is proof that the engine left.
sub pid_dead {
	my ($pid) = @_;
	return 1 unless pid_alive($pid);
	open(my $fh, '<', "/proc/$pid/stat") or return 0;
	my $line = <$fh>;
	close $fh;
	return 0 unless defined $line;
	my $close = rindex($line, ')');
	return 0 if $close < 0;
	return substr($line, $close + 2, 1) eq 'Z' ? 1 : 0;
}

# The identity is read again immediately before each signal, so a pid the kernel
# reused between the /proc scan and the kill is never hit for its number.
sub still_orphan {
	my ($pid, $socket, $binary) = @_;
	return 0 if pid_dead($pid);
	my $args = read_cmdline($pid) or return 0;
	return 0 unless @$args;
	return 0 unless runs_binary($pid, $args, $binary);
	return 0 unless serves_socket($args, $socket);
	return 1;
}

# TERM, a grace, then KILL - the same ladder `stop_supervisor` uses on its own
# child. Returns 1 once the engine is gone (or no longer the process we
# identified, which means the one we wanted is gone) and 0 while it still is.
sub terminate_orphan {
	my ($pid, $socket, $binary) = @_;
	return 1 if pid_dead($pid);
	kill 'TERM', $pid if still_orphan($pid, $socket, $binary);
	my $deadline = time + $STOP_GRACE;
	while (time < $deadline) {
		return 1 if pid_dead($pid);
		sleep 0.05;
	}
	return 1 if pid_dead($pid);
	return 1 unless still_orphan($pid, $socket, $binary);
	kill 'KILL', $pid;
	$deadline = time + $STOP_GRACE;
	while (time < $deadline) {
		return 1 if pid_dead($pid);
		sleep 0.05;
	}
	return pid_dead($pid) ? 1 : 0;
}

# Ask an engine we did not start to quit before replacing the socket under it.
# A clean quit unlinks the socket and exits; only then is a spawn safe. The
# request needs the socket file to exist, and the boot wipe deletes it while an
# engine from the previous run keeps the listening end - so the wait below is
# often known to fail before it starts. An engine positively identified from
# /proc (this binary, `--serve`, this socket) then gets the ladder: TERM, a
# grace, KILL. A process that is not this binary on this socket is never
# signalled, and no second engine is ever started.
sub clear_orphans {
	my ($socket, $binary) = @_;
	my @orphans = orphan_engines($socket, $binary);
	return 1 unless @orphans;
	print "audio supervisor: found engine " . join(' ', @orphans)
		. " already serving $socket but not as my child; asking it to quit\n";
	engine_command($socket, { cmd => 'quit' });
	my $deadline = time + $ORPHAN_GRACE;
	my @alive = @orphans;
	while (time < $deadline) {
		@alive = grep { !pid_dead($_) } @orphans;
		last unless @alive;
		sleep 0.05;
	}
	@alive = grep { !pid_dead($_) } @orphans;
	if (!@alive) {
		print "audio supervisor: engine " . join(' ', @orphans) . " quit\n";
		return 1;
	}

	# It could not be reached over the socket (or ignored the request). Asking a
	# supervisor to give up here is what left a machine with an engine it could
	# not see, a sink nobody captured and no supervisor of its own: the next
	# start found the same orphan and refused the same way.
	print STDERR "audio supervisor: engine " . join(' ', @alive)
		. " did not quit over the socket; sending it TERM\n";
	my @stuck;
	for my $pid (@alive) {
		push @stuck, $pid unless terminate_orphan($pid, $socket, $binary);
	}
	if (@stuck) {
		print STDERR "audio supervisor: engine " . join(' ', @stuck)
			. " is still alive after TERM and KILL; not starting a second one\n";
		return 0;
	}
	print "audio supervisor: engine " . join(' ', @alive) . " is gone\n";
	return 1;
}

# The saved plan and switch, plus the picker's choice when one was written.
# A flag on the command line still wins over the pair, so a hand-run supervisor
# can be pinned to one device; the manager's picker is the normal path (it
# starts with JawnOS, with no flags). The pair is optional: a machine that has
# never chosen one still gets its plan and switch, and `spawn_choice` decides
# the interface with its safe fallback (never a silent hw:1,0).
sub plan_config {
	return undef unless -s $plan;
	open(my $fh, '<', $plan) or return undef;
	local $/;
	my $raw = <$fh>;
	close $fh;
	my $doc = eval { JSON::PP->new->decode($raw) };
	return undef unless ref $doc eq 'HASH';
	my $backend = $doc->{'backend'};
	my $device  = $doc->{'device'};
	my $pair = defined $backend && $backend =~ /\A(?:alsa|pipewire|null)\z/
		&& defined $device && $device =~ /\A[A-Za-z0-9_.:,-]+\z/;
	return {
		($pair ? (backend => $backend, device => $device) : ()),
		manage  => $doc->{'manage'} ? 1 : 0,
		plan    => $doc->{'plan'},
	};
}

# Whether a backend carries the machine's own audio through the engine, and so
# needs the virtual sink: ALSA always owns the card; a PipeWire plan (playback
# or duplex) plays the sink's monitor out the device it replaced. A duplex plan
# captures its routed inputs through their own streams, so the engine never
# needs the card's capture through pipewire-alsa.
sub mix_backends {
	my ($backend, $mode) = @_;
	return 1 if defined $backend && $backend eq 'alsa';
	return 1 if defined $backend && $backend eq 'pipewire';
	return 0;
}

# `alsa|hw:0,0` and `hw:0,0` are the same choice; the engine reports the bare
# form while the picker and the plan may store the prefixed one.
sub device_same {
	my ($a, $b) = @_;
	$a = '' unless defined $a;
	$b = '' unless defined $b;
	$a =~ s/\Aalsa\|//;
	$b =~ s/\Aalsa\|//;
	return $a eq $b ? 1 : 0;
}

# Put the machine's own audio on the virtual sink exactly while the engine
# plays the machine's output. On ALSA the engine holds the card, so the sink is
# the only place an app can land; on the shared PipeWire backend the engine is
# the mixer itself and plays the sink's monitor out the device it replaced. A
# duplex PipeWire plan uses the same mix and plays only; each routed input is
# captured by its own stream. The plan file is the switch's durable copy, so a
# supervisor that starts after a reboot knows without asking the manager. The
# rule that frees the card's playback node goes in before the child opens it,
# and only for an ALSA card; the microphone node deliberately stays with
# PipeWire.
sub ensure_system_mix {
	my ($backend, $manage, $device, $mode, $engine) = @_;
	return undef unless load_system_mix();

	# ALSA always needs the sink: the engine holds the card. PipeWire needs it
	# for every plan: the engine plays the mix out the output it replaced, and a
	# duplex plan's routed inputs arrive through their own capture streams, so
	# no single pipewire-alsa process has to play one node and capture another.
	#
	# A live child's own report is the fact; the flags only describe the next
	# spawn. Deciding from the flags while the child runs could take the sink
	# away from a card-owning engine and silence the machine.
	my $deciding = defined $engine && defined $engine->{'backend'} && length $engine->{'backend'}
		? $engine->{'backend'} : $backend;
	my $mix_backend = mix_backends($deciding, $mode);
	if (!$manage || !$mix_backend) {
		remove_system_mix() if defined $active_system_device;
		return undef;
	}

	# A hand-run supervisor may name the source itself; then it owns the sink
	# and this one must not load or unload it.
	if (defined $given{'system-device'} && length $given{'system-device'}) {
		$active_system_device   = $system_device;
		$active_system_mode     = $mode;
		$active_playback_device = undef;
		return $system_device;
	}

	my $mix = JawnOS::Audio::SystemMix::ensure($audio_dir, $device, $mode);
	if ($mix && $mix->{ok}) {
		$active_system_device = $mix->{source};
		$active_system_mode   = $mode;
		$active_playback_device = $backend eq 'pipewire'
			&& defined $mix->{playback_device} && length $mix->{playback_device}
			? $mix->{playback_device} : undef;
		if ($mix->{managed_card} && $mix->{managed_card}->{note}) {
			print "audio supervisor: card rule: " . $mix->{managed_card}->{note} . "\n";
		}
		return $mix->{source};
	}
	$active_system_device   = undef;
	$active_playback_device = undef;
	if ($mix && $mix->{error}) {
		print "audio supervisor: system mix: " . $mix->{error} . "\n";
	}
	return undef;
}

sub remove_system_mix {
	return unless load_system_mix();
	my $state = JawnOS::Audio::SystemMix::status($audio_dir);
	# A sink with no state record is a mix a wipe or a crash left behind; the
	# module can find and undo it by its own listing. `present` is what a
	# supervisor that lost the record still knows.
	return unless defined $active_system_device
		|| ($state && ($state->{active} || $state->{present}));
	my $answer = JawnOS::Audio::SystemMix::remove($audio_dir);
	$active_system_device   = undef;
	$active_system_mode     = undef;
	$active_playback_device = undef;
	if ($answer && $answer->{recovered}) {
		print "audio supervisor: the system mix was found without its state record;"
			. " handed the machine back\n";
	}
	if ($answer && !$answer->{ok} && $answer->{error}) {
		print STDERR "audio supervisor: system mix: " . $answer->{error} . "\n";
	}
	if ($answer && $answer->{managed_card}
		&& $answer->{managed_card}->{restart}
		&& $answer->{managed_card}->{restart}->{error}) {
		print STDERR "audio supervisor: card rule: "
			. $answer->{managed_card}->{restart}->{error} . "\n";
	}
}

# Keep the virtual sink only while the engine is actually patching and actually
# capturing its monitor. The engine's `system` value is the fact (its own status
# contract, engine/src/socket.rs): `capturing` once parec is reading, `pending`
# while the worker is still opening it, `unavailable` when this machine cannot
# capture it (no parec or no source), and `off` when the patch was not asked for
# one. A failed or ended patch takes the sink away with it - on PipeWire
# especially, where a failed capture must never leave `jawn_system` as the
# machine's default. A child that reports `unavailable` can never capture, so it
# is ended as well: the supervisor respawns it without the source, rather than
# leaving a `parec` retrying against a node nobody provides.
my $system_unavailable;   # plan token under which the engine could not capture
my $system_quit_token;    # plan token of the child already asked to leave
my $child_system_source;  # the source this child was actually handed

# What the next spawn would ask for, as one comparable string. `unavailable` is
# remembered against this, so a plan change (the switch, the pair, the capture
# mode) is a fresh attempt while a respawn of the same plan is not.
sub mix_token {
	my ($manage, $backend, $device, $mode) = @_;
	return join '|', ( $manage ? 1 : 0 ),
		( defined $backend ? $backend : '' ),
		( defined $device  ? $device  : '' ),
		( defined $mode    ? $mode    : '' );
}

# The sink a source belongs to, for the one check a spawn makes: a monitor of a
# sink the server does not list is a name `parec` can only retry forever
# against. A source that is not a monitor is left to the engine to judge.
sub system_source_present {
	my ($source) = @_;
	return 1 unless defined $source && $source =~ /\A(.+)\.monitor\z/;
	my $sink = $1;
	return 1 unless load_system_mix();
	my $present = JawnOS::Audio::SystemMix::sink_present($sink);
	return 1 unless defined $present;
	return $present ? 1 : 0;
}

sub sync_system_mix {
	my ($engine) = @_;
	return unless load_system_mix();
	# A hand-run supervisor named its own source; it owns that sink. It still
	# owns the child, so an `unavailable` capture still ends the child below.
	my $owns_sink = !( defined $given{'system-device'} && length $given{'system-device'} );

	my $chosen = plan_config();
	my $manage = $chosen ? $chosen->{manage} : 0;
	my $state  = $engine ? ( $engine->{'state'} // '' ) : '';
	my $engine_backend = $engine && defined $engine->{'backend'} && length $engine->{'backend'}
		? $engine->{'backend'} : $backend;

	# A take, a playback or a listen still holds the output, so the machine's
	# ordinary audio must stay on the sink even though the patch is not the
	# status line.
	return if $state =~ /\A(?:recording|playing|listening)\z/;

	my $live   = $state eq 'patching';
	my $system = $engine ? ( $engine->{'system'} // '' ) : '';

	# The engine's mode can lag the plan by one patch. Keep duplex whenever
	# either says duplex: an extra capture rule is harmless, but a sink-only
	# rule would make the new duplex patch fail to open the microphone.
	my $plan_mode = load_system_mix() && $chosen
		? JawnOS::Audio::SystemMix::plan_mode($chosen->{'plan'}, $machine)
		: 'playback';
	my $engine_mode = $engine && defined $engine->{'mode'}
		&& $engine->{'mode'} =~ /\A(?:duplex|playback)\z/
		? $engine->{'mode'} : undef;
	my $mode = JawnOS::Audio::SystemMix::mode_union($engine_mode, $plan_mode);
	my $mix_backend = mix_backends($engine_backend, $mode);
	# The plan this poll describes. A token that differs from the one the engine
	# failed under is a fresh attempt - the person moved the switch, the pair or
	# the capture mode - even if no spawn has happened since.
	my $next  = spawn_choice();
	my $token = mix_token($manage, $next->{'backend'}, $next->{'device'}, $plan_mode);
	$system_unavailable = undef
		if defined $system_unavailable && $system_unavailable ne $token;
	$system_quit_token = undef
		if defined $system_quit_token && $system_quit_token ne $token;

	if ($live && $mix_backend) {
		if ($system eq 'unavailable') {
			# The engine's own status says this machine has no capture it can
			# ever make. Hand the output back, remember the verdict so the next
			# spawn asks for no source, and end the child that holds it - once,
			# however often the status is polled.
			$system_unavailable = $token;
			remove_system_mix() if $owns_sink;
			if ( !defined $system_quit_token || $system_quit_token ne $token ) {
				my $stranded = defined $child_system_source || $adopted;
				if ($stranded) {
					$system_quit_token   = $token;
					$child_system_source = undef;
					print "audio supervisor: the engine cannot capture the system mix;"
						. " handing the machine back and restarting it without that source\n";
					engine_command($socket, { cmd => 'quit' });
				}
			}
			return;
		}
		if ($manage) {
			if ($system eq 'pending') {
				# Still opening the capture; the child's own retry loop owns it.
				return;
			}
			if ($system eq 'off') {
				# The pass no longer asks for a mix. The child keeps running.
				remove_system_mix() if $owns_sink;
				return;
			}
			if ($system eq 'capturing') {
				return unless $owns_sink;
				# A mode flip rewrites the rule; the same mode costs nothing.
				return if defined $active_system_device
					&& defined $active_system_mode
					&& $active_system_mode eq $mode;
				my $engine_device = $engine && defined $engine->{'device'} && length $engine->{'device'}
					? $engine->{'device'} : $device;
				ensure_system_mix($engine_backend, $manage, $engine_device, $mode, $engine);
				return;
			}
			# No report at all (an engine older than this field) or a value this
			# supervisor does not know: keep the mix and let the child's own
			# capture retry decide, rather than take the output from under it.
			return;
		}
	}

	# A switch that just went off, or a plan that just moved to another backend,
	# describes the next spawn: the child still owns the output. The mismatch
	# quit in `follow_plan` ends it first, and `child_exited` takes the sink away,
	# so the machine is never left on a card the engine holds with no sink behind
	# it. A failed capture is different - that child plays the output the mix
	# replaced, so a sink nobody captures must not stay the default.
	return if !$manage && $live && mix_backends($engine_backend, $mode);
	remove_system_mix() if $owns_sink;
}

my $engine_build_at = 0;
sub ensure_engine_fresh {
	# The staged binary is a build artifact. A pull can change engine/ without
	# restaging it, so the supervisor asks the one build script whether the
	# binary is fresh before it spawns one. A hand-run supervisor with a binary
	# of its own (`--binary` or the environment) never touches the tree's engine.
	my $script = ( defined $ENV{'JAWNOS_AUDIO_BUILD'} && length $ENV{'JAWNOS_AUDIO_BUILD'} )
		? $ENV{'JAWNOS_AUDIO_BUILD'} : "$root/scripts/build_engine.pl";
	return unless -f $script;
	return if defined $given{'binary'}
		|| ( defined $ENV{'JAWNOS_AUDIO_BINARY'} && length $ENV{'JAWNOS_AUDIO_BINARY'} );
	# A missing toolchain answers in a sentence; do not run it on every backoff
	# step. A real engine change is noticed within a minute.
	return if $engine_build_at && time - $engine_build_at < 60;
	$engine_build_at = time;
	my $pid = open(my $fh, '-|', $^X, $script, '--if-stale');
	return unless $pid;
	my $summary = '';
	while (my $line = <$fh>) {
		$summary = $line if $line =~ /^(?:fresh|built):/;
	}
	close $fh;
	return unless $? == 0 && length $summary;
	chomp $summary;
	print "audio supervisor: engine $summary\n";
}

# What to use when no saved plan describes one. The compiled default
# (`alsa hw:1,0`) opens a card exclusively; on a machine with a
# PipeWire/PulseAudio server the shared `pipewire`/`default` pair coexists with
# everything else. A flag or the environment still wins. The pair is decided
# once per supervisor, so a `follow_plan` poll does not probe `pactl` every
# second; it is also the diagnostic for a plan file that disappears.
my $fallback_pair;
my $fallback_announced = 0;
sub fallback_choice {
	return undef if defined $given{'backend'} || defined $given{'device'};
	return undef if defined $ENV{'JAWNOS_AUDIO_BACKEND'} && length $ENV{'JAWNOS_AUDIO_BACKEND'};
	return undef if defined $ENV{'JAWNOS_AUDIO_DEVICE'} && length $ENV{'JAWNOS_AUDIO_DEVICE'};
	return $fallback_pair if defined $fallback_pair;
	my $server = load_system_mix() && JawnOS::Audio::SystemMix::available();
	$fallback_pair = $server
		? { backend => 'pipewire', device => 'default' }
		: { backend => 'alsa',     device => 'hw:1,0' };
	return $fallback_pair;
}

# The pair the next spawn will use. A command-line flag still wins over the
# plan file, exactly as `spawn_engine` reads it; `$backend`/`$device` hold the
# last spawn's pair once a plan has been read, and stay that if the file goes.
sub spawn_choice {
	my $chosen   = plan_config();
	my $has_pair = $chosen
		&& defined $chosen->{'backend'} && length $chosen->{'backend'}
		&& defined $chosen->{'device'}  && length $chosen->{'device'};
	my $fallback = $has_pair ? undef : fallback_choice();
	if ($fallback && !$fallback_announced) {
		$fallback_announced = 1;
		print "audio supervisor: no saved plan at $plan; choosing backend"
			. " $fallback->{'backend'} on device $fallback->{'device'}\n";
	}
	my $next_backend = defined $given{'backend'} ? $backend
		: ( $has_pair ? $chosen->{'backend'} : ( $fallback ? $fallback->{'backend'} : $backend ) );
	my $next_device = defined $given{'device'} ? $device
		: ( $has_pair ? $chosen->{'device'} : ( $fallback ? $fallback->{'device'} : $device ) );
	return { backend => $next_backend, device => $next_device };
}

sub spawn_engine {
	# An engine left by an older binary (or a wedged one) may hold this socket
	# without answering `status`; the adopt path cannot see it, and starting
	# ours would put two engines on the machine. Ask it to quit first, and take
	# it down the TERM/KILL ladder if it will not: never spawn a second engine
	# this supervisor cannot see, and never signal one it cannot identify.
	unless (clear_orphans($socket, $binary)) {
		$spawn_refused = "an engine this supervisor did not start is still on $socket";
		return undef;
	}
	$spawn_refused = undef;
	my $chosen  = plan_config();
	my $manage  = $chosen ? $chosen->{'manage'} : 0;
	my $choice  = spawn_choice();
	$backend = $choice->{'backend'};
	$device  = $choice->{'device'};
	my $mode = load_system_mix() && $chosen
		? JawnOS::Audio::SystemMix::plan_mode($chosen->{'plan'}, $machine)
		: 'playback';
	my $token = mix_token($manage, $backend, $device, $mode);
	# A plan change is a fresh attempt: an engine this plan could not capture
	# with says nothing about the next one. The same plan is not retried, or a
	# machine with no parec would recreate the sink and be ended forever.
	$system_unavailable = undef
		if defined $system_unavailable && $system_unavailable ne $token;
	my $system_source;
	$system_source = ensure_system_mix($backend, $manage, $device, $mode)
		if !defined $system_unavailable;
	# The engine's source must exist at this moment. `ensure` may have just made
	# the sink; a source whose sink the server does not list is one its `parec`
	# can only retry against, so the flag is not passed at all. This is the
	# direct guard against a run left with `manage: 1` and no `jawn_system`.
	if (defined $system_source && length $system_source
		&& !system_source_present($system_source)) {
		print "audio supervisor: not passing --system-device $system_source;"
			. " its sink is not in pactl's list\n";
		$system_source = undef;
	}
	$child_system_source = $system_source;
	# A PipeWire engine plays out the output the mix replaced; `default` would
	# be our own sink once the switch has moved it. The engine's device is the
	# PCM it opens, so the node name reaches pipewire-alsa through the
	# environment, which is how that plugin picks its target.
	my $engine_device = $device;
	$engine_device = $active_playback_device
		if $backend eq 'pipewire'
			&& defined $active_playback_device && length $active_playback_device;
	my $pipewire_node = $backend eq 'pipewire'
		&& defined $active_playback_device && length $active_playback_device
		? $active_playback_device : undef;
	my $pid = fork();
	unless (defined $pid) {
		warn "audio supervisor: cannot fork: $!\n";
		$spawn_refused = 'cannot fork';
		# The sink this spawn may have just made has no child to capture it.
		remove_system_mix();
		$child_system_source = undef;
		return undef;
	}
	if ($pid == 0) {
		# Belt and braces: FD_CLOEXEC should already have done this on exec.
		close $lock;
		$ENV{'PIPEWIRE_NODE'} = $pipewire_node if defined $pipewire_node;
		my @args = (
			$binary, '--serve',
			'--backend', $backend,
			'--device',  $engine_device,
			'--period',  $period,
			'--buffer',  $buffer,
			'--socket',  $socket,
			'--plan',    $plan,
			'--machine', $machine,
		);
		push @args, ('--system-device', $system_source)
			if defined $system_source && length $system_source;
		push @args, ('--handset-device', $handset_device)
			if $handset_given && defined $handset_device && length $handset_device;
		exec { $binary } @args or do {
				print STDERR "audio supervisor: cannot run $binary: $!\n";
				POSIX::_exit(127);
			};
	}
	return $pid;
}

# The plan file is what the next spawn will use. A child spawned before a plan
# change keeps its own pair - and on ALSA keeps the card exclusively - so a
# mismatch is ended here rather than deferred to a restart that never comes.
# The device is compared for ALSA only: a PipeWire child is deliberately started
# on the output the mix replaced, so its `--device` is not the plan's device.
sub follow_plan {
	my ($engine) = @_;
	return unless $engine && defined $engine->{'backend'} && length $engine->{'backend'};
	my $want = spawn_choice();
	my $note;
	if ($engine->{'backend'} ne $want->{'backend'}) {
		$note = "the engine runs backend $engine->{'backend'};"
			. " the saved plan says $want->{'backend'}";
	}
	elsif ($engine->{'backend'} eq 'alsa'
		&& defined $engine->{'device'} && length $engine->{'device'}
		&& !device_same($engine->{'device'}, $want->{'device'})) {
		$note = "the engine plays $engine->{'device'};"
			. " the saved plan says $want->{'device'}";
	}
	return unless defined $note;
	print "audio supervisor: $note; asking it to restart on the saved choice\n";
	engine_command($socket, { cmd => 'quit' });
}

sub child_exited {
	my ($raw) = @_;
	# The engine is gone, so the machine must not stay pointed at a sink nobody
	# captures. Put the previous default back before the backoff starts.
	remove_system_mix();
	$child_system_source = undef;
	my $ran = defined $child_started ? time - $child_started : 0;
	$last_exit = describe_wait($raw);
	# A real run earns a fresh ladder; a run of a few milliseconds does not.
	$consecutive_restarts = 0 if $ran >= $LONG_RUN;
	my $delay = $RESTART_DELAYS[$consecutive_restarts];
	$delay = $RESTART_DELAYS[-1] unless defined $delay;
	$consecutive_restarts++;
	$restarts++;
	$backoff   = $delay;
	$child_pid = undef;
	$child_started = undef;
	write_status();
	print "audio supervisor: engine $last_exit after " . int($ran)
		. "s; restarting in ${delay}s\n";
	return $delay;
}

sub report_missing {
	return if $missing_said;
	$missing_said = 1;
	print STDERR "audio supervisor: the engine binary $binary is missing or not executable;"
		. " the engine is optional, checking again every ${MISSING_RETRY}s\n";
}

sub stop_supervisor {
	remove_system_mix();
	if (defined $child_pid) {
		kill 'TERM', $child_pid;
		my $deadline = time + $STOP_GRACE;
		my $reaped   = 0;
		while (time < $deadline) {
			my $got = waitpid($child_pid, POSIX::WNOHANG());
			if ($got == $child_pid) {
				$reaped = 1;
				last;
			}
			sleep 0.05;
		}
		unless ($reaped) {
			kill 'KILL', $child_pid;
			waitpid($child_pid, 0);
		}
		$child_pid = undef;
	}
	elsif ($adopted) {
		# The adopted engine is not our child, so it cannot be reaped and must
		# be asked to leave. It is the engine this supervisor now owns; a clean
		# stop should not leave one detached behind.
		engine_command($socket, { cmd => 'quit' });
		my $deadline = time + $STOP_GRACE;
		while (time < $deadline) {
			last unless engine_answers($socket);
			sleep 0.05;
		}
		if (engine_answers($socket)) {
			print STDERR "audio supervisor: the adopted engine at $socket did not stop\n";
		}
	}
	unlink $status_path;
	print "audio supervisor: stopped\n";
	exit 0;
}

# --- adopt a live engine on start ---------------------------------------------

# Run before the signal handlers are installed: a TERM during this first probe
# must not be mistaken for a dead engine and unlink a socket that is still
# serving. A stale file is the only thing removed here.
if (-S $socket) {
	if (my $engine = engine_answers($socket)) {
		$adopted          = 1;
		$adopted_since    = time;
		$adopted_mismatch = 0;
		$adopted_note     = undef;
		# This engine's source was chosen by whatever started it, not by us.
		$child_system_source = undef;
		$next_probe       = time + $ADOPT_POLL;
		my $engine_backend = $engine->{'backend'};
		my $engine_device  = $engine->{'device'};
		# An engine too old to report its configuration cannot be judged, so it
		# is adopted exactly as before rather than accused of a mismatch.
		# The device only matters when the engine actually opens one: a null-backend
		# engine reports `device: "null"`, and comparing that with a configured
		# `hw:1,0` would flag a mismatch that cannot matter.
		my $device_differs = defined $engine_device && $engine_backend ne 'null'
			&& $engine_device ne $device;
		if (defined $engine_backend && defined $engine_device
			&& ($engine_backend ne $backend || $device_differs)) {
			$adopted_mismatch = 1;
			$adopted_note = "adopted engine is backend $engine_backend on device $engine_device;"
				. " this supervisor is configured for backend $backend on device $device";
			print "audio supervisor: adopting the engine already serving $socket although it runs"
				. " backend $engine_backend on device $engine_device, not the configured"
				. " backend $backend on device $device\n";
		}
		else {
			print "audio supervisor: adopting the engine already serving $socket"
				. " instead of starting a second one\n";
		}
	}
	elsif (clear_orphans($socket, $binary)) {
		if (!-S $socket) {
			# The engine we asked to quit unlinked it on the way out.
			print "audio supervisor: the socket $socket is free\n";
		}
		elsif (unlink $socket) {
			print "audio supervisor: removed the stale socket $socket\n";
		}
		else {
			print STDERR "audio supervisor: cannot remove the stale socket $socket: $!\n";
		}
	}
	else {
		print STDERR "audio supervisor: leaving $socket to the engine that would not quit;"
			. " not starting a second one\n";
	}
}

# A supervisor that was killed leaves its engine and its virtual sink behind.
# A live engine is adopted above and keeps both; with no adopted engine, the
# state file is a crash remnant and the machine's own default comes back now.
unless ($adopted) {
	remove_system_mix();
}

# --- supervise ----------------------------------------------------------------

$SIG{'TERM'} = sub { $stop = 1 };
$SIG{'INT'}  = sub { $stop = 1 };

write_status();
print "audio supervisor: supervising $socket (binary $binary, backend $backend,"
	. " device $device, ${period}/${buffer})\n";

while (!$stop) {
	if ($adopted) {
		if (time >= $next_probe) {
			my $engine = engine_answers($socket);
			if ($engine) {
				$next_probe = time + $ADOPT_POLL;
				sync_system_mix($engine);
			}
			else {
				# A signal may have interrupted the probe; do not turn that
				# into a takeover on the way out.
				last if $stop;
				print "audio supervisor: the adopted engine at $socket stopped answering;"
					. " starting our own\n";
				$adopted          = 0;
				$adopted_since    = undef;
				$adopted_mismatch = 0;
				$adopted_note     = undef;
				$next_start       = 0;
				write_status();
			}
		}
		if ($adopted) {
			sleep $POLL;
			next;
		}
	}
	if (defined $child_pid) {
		my $got = waitpid($child_pid, POSIX::WNOHANG());
		if ($got == $child_pid) {
			$next_start = time + child_exited($?);
			next;
		}
		if (time >= $next_sync) {
			$next_sync = time + $ADOPT_POLL;
			my $engine = engine_answers($socket);
			if ($engine) {
				sync_system_mix($engine);
				follow_plan($engine);
			}
		}
	}
	elsif (time >= $next_start) {
		# A pull can move engine/ while the staged binary stays behind; restage
		# it before the missing/binary check, because the first run may be the
		# one that builds the binary at all.
		ensure_engine_fresh();
		unless (-f $binary && -x $binary) {
			report_missing();
			$last_exit = 'engine missing';
			$child_pid = undef;
			$child_started = undef;
			write_status();
			$next_start = time + $MISSING_RETRY;
			next;
		}
		$child_pid = spawn_engine();
		if (defined $child_pid) {
			$child_started = time;
			$next_start    = 0;
			$next_sync     = time + $ADOPT_POLL;
			write_status();
			print "audio supervisor: started engine as $child_pid\n";
		}
		else {
			# A spawn the machine refused (an engine that would not leave,
			# or a fork that failed) is not a reason to stop supervising:
			# the next retry is what recovers it. Say why the house is
			# silent in the status file instead, so --check and Sound can
			# explain it rather than showing a bare null pid.
			$last_exit = $spawn_refused // 'the engine could not be started';
			$child_pid = undef;
			$child_started = undef;
			write_status();
			print "audio supervisor: $last_exit; retrying in ${MISSING_RETRY}s\n";
			$next_start = time + $MISSING_RETRY;
		}
	}
	sleep $POLL;
}

stop_supervisor();
