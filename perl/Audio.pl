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
# leaves a process no worker owns and no restart stops. The worker tree starts
# it beside Sco.pl and Reception.pl later; until then it is run by hand, in the
# foreground, exactly like those two.
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

my $script     = abs_path(__FILE__) // __FILE__;
my $script_dir = dirname($script);
my $root       = dirname($script_dir);

sub home_dir {
	my $home = $ENV{'HOME'};
	return $home if defined $home && length $home;
	my $passwd = eval { (getpwuid($<))[7] };
	return $passwd if defined $passwd && length $passwd;
	return '.';
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
answering. A socket file with nothing behind it is removed and replaced. A
clean stop asks an adopted engine to quit, so no engine is left behind.

Options:
  --backend NAME   audio backend: null, alsa, pipewire or jack (default alsa)
  --device NAME    ALSA PCM name (default hw:1,0)
  --period N       period/block size in frames (default 64)
  --buffer N       buffer size in frames (default 256)
  --socket PATH    control socket (default ~/.president/audio.sock)
  --binary PATH    engine binary (default perl/audio/jawn-audio under this tree)
  --status         print ~/.president/audio.json and exit
  --check          exit 0 while the supervisor and its engine are alive,
                   1 otherwise (an adopted engine counts while it answers)
  --help           this text

Config, highest precedence first: these flags, then JAWNOS_AUDIO_SOCKET,
JAWNOS_AUDIO_BINARY, JAWNOS_AUDIO_BACKEND, JAWNOS_AUDIO_DEVICE,
JAWNOS_AUDIO_PERIOD and JAWNOS_AUDIO_BUFFER, then the defaults above.

The status file is written while the supervisor runs and removed on a clean
stop. Its keys are: pid (the engine child, null while it is down or while an
engine is adopted), adopted (true while an engine found at start is answering),
adopted_since (when that adoption began), supervisor_pid, socket, binary,
backend, device, period, buffer, started_at, engine_started_at, restarts,
last_exit, consecutive_restarts, backoff and updated_at.
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
	elsif ($arg =~ /^--(socket|binary|backend|device|period|buffer)$/) {
		my $name = $1;
		fatal("--$name needs a value") unless @argv;
		$given{$name} = shift @argv;
	}
	elsif ($arg =~ /^--(socket|binary|backend|device|period|buffer)=(.*)$/s) {
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

fatal('--socket wants a path') unless length $socket;
fatal('--binary wants a path') unless length $binary;
fatal('--backend wants a name') unless length $backend;
fatal('--device wants a name') unless length $device;
fatal('--period wants a positive whole number of frames')
	unless $period =~ /\A[1-9][0-9]*\z/;
fatal('--buffer wants a positive whole number of frames')
	unless $buffer =~ /\A[1-9][0-9]*\z/;

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
my $next_probe            = 0;

sub write_status {
	my $data = {
		pid                  => $child_pid,
		adopted              => $adopted ? JSON::PP::true : JSON::PP::false,
		adopted_since        => defined $adopted_since ? int($adopted_since) : undef,
		supervisor_pid       => $supervisor_pid,
		socket               => $socket,
		binary               => $binary,
		backend              => $backend,
		device               => $device,
		period               => 0 + $period,
		buffer               => 0 + $buffer,
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

sub spawn_engine {
	my $pid = fork();
	unless (defined $pid) {
		warn "audio supervisor: cannot fork: $!\n";
		return undef;
	}
	if ($pid == 0) {
		# Belt and braces: FD_CLOEXEC should already have done this on exec.
		close $lock;
		exec { $binary } $binary, '--serve',
			'--backend', $backend,
			'--device',  $device,
			'--period',  $period,
			'--buffer',  $buffer,
			'--socket',  $socket
			or do {
				print STDERR "audio supervisor: cannot run $binary: $!\n";
				POSIX::_exit(127);
			};
	}
	return $pid;
}

sub child_exited {
	my ($raw) = @_;
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
	if (engine_answers($socket)) {
		$adopted       = 1;
		$adopted_since = time;
		$next_probe    = time + $ADOPT_POLL;
		print "audio supervisor: adopting the engine already serving $socket"
			. " instead of starting a second one\n";
	}
	elsif (unlink $socket) {
		print "audio supervisor: removed the stale socket $socket\n";
	}
	else {
		print STDERR "audio supervisor: cannot remove the stale socket $socket: $!\n";
	}
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
			if (engine_answers($socket)) {
				$next_probe = time + $ADOPT_POLL;
			}
			else {
				# A signal may have interrupted the probe; do not turn that
				# into a takeover on the way out.
				last if $stop;
				print "audio supervisor: the adopted engine at $socket stopped answering;"
					. " starting our own\n";
				$adopted       = 0;
				$adopted_since = undef;
				$next_start    = 0;
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
	}
	elsif (time >= $next_start) {
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
			write_status();
			print "audio supervisor: started engine as $child_pid\n";
		}
		else {
			# fork failed; treat it like a missing binary rather than looping.
			$next_start = time + $MISSING_RETRY;
		}
	}
	sleep $POLL;
}

stop_supervisor();
