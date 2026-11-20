# tests-for: perl/Audio.pl lib/JawnOS/Audio/SystemMix.pm
# covers:    the audio supervisor: a live engine found on its socket at start is
#            adopted (no child, no second engine, --check 0) and replaced only
#            once it stops answering, a stale socket file is removed and an
#            engine started, a quick-exit engine is restarted on a growing
#            backoff with the count and last exit in the status file, a live
#            engine makes --check 0 and --status name it, an adopted engine
#            whose backend/device differ from the flags is flagged and named
#            but still adopted, a second supervisor
#            refuses the lock without touching the first, a missing binary
#            is reported once while the supervisor keeps waiting, and the
#            saved-plan path and machine name (from the flags, then the
#            environment, then the host name and $state_dir) reach the status
#            file. A managed PipeWire engine plays the sink out the output the
#            mix replaced, captures the same monitor as ALSA, and a failed
#            capture hands the machine back instead of leaving our sink default.
#            An engine the supervisor did not start but can identify as this
#            binary on this socket is asked to quit before a spawn; a process
#            it cannot identify is left alone. With no saved plan the pair is
#            pipewire/default when a sound server answers, alsa/hw:1,0 when
#            none does, and the choice is logged once. The plan defaults to
#            the durable audio state dir, not the wiped ~/.president, and the
#            system-mix state follows the plan beside it.

use strict;
use warnings;

use FindBin;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use IO::Socket::UNIX;
use JSON::PP ();
use POSIX ();
use Socket qw(SOCK_STREAM);
use Test::More;
use Time::HiRes qw(sleep time);

# FindBin, not RepoSource or Probe: the pre-push guard compiles a new test in a
# scratch directory, so every path here comes from this file or a tempdir.
my $root  = abs_path("$FindBin::Bin/..");
my $audio = "$root/perl/Audio.pl";
ok(-f $audio, 'perl/Audio.pl is in the tree');

# Every process this file starts, so a failed assertion cannot leave a
# supervisor or an engine behind.
my @children;
END {
	# Killing a leftover child sets `$?` to its signal; keep that from becoming
	# this file's exit status after Test::More has already passed.
	local $?;
	for my $pid (grep { defined && $_ > 0 } @children) {
		next unless kill(0, $pid);
		kill 'KILL', $pid;
		waitpid($pid, 0);
	}
}

sub wait_for {
	my ($cond, $timeout) = @_;
	my $deadline = time + $timeout;
	while (1) {
		my $value = $cond->();
		return $value if $value;
		return 0 if time >= $deadline;
		sleep 0.05;
	}
}

sub read_text {
	my ($path) = @_;
	return '' unless -s $path;
	open(my $fh, '<', $path) or return '';
	local $/;
	my $text = <$fh>;
	close $fh;
	return $text // '';
}

sub read_status {
	my ($path) = @_;
	my $raw = read_text($path);
	return undef unless length $raw;
	my $data = eval { JSON::PP->new->decode($raw) };
	return ref $data eq 'HASH' ? $data : undef;
}

sub wait_status {
	my ($path, $timeout) = @_;
	return wait_for(sub { read_status($path) }, $timeout);
}

sub write_script {
	my ($path, $body) = @_;
	open(my $fh, '>', $path) or die "$path: $!";
	print {$fh} "#!/usr/bin/env perl\nuse strict;\nuse warnings;\n$body\n";
	close $fh;
	chmod 0755, $path or die "chmod $path: $!";
	return $path;
}

# A script whose shebang is this Perl, so a test can run it with a PATH that
# names no `perl` at all (the no-sound-server case).
sub write_absolute_script {
	my ($path, $body) = @_;
	open(my $fh, '>', $path) or die "$path: $!";
	print {$fh} "#!$^X\nuse strict;\nuse warnings;\n$body\n";
	close $fh;
	chmod 0755, $path or die "chmod $path: $!";
	return $path;
}

sub start_supervisor {
	my (%opt) = @_;
	my $pid = fork();
	die "fork: $!" unless defined $pid;
	if (!$pid) {
		open(my $log, '>>', $opt{'log'}) or POSIX::_exit(111);
		open(STDOUT, '>&', $log) or POSIX::_exit(111);
		open(STDERR, '>&', $log) or POSIX::_exit(111);
		exec $^X, $audio, @{ $opt{'args'} || [] } or POSIX::_exit(127);
	}
	push @children, $pid;
	return $pid;
}

# TERM, wait, and report the exit code; a supervisor that does not go is KILLed
# rather than left running.
sub stop_supervisor {
	my ($pid) = @_;
	return undef unless defined $pid && kill(0, $pid);
	kill 'TERM', $pid;
	my $raw;
	my $done = wait_for(sub {
		my $got = waitpid($pid, POSIX::WNOHANG());
		return 0 unless $got == $pid;
		$raw = $?;
		return 1;
	}, 10);
	unless ($done) {
		kill 'KILL', $pid;
		waitpid($pid, 0);
		return undef;
	}
	return $raw >> 8;
}

sub run_cli {
	my (@args) = @_;
	require IPC::Open3;
	require Symbol;
	my $err = Symbol::gensym();
	my $pid = IPC::Open3::open3(my $in, my $out, $err, $^X, $audio, @args);
	close $in;
	local $/;
	my $stdout = <$out> // '';
	my $stderr = <$err> // '';
	close $out;
	close $err;
	waitpid($pid, 0);
	return ($? >> 8, $stdout, $stderr);
}

# A stand-in for the real engine: it binds the control socket and answers each
# command with an ok object, so the supervisor's status probe sees a live
# engine. `backend`/`device` shape the configuration it reports, which is what
# the supervisor compares with its own flags. Like the engine it exits on quit
# and unlinks its socket; a KILL from the test leaves the socket file behind,
# which is the stale case.
sub start_fake_engine {
	my ($path, $ready, %opt) = @_;
	my $backend = defined $opt{'backend'} ? $opt{'backend'} : 'null';
	my $device  = defined $opt{'device'}  ? $opt{'device'}  : 'hw:1,0';
	my $pid = fork();
	die "fork: $!" unless defined $pid;
	if (!$pid) {
		my $listener = IO::Socket::UNIX->new(
			Local  => $path,
			Type   => SOCK_STREAM,
			Listen => 5,
		) or POSIX::_exit(1);
		open(my $fh, '>', $ready) or POSIX::_exit(1);
		print {$fh} "$$\n";
		close $fh;
		while (my $client = $listener->accept) {
			$client->autoflush(1);
			my $line = <$client>;
			my $cmd = '';
			if (defined $line) {
				my $obj = eval { JSON::PP->new->decode($line) };
				$cmd = ref $obj eq 'HASH' ? ($obj->{'cmd'} // '') : '';
			}
			if ($cmd eq 'quit') {
				print {$client} qq({"ok":true}\n);
				close $client;
				last;
			}
			print {$client} qq({"ok":true,"take":0,"state":"idle","backend":"$backend","device":"$device"}\n);
			close $client;
		}
		close $listener;
		unlink $path;
		POSIX::_exit(0);
	}
	push @children, $pid;
	return $pid;
}

sub reap_child {
	my ($pid) = @_;
	return 0 unless defined $pid;
	return waitpid($pid, POSIX::WNOHANG()) == $pid ? 1 : 0;
}

# --- a crashing engine is restarted on a growing backoff ----------------------
{
	my $dir  = tempdir(CLEANUP => 1);
	my $home = "$dir/home";
	make_path("$home/.president");
	local $ENV{HOME} = $home;
	local $ENV{AUDIO_TEST_ENGINE_MARK} = "$dir/engine.pid";
	local $ENV{JAWNOS_AUDIO_BINARY} = write_script("$dir/crashing-engine", <<'ENGINE');
my $mark = $ENV{AUDIO_TEST_ENGINE_MARK} || '';
open(my $fh, '>', $mark) or exit 7;
print {$fh} "$$\n";
close $fh;
exit 3;
ENGINE

	my $status = "$home/.president/audio.json";
	my $sup = start_supervisor(
		log  => "$dir/supervisor.log",
		args => [
			'--backend', 'null',
			'--device',  'hw:0,0',
			'--socket',  "$dir/audio.sock",
			'--period',  '64',
			'--buffer',  '256',
		],
	);

	my (%backoff_at, $final);
	my $seen = wait_for(sub {
		my $s = read_status($status);
		return 0 unless $s;
		my $n = defined $s->{'restarts'} ? $s->{'restarts'} : 0;
		$backoff_at{$n} = $s->{'backoff'} if $n >= 1;
		return 0 unless $n >= 2;
		$final = $s;
		return 1;
	}, 15);

	ok($seen, 'the supervisor restarted the crashing engine at least twice');
	cmp_ok($final->{'restarts'}, '>=', 2, 'the status file records the restart count')
		if $final;
	is($final->{'last_exit'}, 'exit 3', 'the status file records how the engine left')
		if $final;
	is($backoff_at{1}, 1, 'the first restart waits one second');
	is($backoff_at{2}, 2, 'the second restart waits two seconds');
	cmp_ok($backoff_at{2}, '>', $backoff_at{1}, 'the backoff grows');

	my $code = stop_supervisor($sup);
	is($code, 0, 'SIGTERM exits the crash-looping supervisor 0');
	ok(!-e $status, 'and removes the status file');
}

# --- a live engine: --check, --status, and a clean stop ----------------------
{
	my $dir  = tempdir(CLEANUP => 1);
	my $home = "$dir/home";
	make_path("$home/.president");
	local $ENV{HOME} = $home;
	my $mark = "$dir/engine.pid";
	local $ENV{AUDIO_TEST_ENGINE_MARK} = $mark;
	local $ENV{JAWNOS_AUDIO_BINARY} = write_script("$dir/alive-engine", <<'ENGINE');
my $mark = $ENV{AUDIO_TEST_ENGINE_MARK} || '';
open(my $fh, '>', $mark) or exit 7;
print {$fh} "$$\n";
close $fh;
sleep 600;
ENGINE

	# The environment disagrees with the flags on purpose: the flags must win.
	local $ENV{JAWNOS_AUDIO_BACKEND} = 'jack';
	local $ENV{JAWNOS_AUDIO_DEVICE}  = 'hw:9,9';
	local $ENV{JAWNOS_AUDIO_PERIOD}  = '999';

	my $status = "$home/.president/audio.json";
	my $sup = start_supervisor(
		log  => "$dir/supervisor.log",
		args => [
			'--backend', 'null',
			'--device',  'hw:1,0',
			'--socket',  "$dir/live.sock",
			'--period',  '128',
			'--buffer',  '512',
		],
	);

	my $s = wait_for(sub {
		my $data = read_status($status);
		return 0 unless $data && $data->{'pid'};
		return -s $mark ? $data : 0;
	}, 10);
	ok($s, 'the supervisor started the live engine');
	my $engine_pid = read_text($mark);
	$engine_pid =~ s/\s+//g;
	push @children, 0 + $engine_pid if length $engine_pid;
	is($s->{'pid'}, 0 + $engine_pid, 'the status file carries the engine pid') if $s;
	is($s->{'backend'}, 'null', 'a flag beats JAWNOS_AUDIO_BACKEND') if $s;
	is($s->{'device'}, 'hw:1,0', 'a flag beats JAWNOS_AUDIO_DEVICE') if $s;
	is($s->{'period'}, 128, 'a flag beats JAWNOS_AUDIO_PERIOD') if $s;
	is($s->{'buffer'}, 512, 'a flag beats the buffer default') if $s;
	is($s->{'socket'}, "$dir/live.sock", 'the status file names the socket') if $s;
	is($s->{'binary'}, $ENV{JAWNOS_AUDIO_BINARY}, 'JAWNOS_AUDIO_BINARY names the engine') if $s;
	ok(defined $s->{'started_at'}, 'the status file records when the supervisor started') if $s;

	my ($check_code, $check_out, $check_err) = run_cli('--check');
	is($check_code, 0, '--check is 0 while the child is alive') or diag($check_err);

	my ($status_code, $status_out, $status_err) = run_cli('--status');
	is($status_code, 0, '--status exits 0') or diag($status_err);
	my $printed = eval { JSON::PP->new->decode($status_out) };
	is(ref $printed eq 'HASH' ? $printed->{'pid'} : undef, 0 + $engine_pid,
		'--status prints the running engine');

	my $code = stop_supervisor($sup);
	is($code, 0, 'SIGTERM stops the supervisor 0');
	ok(!-e $status, 'the status file is gone after the clean stop');
	ok(!kill(0, 0 + $engine_pid), 'the engine child is gone with it');

	my ($after_code) = run_cli('--check');
	is($after_code, 1, '--check is 1 once the supervisor has stopped');
}

# --- a second supervisor refuses the lock and leaves the first alone ---------
{
	my $dir  = tempdir(CLEANUP => 1);
	my $home = "$dir/home";
	make_path("$home/.president");
	local $ENV{HOME} = $home;
	my $mark = "$dir/engine.pid";
	local $ENV{AUDIO_TEST_ENGINE_MARK} = $mark;
	local $ENV{JAWNOS_AUDIO_BINARY} = write_script("$dir/alive-engine", <<'ENGINE');
my $mark = $ENV{AUDIO_TEST_ENGINE_MARK} || '';
open(my $fh, '>', $mark) or exit 7;
print {$fh} "$$\n";
close $fh;
sleep 600;
ENGINE

	my $status = "$home/.president/audio.json";
	my $sup = start_supervisor(
		log  => "$dir/first.log",
		args => ['--backend', 'null', '--socket', "$dir/live.sock"],
	);
	my $before = wait_for(sub {
		my $data = read_status($status);
		return 0 unless $data && $data->{'pid'};
		return -s $mark ? $data : 0;
	}, 10);
	ok($before, 'the first supervisor owns the engine');
	my $first_engine = read_text($mark);
	$first_engine =~ s/\s+//g;
	push @children, 0 + $first_engine if length $first_engine;

	my ($second_code, $second_out, $second_err) = run_cli(
		'--backend', 'null', '--socket', "$dir/live.sock",
	);
	is($second_code, 1, 'a second supervisor refuses to start');
	like($second_err, qr/another audio supervisor/, 'and says so in one sentence');
	my @why = grep { /another audio supervisor/ } split /\n/, $second_err;
	is(scalar @why, 1, 'the refusal is one line, not a stack trace');

	my $after = read_status($status);
	is($after->{'pid'}, $before->{'pid'}, 'the first supervisor still owns its child');
	is($after->{'supervisor_pid'}, $before->{'supervisor_pid'}, 'and is still the writer');
	ok(kill(0, $sup), 'the first supervisor is untouched');

	my $code = stop_supervisor($sup);
	is($code, 0, 'the first supervisor still stops cleanly');
}

# --- a missing binary is optional, not a spin --------------------------------
{
	my $dir  = tempdir(CLEANUP => 1);
	my $home = "$dir/home";
	make_path("$home/.president");
	local $ENV{HOME} = $home;
	local $ENV{JAWNOS_AUDIO_BINARY} = "$dir/no-such-engine";

	my $status = "$home/.president/audio.json";
	my $log    = "$dir/supervisor.log";
	my $sup = start_supervisor(
		log  => $log,
		args => ['--backend', 'null', '--socket', "$dir/audio.sock"],
	);

	my $s = wait_status($status, 5);
	ok($s, 'the supervisor writes status with no engine to run');
	ok(!defined $s->{'pid'}, 'the status file names no child') if $s;

	sleep 1;
	ok(kill(0, $sup), 'the supervisor keeps running with a missing binary');
	my $text  = read_text($log);
	my $count = () = $text =~ /missing or not executable/g;
	is($count, 1, 'the missing binary is reported once, not once per retry');

	my ($check_code) = run_cli('--check');
	is($check_code, 1, '--check is 1 with no engine');

	my $code = stop_supervisor($sup);
	is($code, 0, 'a supervisor with no engine still stops cleanly');
	ok(!-e $status, 'and removes the status file');
}

# --- a live engine already on the socket is adopted, not duplicated ----------
{
	my $dir  = tempdir(CLEANUP => 1);
	my $home = "$dir/home";
	make_path("$home/.president");
	local $ENV{HOME} = $home;
	my $mark = "$dir/engine.pid";
	local $ENV{AUDIO_TEST_ENGINE_MARK} = $mark;
	local $ENV{JAWNOS_AUDIO_BINARY} = write_script("$dir/engine", <<'ENGINE');
my $mark = $ENV{AUDIO_TEST_ENGINE_MARK} || '';
open(my $fh, '>', $mark) or exit 7;
print {$fh} "$$\n";
close $fh;
sleep 600;
ENGINE

	my $sockpath = "$dir/adopt.sock";
	my $fake = start_fake_engine($sockpath, "$dir/fake.ready");
	ok(wait_for(sub { -s "$dir/fake.ready" }, 5), 'the fake engine is listening');

	my $status = "$home/.president/audio.json";
	my $sup = start_supervisor(
		log  => "$dir/supervisor.log",
		args => ['--backend', 'null', '--socket', $sockpath],
	);

	my $s = wait_for(sub {
		my $data = read_status($status);
		return 0 unless $data && $data->{'adopted'};
		return $data;
	}, 10);
	ok($s, 'the supervisor adopts the engine already on the socket');
	ok(!defined $s->{'pid'}, 'an adopted engine puts no child pid in the status file') if $s;
	is($s->{'socket'}, $sockpath, 'the adopted status names the socket') if $s;
	ok($s->{'adopted_since'}, 'the adopted status says when adoption began') if $s;
	ok(!$s->{'adopted_mismatch'}, 'a matching backend and device are not flagged') if $s;
	ok(!defined $s->{'adopted_note'}, 'a matching engine carries no mismatch note') if $s;

	my ($check_code, undef, $check_err) = run_cli('--check');
	is($check_code, 0, '--check is 0 while an adopted engine answers') or diag($check_err);

	my ($status_code, $status_out) = run_cli('--status');
	is($status_code, 0, '--status exits 0 for an adopted engine');
	my $printed = eval { JSON::PP->new->decode($status_out) };
	ok(ref $printed eq 'HASH' && $printed->{'adopted'}, '--status prints adopted: true');

	# Longer than one poll: an adopted engine must suppress the spawn entirely.
	sleep 2;
	ok(!-e $mark, 'the supervisor did not run the engine binary while adopted');

	my $code = stop_supervisor($sup);
	is($code, 0, 'SIGTERM stops an adopting supervisor 0');
	ok(!-e $status, 'the status file is gone after the clean stop');
	ok(wait_for(sub { reap_child($fake) }, 10), 'the adopted engine was asked to quit');
}

# --- an adopted engine configured differently is flagged, not refused -------
{
	my $dir  = tempdir(CLEANUP => 1);
	my $home = "$dir/home";
	make_path("$home/.president");
	local $ENV{HOME} = $home;
	my $mark = "$dir/engine.pid";
	local $ENV{AUDIO_TEST_ENGINE_MARK} = $mark;
	# If the supervisor refused the mismatch and spawned this, the mark would
	# appear; the test asserts it never does.
	local $ENV{JAWNOS_AUDIO_BINARY} = write_script("$dir/engine", <<'ENGINE');
my $mark = $ENV{AUDIO_TEST_ENGINE_MARK} || '';
open(my $fh, '>', $mark) or exit 7;
print {$fh} "$$\n";
close $fh;
sleep 600;
ENGINE

	my $sockpath = "$dir/mismatch.sock";
	my $fake = start_fake_engine($sockpath, "$dir/fake.ready",
		backend => 'alsa', device => 'hw:7,0');
	ok(wait_for(sub { -s "$dir/fake.ready" }, 5), 'the mismatched fake engine is listening');

	my $status = "$home/.president/audio.json";
	my $log    = "$dir/supervisor.log";
	my $sup = start_supervisor(
		log  => $log,
		args => ['--backend', 'null', '--device', 'hw:1,0', '--socket', $sockpath],
	);

	my $s = wait_for(sub {
		my $data = read_status($status);
		return 0 unless $data && $data->{'adopted'};
		return $data;
	}, 10);
	ok($s, 'a mismatched engine is still adopted: the engine holds the card');
	ok($s->{'adopted_mismatch'}, 'the status file flags the mismatch') if $s;
	like($s->{'adopted_note'}, qr/backend alsa on device hw:7,0/,
		'the note names the engine that was adopted') if $s;
	like($s->{'adopted_note'}, qr/backend null on device hw:1,0/,
		'and the configuration this supervisor expects') if $s;
	ok(!defined $s->{'pid'}, 'a mismatched adoption still puts no child pid in the status file') if $s;

	# Longer than one poll: a mismatch must not turn into a spawn.
	sleep 2;
	ok(!-e $mark, 'the supervisor did not start its own engine on a mismatch');

	my ($check_code) = run_cli('--check');
	is($check_code, 0, '--check is 0 for the mismatched engine it adopted');

	my $code = stop_supervisor($sup);
	is($code, 0, 'SIGTERM stops the mismatched-adoption supervisor 0');
	ok(!-e $status, 'the status file is gone after the clean stop');
	ok(wait_for(sub { reap_child($fake) }, 10), 'the mismatched engine was asked to quit');

	# Read the log after the exit: stdout to a file is buffered until then.
	my $text = read_text($log);
	my @said = grep { /adopting the engine already serving/ } split /\n/, $text;
	is(scalar @said, 1, 'the mismatch is one sentence at startup, not a trace');
	like($said[0], qr/hw:7,0/, 'and the sentence names the engine device') if @said;
	like($said[0], qr/hw:1,0/, 'and the configured device') if @said;
}

# --- when the adopted engine stops answering, the supervisor takes over ------
{
	my $dir  = tempdir(CLEANUP => 1);
	my $home = "$dir/home";
	make_path("$home/.president");
	local $ENV{HOME} = $home;
	my $mark = "$dir/engine.pid";
	local $ENV{AUDIO_TEST_ENGINE_MARK} = $mark;
	local $ENV{JAWNOS_AUDIO_BINARY} = write_script("$dir/engine", <<'ENGINE');
my $mark = $ENV{AUDIO_TEST_ENGINE_MARK} || '';
open(my $fh, '>', $mark) or exit 7;
print {$fh} "$$\n";
close $fh;
sleep 600;
ENGINE

	my $sockpath = "$dir/takeover.sock";
	my $fake = start_fake_engine($sockpath, "$dir/fake.ready",
		backend => 'alsa', device => 'hw:7,0');
	ok(wait_for(sub { -s "$dir/fake.ready" }, 5), 'the fake engine is listening');

	my $status = "$home/.president/audio.json";
	my $sup = start_supervisor(
		log  => "$dir/supervisor.log",
		args => ['--backend', 'null', '--socket', $sockpath],
	);

	my $adopted = wait_for(sub {
		my $data = read_status($status);
		return 0 unless $data && $data->{'adopted'};
		return $data;
	}, 10);
	ok($adopted, 'the supervisor adopts the fake engine first');
	ok($adopted->{'adopted_mismatch'}, 'the fake engine differs from the flags') if $adopted;

	kill 'KILL', $fake;
	waitpid($fake, 0);

	my $s = wait_for(sub {
		my $data = read_status($status);
		return 0 unless $data && defined $data->{'pid'} && -s $mark;
		return $data;
	}, 15);
	ok($s, 'the supervisor starts its own engine after the adopted one dies');
	ok(!$s->{'adopted'}, 'the status file no longer says adopted') if $s;
	ok(!$s->{'adopted_mismatch'}, 'taking over its own engine clears the mismatch flag') if $s;
	ok(!defined $s->{'adopted_note'}, 'and clears the mismatch note') if $s;
	my $engine_pid = read_text($mark);
	$engine_pid =~ s/\s+//g;
	push @children, 0 + $engine_pid if length $engine_pid;
	is($s->{'pid'}, 0 + $engine_pid, 'and names the child it started') if $s;

	my $code = stop_supervisor($sup);
	is($code, 0, 'the taking-over supervisor stops cleanly');
	ok(!-e $status, 'and removes the status file');
	ok(!kill(0, 0 + $engine_pid), 'the engine it started goes with it');
}

# --- a stale socket file is removed and an engine is started -----------------
{
	my $dir  = tempdir(CLEANUP => 1);
	my $home = "$dir/home";
	make_path("$home/.president");
	local $ENV{HOME} = $home;
	my $mark = "$dir/engine.pid";
	local $ENV{AUDIO_TEST_ENGINE_MARK} = $mark;
	local $ENV{JAWNOS_AUDIO_BINARY} = write_script("$dir/engine", <<'ENGINE');
my $mark = $ENV{AUDIO_TEST_ENGINE_MARK} || '';
open(my $fh, '>', $mark) or exit 7;
print {$fh} "$$\n";
close $fh;
sleep 600;
ENGINE

	my $sockpath = "$dir/stale.sock";
	my $orphan = IO::Socket::UNIX->new(
		Local  => $sockpath,
		Type   => SOCK_STREAM,
		Listen => 5,
	) or die "cannot make a stale socket: $!";
	close $orphan;
	ok(-S $sockpath, 'the test left a socket file with no listener');

	my $status = "$home/.president/audio.json";
	my $sup = start_supervisor(
		log  => "$dir/supervisor.log",
		args => ['--backend', 'null', '--socket', $sockpath],
	);

	my $s = wait_for(sub {
		my $data = read_status($status);
		return 0 unless $data && defined $data->{'pid'} && -s $mark;
		return $data;
	}, 10);
	ok($s, 'a stale socket does not stop the supervisor from starting an engine');
	ok(!$s->{'adopted'}, 'nothing was adopted from a socket that does not answer') if $s;
	ok(wait_for(sub { !-S $sockpath }, 5), 'the stale socket file was removed');

	my $engine_pid = read_text($mark);
	$engine_pid =~ s/\s+//g;
	push @children, 0 + $engine_pid if length $engine_pid;
	is($s->{'pid'}, 0 + $engine_pid, 'the status file names the engine it started') if $s;

	my $code = stop_supervisor($sup);
	is($code, 0, 'the supervisor over a stale socket stops cleanly');
	ok(!-e $status, 'and removes the status file');
	ok(!kill(0, 0 + $engine_pid), 'its engine child is gone with it');
}

# --- the saved-plan path and machine name reach the status file --------------
{
	my $dir  = tempdir(CLEANUP => 1);
	my $home = "$dir/home";
	make_path("$home/.president");
	local $ENV{HOME} = $home;
	local $ENV{JAWNOS_AUDIO_BINARY} = "$dir/no-such-engine";

	my $status = "$home/.president/audio.json";
	my $sup = start_supervisor(
		log  => "$dir/supervisor.log",
		args => [
			'--backend', 'null',
			'--socket',  "$dir/audio.sock",
			'--plan',    "$dir/plan.json",
			'--machine', 'table',
		],
	);

	my $s = wait_status($status, 5);
	ok($s, 'the supervisor writes status with a saved plan path');
	is($s->{'plan'}, "$dir/plan.json", 'the status file names the saved plan') if $s;
	is($s->{'machine'}, 'table', 'the status file names the machine') if $s;

	my $code = stop_supervisor($sup);
	is($code, 0, 'the supervisor with a plan path stops cleanly');
	ok(!-e $status, 'and removes the status file');
}

# --- the environment supplies the plan and machine defaults ------------------
{
	my $dir  = tempdir(CLEANUP => 1);
	my $home = "$dir/home";
	make_path("$home/.president");
	local $ENV{HOME} = $home;
	local $ENV{JAWNOS_AUDIO_BINARY} = "$dir/no-such-engine";
	local $ENV{JAWNOS_AUDIO_PLAN}    = "$dir/from-env.json";
	local $ENV{JAWNOS_AUDIO_MACHINE} = 'env-table';

	my $status = "$home/.president/audio.json";
	my $sup = start_supervisor(
		log  => "$dir/supervisor.log",
		args => ['--backend', 'null', '--socket', "$dir/audio.sock"],
	);

	my $s = wait_status($status, 5);
	ok($s, 'the supervisor writes status from the environment');
	is($s->{'plan'}, "$dir/from-env.json", 'JAWNOS_AUDIO_PLAN supplies the plan path') if $s;
	is($s->{'machine'}, 'env-table', 'JAWNOS_AUDIO_MACHINE supplies the machine name') if $s;

	my $code = stop_supervisor($sup);
	is($code, 0, 'the environment-driven supervisor stops cleanly');
	ok(!-e $status, 'and removes the status file');
}

# --- the machine name defaults to this host and the plan to $state_dir ---------
{
	my $dir  = tempdir(CLEANUP => 1);
	my $home = "$dir/home";
	make_path("$home/.president");
	local $ENV{HOME} = $home;
	local $ENV{JAWNOS_AUDIO_BINARY} = "$dir/no-such-engine";
	delete $ENV{JAWNOS_AUDIO_MACHINE};
	delete $ENV{XDG_STATE_HOME};

	my $status = "$home/.president/audio.json";
	my $sup = start_supervisor(
		log  => "$dir/supervisor.log",
		args => ['--backend', 'null', '--socket', "$dir/audio.sock"],
	);

	my $s = wait_status($status, 5);
	ok($s, 'the supervisor writes status with no machine flag');
	ok(defined $s->{'machine'} && length $s->{'machine'},
		'the machine defaults to a host name') if $s;
	is($s->{'plan'}, "$home/.local/state/jawnos/audio/audio-plan.json",
		'the plan defaults to the durable audio state dir') if $s;

	my $code = stop_supervisor($sup);
	is($code, 0, 'the default-plan supervisor stops cleanly');
	ok(!-e $status, 'and removes the status file');
}

# --- the picker's device and backend reach the engine ------------------------
{
	my $dir  = tempdir(CLEANUP => 1);
	my $home = "$dir/home";
	make_path("$home/.president");
	local $ENV{HOME} = $home;
	local $ENV{JAWNOS_AUDIO_MACHINE} = 'picker-table';
	delete $ENV{JAWNOS_AUDIO_BACKEND};
	delete $ENV{JAWNOS_AUDIO_DEVICE};

	my $plan = "$dir/audio-plan.json";
	open(my $pfh, '>', $plan) or die "plan: $!";
	print {$pfh} '{"manage":0,"plan":{"sources":[],"buses":[],"sinks":[],"routes":[]},"backend":"null","device":"hw:9,9"}';
	close $pfh;
	local $ENV{JAWNOS_AUDIO_PLAN} = $plan;

	my $args_log = "$dir/args.log";
	local $ENV{JAWNOS_AUDIO_BINARY} = write_script("$dir/arg-engine", <<'ENGINE');
use Socket qw(SOCK_STREAM);
use JSON::PP ();
use IO::Socket::UNIX;
open(my $log, '>>', $ENV{'AUDIO_TEST_ARGS'}) or exit 1;
print {$log} join(' ', @ARGV), "\n";
close $log;
my %arg;
for (my $i = 0; $i < @ARGV; $i++) {
	$arg{$ARGV[$i]} = $ARGV[$i + 1] if $ARGV[$i] =~ /^--/;
}
my $listener = IO::Socket::UNIX->new(
	Local => $arg{'--socket'}, Type => SOCK_STREAM, Listen => 5,
) or exit 1;
while (my $client = $listener->accept) {
	$client->autoflush(1);
	my $line = <$client>;
	my $obj = eval { JSON::PP->new->decode($line) };
	my $cmd = ref $obj eq 'HASH' ? ($obj->{'cmd'} // '') : '';
	if ($cmd eq 'quit') {
		print {$client} "{\"ok\":true}\n";
		close $client;
		last;
	}
	print {$client} "{\"ok\":true,\"take\":0,\"state\":\"idle\",\"backend\":\"null\",\"device\":\"hw:9,9\"}\n";
	close $client;
}
close $listener;
unlink $arg{'--socket'};
ENGINE
	local $ENV{AUDIO_TEST_ARGS} = $args_log;

	my $sup = start_supervisor(
		args => ['--socket', "$dir/audio.sock", '--handset-device', 'call.monitor'],
		log  => "$dir/supervisor.log",
	);
	my $saw = wait_for(sub {
		return 0 unless -s $args_log;
		my $raw = read_text($args_log);
		return $raw =~ /--backend null --device hw:9,9/;
	}, 10);
	ok($saw, 'the supervisor opens the picker device, not its own default')
		or diag('args: ' . (-s $args_log ? read_text($args_log) : '(none)'));
	like(read_text($args_log), qr/--handset-device call\.monitor/,
		'a handset device flag reaches the engine');

	# The supervisor writes status once before it spawns (with its own defaults)
	# and again after, so wait for the device rather than the first file.
	my $s = wait_for(sub {
		my $got = read_status("$home/.president/audio.json");
		return 0 unless $got;
		return $got->{'device'} eq 'hw:9,9' ? $got : 0;
	}, 10);
	ok($s, 'the status names the picker device') or diag('status: ' . read_text("$home/.president/audio.json"));
	is($s->{'backend'}, 'null', 'and the picker backend') if $s;
	is($s->{'handset_device'}, 'call.monitor', 'and the handset device') if $s;
	like($s->{'pid'} // '', qr/\A[1-9][0-9]*\z/, 'with the engine pid') if $s;

	my $code = stop_supervisor($sup);
	is($code, 0, 'the picker supervisor stops cleanly');
}

# --- the machine's own audio is carried while the engine manages ------------
{
	my $dir  = tempdir(CLEANUP => 1);
	my $home = "$dir/home";
	make_path("$home/.president", "$dir/bin");
	local $ENV{HOME} = $home;
	delete $ENV{JAWNOS_AUDIO_SYSTEM_DEVICE};

	# A plan whose switch is on and whose engine owns the interface.
	my $plan = "$dir/audio-plan.json";
	open(my $pfh, '>', $plan) or die "plan: $!";
	print {$pfh} '{"manage":1,"plan":{"sources":[],"buses":[],"sinks":[],"routes":[]},"backend":"alsa","device":"hw:1,0"}';
	close $pfh;
	local $ENV{JAWNOS_AUDIO_PLAN} = $plan;

	# A fake PulseAudio server; the supervisor must create the sink, make it
	# the default, and put the previous default back on the way out.
	my $sinks   = "$dir/sinks";
	my $default = "$dir/default";
	my $pactl_log = "$dir/pactl.log";
	open(my $sfh, '>', $sinks) or die "sinks: $!";
	print {$sfh} "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n";
	close $sfh;
	open(my $dfh, '>', $default) or die "default: $!";
	print {$dfh} "alsa_output.real\n";
	close $dfh;
	open(my $lfh, '>', $pactl_log) or die "log: $!";
	close $lfh;
	my $pactl = write_script("$dir/bin/pactl", <<'PACTL');
use JSON::PP ();
my $dir = $ENV{'FAKE_PACTL_DIR'} or exit 9;
open(my $log, '>>', "$dir/pactl.log") or exit 9;
print {$log} join(' ', @ARGV), "\n";
close $log;
sub slurp {
	my ($path) = @_;
	open(my $fh, '<', $path) or return '';
	local $/;
	my $text = <$fh>;
	close $fh;
	return defined $text ? $text : '';
}
my $cmd = $ARGV[0] // '';
if ($cmd eq 'info') { print "Server Name: PulseAudio (on PipeWire)\n"; exit 0; }
if (($ARGV[0] // '') eq '-f' && ($ARGV[1] // '') eq 'json' && ($ARGV[2] // '') eq 'list') {
	print '[{"index":0,"name":"alsa_output.real","properties":{';
	print '"alsa.card":"1","api.alsa.pcm.stream":"playback","node.name":"alsa_output.real"}}]';
	exit 0;
}
if ($cmd eq 'list' && ($ARGV[1] // '') eq 'short' && ($ARGV[2] // '') eq 'sinks') {
	print slurp("$dir/sinks"); exit 0;
}
if ($cmd eq 'get-default-sink') { print slurp("$dir/default"); exit 0; }
if ($cmd eq 'set-default-sink') {
	open(my $fh, '>', "$dir/default") or exit 9;
	print {$fh} $ARGV[1], "\n"; close $fh; exit 0;
}
if ($cmd eq 'load-module') {
	open(my $fh, '>>', "$dir/sinks") or exit 9;
	print {$fh} "1\tjawn_system\tmodule-null-sink\ts16le 2ch 48000Hz\n";
	close $fh;
	print "42\n"; exit 0;
}
if ($cmd eq 'unload-module') {
	open(my $fh, '>', "$dir/sinks") or exit 9;
	print {$fh} "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n";
	close $fh; exit 0;
}
exit 0;
PACTL
	local $ENV{PATH} = "$dir/bin:$ENV{PATH}";
	local $ENV{FAKE_PACTL_DIR} = $dir;
	local $ENV{JAWNOS_WIREPLUMBER_DIR} = "$dir/wireplumber";
	# A fake session manager; the host's real WirePlumber is never restarted.
	local $ENV{JAWNOS_SYSTEMCTL} = write_script("$dir/bin/systemctl", "exit 0;\n");

	# A little engine that records its arguments and answers the protocol.
	my $args_log = "$dir/args.log";
	local $ENV{JAWNOS_AUDIO_BINARY} = write_script("$dir/mix-engine", <<'ENGINE');
use IO::Socket::UNIX;
use Socket qw(SOCK_STREAM);
use JSON::PP ();
open(my $log, '>>', $ENV{'AUDIO_TEST_ARGS'}) or exit 1;
print {$log} join(' ', @ARGV), "\n";
close $log;
my %arg;
for (my $i = 0; $i < @ARGV; $i++) {
	$arg{$ARGV[$i]} = $ARGV[$i + 1] if $ARGV[$i] =~ /^--/;
}
my $listener = IO::Socket::UNIX->new(
	Local => $arg{'--socket'}, Type => SOCK_STREAM, Listen => 5,
) or exit 1;
my $backend = $arg{'--backend'} // 'alsa';
my $device  = $arg{'--device'}  // 'hw:1,0';
while (my $client = $listener->accept) {
	$client->autoflush(1);
	my $line = <$client>;
	my $obj = eval { JSON::PP->new->decode($line) };
	my $cmd = ref $obj eq 'HASH' ? ($obj->{'cmd'} // '') : '';
	if ($cmd eq 'quit') {
		print {$client} "{\"ok\":true}\n";
		close $client;
		last;
	}
	print {$client} "{\"ok\":true,\"take\":0,\"state\":\"patching\",\"system\":\"capturing\",\"mode\":\"playback\",\"backend\":\"$backend\",\"device\":\"$device\"}\n";
	close $client;
}
close $listener;
unlink $arg{'--socket'};
ENGINE
	local $ENV{AUDIO_TEST_ARGS} = $args_log;

	my $sup = start_supervisor(
		args => ['--socket', "$dir/audio.sock"],
		log  => "$dir/supervisor.log",
	);

	my $saw = wait_for(sub {
		return 0 unless -s $args_log;
		return read_text($args_log) =~ /--system-device jawn_system\.monitor/;
	}, 10);
	ok($saw, 'the engine is started to capture the system mix')
		or diag('args: ' . (-s $args_log ? read_text($args_log) : '(none)'));

	# The rule is written before the child opens the card, and only for the
	# playback node; the microphone node stays with PipeWire.
	my $rule = "$dir/wireplumber/51-jawnos-studio-card.conf";
	ok(-s $rule, 'the sink-only WirePlumber rule is installed before the engine');
	like(read_text($rule), qr/node\.name = "alsa_output\.real"/,
		'and names the card\'s playback node');
	unlike(read_text($rule), qr/alsa_input|api\.alsa\.pcm\.stream/,
		'while leaving the microphone to PipeWire');
	unlike(read_text($args_log), qr/--handset-device/,
		'the default handset source needs no flag; the engine already knows it');

	my $s = wait_for(sub {
		my $got = read_status("$home/.president/audio.json");
		return 0 unless $got;
		return ($got->{'system_device'} // '') eq 'jawn_system.monitor' ? $got : 0;
	}, 10);
	ok($s, 'and the status names the source') or diag('status: ' . read_text("$home/.president/audio.json"));
	is($s->{'handset_device'}, 'jawn_call_in.monitor', 'the status names the handset source too') if $s;
	is(read_text($default), "jawn_system\n", 'the machine default is the virtual sink while managed');
	like(read_text($pactl_log), qr/load-module module-null-sink sink_name=jawn_system/,
		'the sink was created');
	like(read_text($pactl_log), qr/set-default-sink jawn_system/,
		'and made the default');

	# The one-second status probe must keep the sink: the engine reports it is
	# capturing, so the supervisor's `capturing` branch re-ensures and returns.
	sleep 2;
	is(read_text($default), "jawn_system\n",
		'the sink stays the default across two status probes');
	ok(-e "$dir/audio-system-mix.json", 'and its state is kept');

	# A plan change while the child runs is followed, not deferred to a restart
	# that never comes: the saved pair moves to the shared backend, so the ALSA
	# child is asked to quit and the supervisor respawns on the new one.
	open(my $changed, '>', $plan) or die "plan: $!";
	print {$changed} '{"manage":1,"plan":{"sources":[],"buses":[],"sinks":[],"routes":[]},'
		. '"backend":"pipewire","device":"default"}';
	close $changed;
	my $respawned = wait_for(sub {
		my @line = split /\n/, read_text($args_log);
		return scalar( grep { /--backend pipewire/ } @line ) ? 1 : 0;
	}, 10);
	ok($respawned, 'the supervisor respawns the engine on the plan\'s new backend')
		or diag('args: ' . read_text($args_log));
	like(read_text("$dir/supervisor.log"), qr/asking it to restart on the saved choice/,
		'after asking the old child to quit');

	my $code = stop_supervisor($sup);
	is($code, 0, 'the managing supervisor stops cleanly');
	is(read_text($default), "alsa_output.real\n", 'the previous default is restored');
	like(read_text($pactl_log), qr/set-default-sink alsa_output\.real/,
		'the restore is the recorded default, not a guess');
	like(read_text($pactl_log), qr/unload-module 42/, 'and the sink is unloaded');
	ok(!-e $rule, 'the card rule is removed so the desktop gets the card back');
	ok(!-e "$dir/audio-system-mix.json", 'nothing is left behind');
}

# --- a table-like plan installs the duplex rule before the engine -----------
{
	my $dir  = tempdir(CLEANUP => 1);
	my $home = "$dir/home";
	make_path("$home/.president", "$dir/bin");
	local $ENV{HOME} = $home;
	delete $ENV{JAWNOS_AUDIO_SYSTEM_DEVICE};

	# A local input routed through the house bus: the engine needs capture.
	my $plan = "$dir/audio-plan.json";
	open(my $pfh, '>', $plan) or die "plan: $!";
	print {$pfh} '{"manage":1,"backend":"alsa","device":"hw:1,0","plan":{'
		. '"sources":[{"id":"gtr","kind":"input","channel":0}],'
		. '"buses":[{"id":"house"}],'
		. '"sinks":[{"id":"out","kind":"interface","channel":0}],'
		. '"routes":[{"from":"gtr","to":"house"},'
		. '{"from":"house","to":"out"}]}}';
	close $pfh;
	local $ENV{JAWNOS_AUDIO_PLAN} = $plan;

	my $sinks     = "$dir/sinks";
	my $default   = "$dir/default";
	my $pactl_log = "$dir/pactl.log";
	open(my $sfh, '>', $sinks) or die "sinks: $!";
	print {$sfh} "0\talsa_output.card1\tmodule-alsa-card\ts16le 2ch 48000Hz\n";
	close $sfh;
	open(my $dfh, '>', $default) or die "default: $!";
	print {$dfh} "alsa_output.card1\n";
	close $dfh;
	open(my $lfh, '>', $pactl_log) or die "log: $!";
	close $lfh;
	write_script("$dir/bin/pactl", <<'PACTL');
	my $dir = $ENV{'FAKE_PACTL_DIR'} or exit 9;
	open(my $log, '>>', "$dir/pactl.log") or exit 9;
	print {$log} join(' ', @ARGV), "\n";
	close $log;
	sub slurp {
		my ($path) = @_;
		open(my $fh, '<', $path) or return '';
		local $/;
		my $text = <$fh>;
		close $fh;
		return defined $text ? $text : '';
	}
	my $cmd = $ARGV[0] // '';
	my $all = join(' ', @ARGV);
	if ($cmd eq 'info') { print "Server Name: PulseAudio (on PipeWire)\n"; exit 0; }
	if ($all eq '-f json list sinks') {
		print '[{"index":0,"name":"alsa_output.card1","properties":{';
		print '"alsa.card":"1","api.alsa.pcm.stream":"playback","node.name":"alsa_output.card1"}}]';
		exit 0;
	}
	if ($all eq '-f json list sources') {
		print '[{"index":0,"name":"alsa_input.card1","properties":{';
		print '"alsa.card":"1","api.alsa.pcm.stream":"capture","node.name":"alsa_input.card1"}}]';
		exit 0;
	}
	if ($all eq 'list short sinks') { print slurp("$dir/sinks"); exit 0; }
	if ($cmd eq 'get-default-sink') { print slurp("$dir/default"); exit 0; }
	if ($cmd eq 'set-default-sink') {
		open(my $fh, '>', "$dir/default") or exit 9;
		print {$fh} $ARGV[1], "\n"; close $fh; exit 0;
	}
	if ($cmd eq 'load-module') {
		open(my $fh, '>>', "$dir/sinks") or exit 9;
		print {$fh} "1\tjawn_system\tmodule-null-sink\ts16le 2ch 48000Hz\n";
		close $fh; print "42\n"; exit 0;
	}
	if ($cmd eq 'unload-module') {
		open(my $fh, '>', "$dir/sinks") or exit 9;
		print {$fh} "0\talsa_output.card1\tmodule-alsa-card\ts16le 2ch 48000Hz\n";
		close $fh; exit 0;
	}
	exit 0;
PACTL
	local $ENV{PATH} = "$dir/bin:$ENV{PATH}";
	local $ENV{FAKE_PACTL_DIR} = $dir;
	local $ENV{JAWNOS_WIREPLUMBER_DIR} = "$dir/wireplumber";
	local $ENV{JAWNOS_SYSTEMCTL} = write_script("$dir/bin/systemctl", "exit 0;\n");

	my $args_log = "$dir/args.log";
	local $ENV{JAWNOS_AUDIO_BINARY} = write_script("$dir/duplex-engine", <<'ENGINE');
	use IO::Socket::UNIX;
	use Socket qw(SOCK_STREAM);
	use JSON::PP ();
	open(my $log, '>>', $ENV{'AUDIO_TEST_ARGS'}) or exit 1;
	print {$log} join(' ', @ARGV), "\n";
	close $log;
	my %arg;
	for (my $i = 0; $i < @ARGV; $i++) {
		$arg{$ARGV[$i]} = $ARGV[$i + 1] if $ARGV[$i] =~ /^--/;
	}
	my $listener = IO::Socket::UNIX->new(
		Local => $arg{'--socket'}, Type => SOCK_STREAM, Listen => 5,
	) or exit 1;
	while (my $client = $listener->accept) {
		$client->autoflush(1);
		my $line = <$client>;
		my $obj = eval { JSON::PP->new->decode($line) };
		my $cmd = ref $obj eq 'HASH' ? ($obj->{'cmd'} // '') : '';
		if ($cmd eq 'quit') {
			print {$client} "{\"ok\":true}\n";
			close $client;
			last;
		}
		my $mode = $ENV{'FAKE_ENGINE_MODE'} // 'duplex';
		print {$client} "{\"ok\":true,\"take\":0,\"state\":\"patching\","
			. "\"system\":\"capturing\",\"mode\":\"$mode\","
			. "\"backend\":\"alsa\",\"device\":\"hw:1,0\"}\n";
		close $client;
	}
	close $listener;
	unlink $arg{'--socket'};
ENGINE
	local $ENV{AUDIO_TEST_ARGS} = $args_log;
	# The old engine still says playback while the new plan needs duplex. The
	# union keeps both matches, so the patch can open capture.
	local $ENV{FAKE_ENGINE_MODE} = 'playback';

	my $sup = start_supervisor(
		args => ['--socket', "$dir/audio.sock"],
		log  => "$dir/supervisor.log",
	);

	my $saw = wait_for(sub {
		return 0 unless -s $args_log;
		return read_text($args_log) =~ /--backend alsa --device hw:1,0/;
	}, 10);
	ok($saw, 'the duplex engine opens the saved card')
		or diag('args: ' . (-s $args_log ? read_text($args_log) : '(none)'));

	my $rule = "$dir/wireplumber/51-jawnos-studio-card.conf";
	ok(-s $rule, 'the plan duplex installs the rule before the engine');
	like(read_text($rule), qr/node\.name = "alsa_output\.card1"/,
		'it names the playback node');
	like(read_text($rule), qr/node\.name = "alsa_input\.card1"/,
		'and the capture node even while the engine still says playback');
	is(read_text("$dir/default"), "jawn_system\n", 'the machine is on the virtual sink');

	my $code = stop_supervisor($sup);
	is($code, 0, 'the duplex supervisor stops cleanly');
	ok(!-e $rule, 'and the card is handed back');

	# The reverse transition: the plan is now playback but the engine is still
	# patching duplex. The rule may stay duplex until the respawn; the engine
	# must not fail.
	open(my $pfh2, '>', $plan) or die "plan2: $!";
	print {$pfh2} '{"manage":1,"backend":"alsa","device":"hw:1,0","plan":{'
		. '"sources":[],"buses":[],"sinks":[],"routes":[]}}';
	close $pfh2;
	$ENV{FAKE_ENGINE_MODE} = 'duplex';
	my $args_log2 = "$dir/args2.log";
	$ENV{AUDIO_TEST_ARGS} = $args_log2;

	my $sup2 = start_supervisor(
		args => ['--socket', "$dir/audio2.sock"],
		log  => "$dir/supervisor2.log",
	);
	my $saw2 = wait_for(sub {
		return 0 unless -s $args_log2;
		return read_text($args_log2) =~ /--backend alsa --device hw:1,0/;
	}, 10);
	ok($saw2, 'the playback plan still starts its engine')
		or diag('args: ' . (-s $args_log2 ? read_text($args_log2) : '(none)'));

	my $kept = wait_for(sub {
		return 0 unless -s $rule;
		return read_text($rule) =~ /alsa_input\.card1/;
	}, 10);
	ok($kept, 'the rule stays duplex while the engine is still patching duplex');
	like(read_text($rule), qr/alsa_output\.card1/, 'with both matches, not just playback');

	my $code2 = stop_supervisor($sup2);
	is($code2, 0, 'the reverse-transition supervisor stops cleanly');
	ok(!-e $rule, 'and the card is handed back too');
}

# --- a PipeWire engine plays the machine's audio out the real sink ----------
{
	my $dir  = tempdir(CLEANUP => 1);
	my $home = "$dir/home";
	make_path("$home/.president", "$dir/bin");
	local $ENV{HOME} = $home;
	delete $ENV{JAWNOS_AUDIO_SYSTEM_DEVICE};

	my $plan = "$dir/audio-plan.json";
	open(my $pfh, '>', $plan) or die "plan: $!";
	print {$pfh} '{"manage":1,"plan":{"sources":[],"buses":[],"sinks":[],"routes":[]},'
		. '"backend":"pipewire","device":"default"}';
	close $pfh;
	local $ENV{JAWNOS_AUDIO_PLAN} = $plan;

	my $sinks     = "$dir/sinks";
	my $default   = "$dir/default";
	my $pactl_log = "$dir/pactl.log";
	open(my $sfh, '>', $sinks) or die "sinks: $!";
	print {$sfh} "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n";
	close $sfh;
	open(my $dfh, '>', $default) or die "default: $!";
	print {$dfh} "alsa_output.real\n";
	close $dfh;
	open(my $lfh, '>', $pactl_log) or die "log: $!";
	close $lfh;
	write_script("$dir/bin/pactl", <<'PACTL');
	my $dir = $ENV{'FAKE_PACTL_DIR'} or exit 9;
	open(my $log, '>>', "$dir/pactl.log") or exit 9;
	print {$log} join(' ', @ARGV), "\n";
	close $log;
	sub slurp {
		my ($path) = @_;
		open(my $fh, '<', $path) or return '';
		local $/;
		my $text = <$fh>;
		close $fh;
		return defined $text ? $text : '';
	}
	my $cmd = $ARGV[0] // '';
	my $all = join(' ', @ARGV);
	if ($cmd eq 'info') { print "Server Name: PulseAudio (on PipeWire)\n"; exit 0; }
	if ($all eq 'list short sinks') { print slurp("$dir/sinks"); exit 0; }
	if ($cmd eq 'get-default-sink') { print slurp("$dir/default"); exit 0; }
	if ($cmd eq 'set-default-sink') {
		open(my $fh, '>', "$dir/default") or exit 9;
		print {$fh} $ARGV[1], "\n"; close $fh; exit 0;
	}
	if ($cmd eq 'load-module') {
		open(my $fh, '>>', "$dir/sinks") or exit 9;
		print {$fh} "1\tjawn_system\tmodule-null-sink\ts16le 2ch 48000Hz\n";
		close $fh; print "42\n"; exit 0;
	}
	if ($cmd eq 'unload-module') {
		open(my $fh, '>', "$dir/sinks") or exit 9;
		print {$fh} "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n";
		close $fh; exit 0;
	}
	exit 0;
PACTL
	local $ENV{PATH} = "$dir/bin:$ENV{PATH}";
	local $ENV{FAKE_PACTL_DIR} = $dir;
	local $ENV{JAWNOS_WIREPLUMBER_DIR} = "$dir/wireplumber";

	my $args_log = "$dir/args.log";
	my $env_log  = "$dir/env.log";
	local $ENV{JAWNOS_AUDIO_BINARY} = write_script("$dir/pw-engine", <<'ENGINE');
	use IO::Socket::UNIX;
	use Socket qw(SOCK_STREAM);
	use JSON::PP ();
	open(my $log, '>>', $ENV{'AUDIO_TEST_ARGS'}) or exit 1;
	print {$log} join(' ', @ARGV), "\n";
	close $log;
	open(my $env, '>>', $ENV{'AUDIO_TEST_ENV'}) or exit 1;
	print {$env} 'PIPEWIRE_NODE=' . ($ENV{'PIPEWIRE_NODE'} // '') . "\n";
	close $env;
	my %arg;
	for (my $i = 0; $i < @ARGV; $i++) {
		$arg{$ARGV[$i]} = $ARGV[$i + 1] if $ARGV[$i] =~ /^--/;
	}
	my $listener = IO::Socket::UNIX->new(
		Local => $arg{'--socket'}, Type => SOCK_STREAM, Listen => 5,
	) or exit 1;
	while (my $client = $listener->accept) {
		$client->autoflush(1);
		my $line = <$client>;
		my $obj = eval { JSON::PP->new->decode($line) };
		my $cmd = ref $obj eq 'HASH' ? ($obj->{'cmd'} // '') : '';
		if ($cmd eq 'quit') {
			print {$client} "{\"ok\":true}\n";
			close $client;
			last;
		}
		my $system = $ENV{'FAKE_ENGINE_SYSTEM'} // 'capturing';
		print {$client} "{\"ok\":true,\"take\":0,\"state\":\"patching\","
			. "\"system\":\"$system\",\"mode\":\"playback\","
			. "\"backend\":\"pipewire\",\"device\":\"default\"}\n";
		close $client;
	}
	close $listener;
	unlink $arg{'--socket'};
ENGINE
	local $ENV{AUDIO_TEST_ARGS} = $args_log;
	local $ENV{AUDIO_TEST_ENV}  = $env_log;
	local $ENV{FAKE_ENGINE_SYSTEM} = 'capturing';

	my $sup = start_supervisor(
		args => ['--socket', "$dir/audio.sock"],
		log  => "$dir/supervisor.log",
	);

	my $saw = wait_for(sub {
		return 0 unless -s $args_log;
		return read_text($args_log) =~ /--backend pipewire --device alsa_output\.real/;
	}, 10);
	ok($saw, 'the pipewire engine plays out the output the mix replaced')
		or diag('args: ' . (-s $args_log ? read_text($args_log) : '(none)'));
	like(read_text($args_log), qr/--system-device jawn_system\.monitor/,
		'and captures the system mix, as the ALSA backend does');
	like(read_text($env_log), qr/^PIPEWIRE_NODE=alsa_output\.real$/m,
		'the node reaches pipewire-alsa through the environment');
	ok(!-e "$dir/wireplumber/51-jawnos-studio-card.conf",
		'no WirePlumber card rule is installed for a PipeWire device');
	is(read_text($default), "jawn_system\n", 'the machine default is the virtual sink');

	my $code = stop_supervisor($sup);
	is($code, 0, 'the pipewire supervisor stops cleanly');
	is(read_text($default), "alsa_output.real\n", 'the previous default is restored');
	like(read_text($pactl_log), qr/unload-module 42/, 'and the sink is unloaded');
}

# --- a duplex PipeWire plan gets the mix too -------------------------------
{
	my $dir  = tempdir(CLEANUP => 1);
	my $home = "$dir/home";
	make_path("$home/.president", "$dir/bin");
	local $ENV{HOME} = $home;
	delete $ENV{JAWNOS_AUDIO_SYSTEM_DEVICE};

	my $plan = "$dir/audio-plan.json";
	open(my $pfh, '>', $plan) or die "plan: $!";
	print {$pfh} '{"manage":1,"plan":{"sources":[{"id":"gtr","kind":"input","channel":0}],'
		. '"buses":[],"sinks":[{"id":"out","kind":"interface"}],'
		. '"routes":[{"from":"gtr","to":"out"}]},'
		. '"backend":"pipewire","device":"default"}';
	close $pfh;
	local $ENV{JAWNOS_AUDIO_PLAN} = $plan;

	my $sinks     = "$dir/sinks";
	my $default   = "$dir/default";
	my $pactl_log = "$dir/pactl.log";
	open(my $sfh, '>', $sinks) or die "sinks: $!";
	print {$sfh} "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n";
	close $sfh;
	open(my $dfh, '>', $default) or die "default: $!";
	print {$dfh} "alsa_output.real\n";
	close $dfh;
	open(my $lfh, '>', $pactl_log) or die "log: $!";
	close $lfh;
	write_script("$dir/bin/pactl", <<'PACTL');
	my $dir = $ENV{'FAKE_PACTL_DIR'} or exit 9;
	open(my $log, '>>', "$dir/pactl.log") or exit 9;
	print {$log} join(' ', @ARGV), "\n";
	close $log;
	sub slurp {
		my ($path) = @_;
		open(my $fh, '<', $path) or return '';
		local $/;
		my $text = <$fh>;
		close $fh;
		return defined $text ? $text : '';
	}
	my $cmd = $ARGV[0] // '';
	my $all = join(' ', @ARGV);
	if ($cmd eq 'info') { print "Server Name: PulseAudio (on PipeWire)\n"; exit 0; }
	if ($all eq 'list short sinks') { print slurp("$dir/sinks"); exit 0; }
	if ($cmd eq 'get-default-sink') { print slurp("$dir/default"); exit 0; }
	if ($cmd eq 'set-default-sink') {
		open(my $fh, '>', "$dir/default") or exit 9;
		print {$fh} $ARGV[1], "\n"; close $fh; exit 0;
	}
	if ($cmd eq 'load-module') {
		open(my $fh, '>>', "$dir/sinks") or exit 9;
		print {$fh} "1\tjawn_system\tmodule-null-sink\ts16le 2ch 48000Hz\n";
		close $fh; print "42\n"; exit 0;
	}
	if ($cmd eq 'unload-module') {
		open(my $fh, '>', "$dir/sinks") or exit 9;
		print {$fh} "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n";
		close $fh; exit 0;
	}
	exit 0;
PACTL
	local $ENV{PATH} = "$dir/bin:$ENV{PATH}";
	local $ENV{FAKE_PACTL_DIR} = $dir;
	local $ENV{JAWNOS_WIREPLUMBER_DIR} = "$dir/wireplumber";

	my $args_log = "$dir/args.log";
	my $env_log  = "$dir/env.log";
	local $ENV{JAWNOS_AUDIO_BINARY} = write_script("$dir/pw-engine", <<'ENGINE');
	use IO::Socket::UNIX;
	use Socket qw(SOCK_STREAM);
	use JSON::PP ();
	open(my $log, '>>', $ENV{'AUDIO_TEST_ARGS'}) or exit 1;
	print {$log} join(' ', @ARGV), "\n";
	close $log;
	open(my $env, '>>', $ENV{'AUDIO_TEST_ENV'}) or exit 1;
	print {$env} 'PIPEWIRE_NODE=' . ($ENV{'PIPEWIRE_NODE'} // '') . "\n";
	close $env;
	my %arg;
	for (my $i = 0; $i < @ARGV; $i++) {
		$arg{$ARGV[$i]} = $ARGV[$i + 1] if $ARGV[$i] =~ /^--/;
	}
	my $listener = IO::Socket::UNIX->new(
		Local => $arg{'--socket'}, Type => SOCK_STREAM, Listen => 5,
	) or exit 1;
	while (my $client = $listener->accept) {
		$client->autoflush(1);
		my $line = <$client>;
		my $obj = eval { JSON::PP->new->decode($line) };
		my $cmd = ref $obj eq 'HASH' ? ($obj->{'cmd'} // '') : '';
		if ($cmd eq 'quit') {
			print {$client} "{\"ok\":true}\n";
			close $client;
			last;
		}
		print {$client} "{\"ok\":true,\"take\":0,\"state\":\"patching\","
			. "\"system\":\"capturing\",\"mode\":\"duplex\","
			. "\"backend\":\"pipewire\",\"device\":\"default\"}\n";
		close $client;
	}
	close $listener;
	unlink $arg{'--socket'};
ENGINE
	local $ENV{AUDIO_TEST_ARGS} = $args_log;
	local $ENV{AUDIO_TEST_ENV}  = $env_log;

	my $sup = start_supervisor(
		args => ['--socket', "$dir/audio.sock"],
		log  => "$dir/supervisor.log",
	);

	my $saw = wait_for(sub {
		return 0 unless -s $args_log;
		return read_text($args_log) =~ /--backend pipewire --device alsa_output\.real/;
	}, 10);
	ok($saw, 'a duplex pipewire engine plays the output the mix replaced')
		or diag('args: ' . (-s $args_log ? read_text($args_log) : '(none)'));
	like(read_text($args_log), qr/--system-device jawn_system\.monitor/,
		'and captures the system mix while it captures the routed input');
	like(read_text($env_log), qr/^PIPEWIRE_NODE=alsa_output\.real$/m,
		'the replaced node reaches pipewire-alsa through the environment');
	ok(!-e "$dir/wireplumber/51-jawnos-studio-card.conf",
		'no WirePlumber card rule is installed for a PipeWire device');
	is(read_text($default), "jawn_system\n", 'the machine default is the virtual sink');

	my $code = stop_supervisor($sup);
	is($code, 0, 'the duplex pipewire supervisor stops cleanly');
	is(read_text($default), "alsa_output.real\n", 'the previous default is restored');
	like(read_text($pactl_log), qr/unload-module 42/, 'and the sink is unloaded');
}

# --- a failed duplex PipeWire capture never leaves our sink as default -----
{
	my $dir  = tempdir(CLEANUP => 1);
	my $home = "$dir/home";
	make_path("$home/.president", "$dir/bin");
	local $ENV{HOME} = $home;
	delete $ENV{JAWNOS_AUDIO_SYSTEM_DEVICE};

	my $plan = "$dir/audio-plan.json";
	open(my $pfh, '>', $plan) or die "plan: $!";
	print {$pfh} '{"manage":1,"plan":{"sources":[{"id":"gtr","kind":"input","channel":0}],'
		. '"buses":[],"sinks":[{"id":"out","kind":"interface"}],'
		. '"routes":[{"from":"gtr","to":"out"}]},'
		. '"backend":"pipewire","device":"default"}';
	close $pfh;
	local $ENV{JAWNOS_AUDIO_PLAN} = $plan;

	my $default   = "$dir/default";
	my $pactl_log = "$dir/pactl.log";
	open(my $sfh, '>', "$dir/sinks") or die "sinks: $!";
	print {$sfh} "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n";
	close $sfh;
	open(my $dfh, '>', $default) or die "default: $!";
	print {$dfh} "alsa_output.real\n";
	close $dfh;
	open(my $lfh, '>', $pactl_log) or die "log: $!";
	close $lfh;
	write_script("$dir/bin/pactl", <<'PACTL');
	my $dir = $ENV{'FAKE_PACTL_DIR'} or exit 9;
	open(my $log, '>>', "$dir/pactl.log") or exit 9;
	print {$log} join(' ', @ARGV), "\n";
	close $log;
	sub slurp {
		my ($path) = @_;
		open(my $fh, '<', $path) or return '';
		local $/;
		my $text = <$fh>;
		close $fh;
		return defined $text ? $text : '';
	}
	my $cmd = $ARGV[0] // '';
	my $all = join(' ', @ARGV);
	if ($cmd eq 'info') { print "Server Name: PulseAudio (on PipeWire)\n"; exit 0; }
	if ($all eq 'list short sinks') { print slurp("$dir/sinks"); exit 0; }
	if ($cmd eq 'get-default-sink') { print slurp("$dir/default"); exit 0; }
	if ($cmd eq 'set-default-sink') {
		open(my $fh, '>', "$dir/default") or exit 9;
		print {$fh} $ARGV[1], "\n"; close $fh; exit 0;
	}
	if ($cmd eq 'load-module') {
		open(my $fh, '>>', "$dir/sinks") or exit 9;
		print {$fh} "1\tjawn_system\tmodule-null-sink\ts16le 2ch 48000Hz\n";
		close $fh; print "42\n"; exit 0;
	}
	if ($cmd eq 'unload-module') {
		open(my $fh, '>', "$dir/sinks") or exit 9;
		print {$fh} "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n";
		close $fh; exit 0;
	}
	exit 0;
PACTL
	local $ENV{PATH} = "$dir/bin:$ENV{PATH}";
	local $ENV{FAKE_PACTL_DIR} = $dir;
	local $ENV{JAWNOS_WIREPLUMBER_DIR} = "$dir/wireplumber";

	local $ENV{JAWNOS_AUDIO_BINARY} = write_script("$dir/pw-engine", <<'ENGINE');
	use IO::Socket::UNIX;
	use Socket qw(SOCK_STREAM);
	use JSON::PP ();
	my %arg;
	for (my $i = 0; $i < @ARGV; $i++) {
		$arg{$ARGV[$i]} = $ARGV[$i + 1] if $ARGV[$i] =~ /^--/;
	}
	my $listener = IO::Socket::UNIX->new(
		Local => $arg{'--socket'}, Type => SOCK_STREAM, Listen => 5,
	) or exit 1;
	while (my $client = $listener->accept) {
		$client->autoflush(1);
		my $line = <$client>;
		my $obj = eval { JSON::PP->new->decode($line) };
		my $cmd = ref $obj eq 'HASH' ? ($obj->{'cmd'} // '') : '';
		if ($cmd eq 'quit') {
			print {$client} "{\"ok\":true}\n";
			close $client;
			last;
		}
		print {$client} "{\"ok\":true,\"take\":0,\"state\":\"patching\","
			. "\"system\":\"unavailable\",\"mode\":\"duplex\","
			. "\"backend\":\"pipewire\",\"device\":\"default\"}\n";
		close $client;
	}
	close $listener;
	unlink $arg{'--socket'};
ENGINE

	my $sup = start_supervisor(
		args => ['--socket', "$dir/audio.sock"],
		log  => "$dir/supervisor.log",
	);

	my $healed = wait_for(sub {
		return read_text($default) eq "alsa_output.real\n"
			&& read_text($pactl_log) =~ /unload-module 42/
			&& !-e "$dir/audio-system-mix.json";
	}, 10);
	ok($healed, 'a failed capture puts the machine back on its own output')
		or diag('default: ' . read_text($default) . ' log: ' . read_text($pactl_log));
	ok(!-e "$dir/audio-system-mix.json", 'and keeps no state to strand');

	my $code = stop_supervisor($sup);
	is($code, 0, 'the supervisor still stops cleanly');
}

# --- an adopted engine lets go of a sink nobody captures ---------------------
{
	my $dir  = tempdir(CLEANUP => 1);
	my $home = "$dir/home";
	make_path("$home/.president", "$dir/bin");
	local $ENV{HOME} = $home;
	delete $ENV{JAWNOS_AUDIO_SYSTEM_DEVICE};

	# The switch is off. The sink below is a crash remnant: a supervisor died
	# between loading it and removing it, so nothing in this process remembers
	# it. The adopted engine reports idle, so the sink must go.
	my $plan = "$dir/audio-plan.json";
	open(my $pfh, '>', $plan) or die "plan: $!";
	print {$pfh} '{"manage":0,"plan":{"sources":[],"buses":[],"sinks":[],"routes":[]},'
		. '"backend":"null","device":"null"}';
	close $pfh;
	local $ENV{JAWNOS_AUDIO_PLAN} = $plan;

	open(my $state, '>', "$dir/audio-system-mix.json") or die "state: $!";
	print {$state} '{"sink":"jawn_system","source":"jawn_system.monitor",'
		. '"previous_default":"alsa_output.real","module_id":"42"}';
	close $state;

	my $sinks     = "$dir/sinks";
	my $default   = "$dir/default";
	my $pactl_log = "$dir/pactl.log";
	open(my $sfh, '>', $sinks) or die "sinks: $!";
	print {$sfh} "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n";
	print {$sfh} "42\tjawn_system\tmodule-null-sink\ts16le 2ch 48000Hz\n";
	close $sfh;
	open(my $dfh, '>', $default) or die "default: $!";
	print {$dfh} "jawn_system\n";
	close $dfh;
	open(my $lfh, '>', $pactl_log) or die "log: $!";
	close $lfh;
	write_script("$dir/bin/pactl", <<'PACTL');
my $dir = $ENV{'FAKE_PACTL_DIR'} or exit 9;
open(my $log, '>>', "$dir/pactl.log") or exit 9;
print {$log} join(' ', @ARGV), "\n";
close $log;
sub slurp {
	my ($path) = @_;
	open(my $fh, '<', $path) or return '';
	local $/;
	my $text = <$fh>;
	close $fh;
	return defined $text ? $text : '';
}
my $cmd = $ARGV[0] // '';
my $all = join(' ', @ARGV);
if ($cmd eq 'info') { print "Server Name: PulseAudio (on PipeWire)\n"; exit 0; }
if ($all eq 'list short sinks') { print slurp("$dir/sinks"); exit 0; }
if ($cmd eq 'get-default-sink') { print slurp("$dir/default"); exit 0; }
if ($cmd eq 'set-default-sink') {
	open(my $fh, '>', "$dir/default") or exit 9;
	print {$fh} $ARGV[1], "\n"; close $fh; exit 0;
}
if ($cmd eq 'unload-module') {
	open(my $fh, '>', "$dir/sinks") or exit 9;
	print {$fh} "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n";
	close $fh; exit 0;
}
exit 0;
PACTL
	local $ENV{PATH} = "$dir/bin:$ENV{PATH}";
	local $ENV{FAKE_PACTL_DIR} = $dir;
	local $ENV{JAWNOS_WIREPLUMBER_DIR} = "$dir/wireplumber";

	my $fake = start_fake_engine("$dir/audio.sock", "$dir/fake.ready",
		backend => 'null', device => 'null');
	ok(wait_for(sub { -s "$dir/fake.ready" }, 5), 'the leftover-sink engine is listening');

	my $sup = start_supervisor(
		args => ['--socket', "$dir/audio.sock"],
		log  => "$dir/supervisor.log",
	);

	my $healed = wait_for(sub {
		return read_text($default) eq "alsa_output.real\n"
			&& read_text($pactl_log) =~ /unload-module 42/
			&& !-e "$dir/audio-system-mix.json";
	}, 10);
	ok($healed, 'an adopted engine removes a sink left by a crashed supervisor')
		or diag('default: ' . read_text($default) . ' log: ' . read_text($pactl_log));
	is(read_text($default), "alsa_output.real\n",
		'and the machine\'s own output is the default again');

	my $code = stop_supervisor($sup);
	is($code, 0, 'the adopted supervisor stops cleanly');
	ok(wait_for(sub { reap_child($fake) }, 10), 'and asks the adopted engine to quit');
}

# --- no plan file: share the machine when a sound server is present ---------
{
	my $dir  = tempdir(CLEANUP => 1);
	my $home = "$dir/home";
	make_path("$home/.president", "$dir/bin");
	local $ENV{HOME} = $home;
	delete $ENV{JAWNOS_AUDIO_PLAN};
	delete $ENV{JAWNOS_AUDIO_BACKEND};
	delete $ENV{JAWNOS_AUDIO_DEVICE};

	# `pactl info` names a PulseAudio-compatible server (PipeWire's shim).
	write_script("$dir/bin/pactl", <<'PACTL');
if (($ARGV[0] // '') eq 'info') { print "Server Name: PulseAudio (on PipeWire)\n"; exit 0; }
exit 0;
PACTL
	local $ENV{PATH} = "$dir/bin:$ENV{PATH}";

	my $args_log = "$dir/args.log";
	local $ENV{JAWNOS_AUDIO_BINARY} = write_script("$dir/pipewire-engine", <<'ENGINE');
use IO::Socket::UNIX;
use Socket qw(SOCK_STREAM);
use JSON::PP ();
open(my $log, '>>', $ENV{'AUDIO_TEST_ARGS'}) or exit 1;
print {$log} join(' ', @ARGV), "\n";
close $log;
my %arg;
for (my $i = 0; $i < @ARGV; $i++) {
	$arg{$ARGV[$i]} = $ARGV[$i + 1] if $ARGV[$i] =~ /^--/;
}
my $listener = IO::Socket::UNIX->new(
	Local => $arg{'--socket'}, Type => SOCK_STREAM, Listen => 5,
) or exit 1;
while (my $client = $listener->accept) {
	$client->autoflush(1);
	my $line = <$client>;
	my $obj = eval { JSON::PP->new->decode($line) };
	my $cmd = ref $obj eq 'HASH' ? ($obj->{'cmd'} // '') : '';
	if ($cmd eq 'quit') {
		print {$client} "{\"ok\":true}\n";
		close $client;
		last;
	}
	print {$client} "{\"ok\":true,\"take\":0,\"state\":\"idle\",\"backend\":\"pipewire\",\"device\":\"default\"}\n";
	close $client;
}
close $listener;
unlink $arg{'--socket'};
ENGINE
	local $ENV{AUDIO_TEST_ARGS} = $args_log;

	my $sup = start_supervisor(
		log  => "$dir/supervisor.log",
		args => ['--socket', "$dir/audio.sock"],
	);
	my $saw = wait_for(sub {
		return 0 unless -s $args_log;
		return read_text($args_log) =~ /--backend pipewire --device default/;
	}, 10);
	ok($saw, 'with no plan and a sound server the engine opens pipewire on default')
		or diag('args: ' . (-s $args_log ? read_text($args_log) : '(none)'));

	my $code = stop_supervisor($sup);
	is($code, 0, 'the fallback supervisor stops cleanly');
	like(read_text("$dir/supervisor.log"),
		qr/no saved plan at .*audio-plan\.json; choosing backend pipewire on device default/,
		'and logs the missing plan and the pair it chose');

	# A regenerated plan may carry the switch and the plan with no chosen
	# interface (a machine that never picked one). The safe fallback still
	# decides; the boot write must not pin the compiled ALSA pair on it.
	my $durable = "$home/.local/state/jawnos/audio";
	make_path($durable);
	open(my $dfh, '>', "$durable/audio-plan.json") or die "plan: $!";
	print {$dfh} '{"manage":1,"plan":{"sources":[],"buses":[],"sinks":[],"routes":[]}}';
	close $dfh;
	unlink $args_log;
	my $second = start_supervisor(
		log  => "$dir/supervisor2.log",
		args => ['--socket', "$dir/audio.sock"],
	);
	my $again = wait_for(sub {
		return 0 unless -s $args_log;
		return read_text($args_log) =~ /--backend pipewire --device default/;
	}, 10);
	ok($again, 'a plan with no chosen interface still uses the safe fallback')
		or diag('args: ' . (-s $args_log ? read_text($args_log) : '(none)'));
	is(stop_supervisor($second), 0, 'the pairless-plan supervisor stops cleanly');
}

# --- no plan file and no server: the compiled ALSA default still applies -----
{
	my $dir  = tempdir(CLEANUP => 1);
	my $home = "$dir/home";
	make_path("$home/.president", "$dir/bin");
	local $ENV{HOME} = $home;
	delete $ENV{JAWNOS_AUDIO_PLAN};
	delete $ENV{JAWNOS_AUDIO_BACKEND};
	delete $ENV{JAWNOS_AUDIO_DEVICE};

	# An empty PATH: no pactl, wpctl or amixer, so no server is discovered. The
	# engine's own shebang names this Perl, so it still runs.
	local $ENV{PATH} = "$dir/bin";

	my $args_log = "$dir/args.log";
	local $ENV{JAWNOS_AUDIO_BINARY} = write_absolute_script("$dir/alsa-engine", <<'ENGINE');
use IO::Socket::UNIX;
use Socket qw(SOCK_STREAM);
use JSON::PP ();
open(my $log, '>>', $ENV{'AUDIO_TEST_ARGS'}) or exit 1;
print {$log} join(' ', @ARGV), "\n";
close $log;
my %arg;
for (my $i = 0; $i < @ARGV; $i++) {
	$arg{$ARGV[$i]} = $ARGV[$i + 1] if $ARGV[$i] =~ /^--/;
}
my $listener = IO::Socket::UNIX->new(
	Local => $arg{'--socket'}, Type => SOCK_STREAM, Listen => 5,
) or exit 1;
while (my $client = $listener->accept) {
	$client->autoflush(1);
	my $line = <$client>;
	my $obj = eval { JSON::PP->new->decode($line) };
	my $cmd = ref $obj eq 'HASH' ? ($obj->{'cmd'} // '') : '';
	if ($cmd eq 'quit') {
		print {$client} "{\"ok\":true}\n";
		close $client;
		last;
	}
	print {$client} "{\"ok\":true,\"take\":0,\"state\":\"idle\",\"backend\":\"alsa\",\"device\":\"hw:1,0\"}\n";
	close $client;
}
close $listener;
unlink $arg{'--socket'};
ENGINE
	local $ENV{AUDIO_TEST_ARGS} = $args_log;

	my $sup = start_supervisor(
		log  => "$dir/supervisor.log",
		args => ['--socket', "$dir/audio.sock"],
	);
	my $saw = wait_for(sub {
		return 0 unless -s $args_log;
		return read_text($args_log) =~ /--backend alsa --device hw:1,0/;
	}, 10);
	ok($saw, 'with no plan and no server the engine keeps alsa on hw:1,0')
		or diag('args: ' . (-s $args_log ? read_text($args_log) : '(none)'));

	my $code = stop_supervisor($sup);
	is($code, 0, 'the no-server fallback supervisor stops cleanly');
	like(read_text("$dir/supervisor.log"),
		qr/no saved plan at .*audio-plan\.json; choosing backend alsa on device hw:1,0/,
		'and logs the missing plan and the ALSA pair');
}

# --- an engine this supervisor did not start is asked to quit first ----------
{
	my $dir  = tempdir(CLEANUP => 1);
	my $home = "$dir/home";
	make_path("$home/.president");
	local $ENV{HOME} = $home;
	my $mark = "$dir/engine.pid";
	local $ENV{AUDIO_TEST_ENGINE_MARK} = $mark;
	delete $ENV{AUDIO_TEST_ORPHAN};
	local $ENV{JAWNOS_AUDIO_BINARY} = write_script("$dir/orphan-engine", <<'ENGINE');
my $mark = $ENV{'AUDIO_TEST_ENGINE_MARK'} || '';
open(my $fh, '>>', $mark) or exit 7;
print {$fh} "$$\n";
close $fh;
use IO::Socket::UNIX;
use Socket qw(SOCK_STREAM);
use JSON::PP ();
my %arg;
for (my $i = 0; $i < @ARGV; $i++) {
	$arg{$ARGV[$i]} = $ARGV[$i + 1] if $ARGV[$i] =~ /^--/;
}
my $listener = IO::Socket::UNIX->new(
	Local => $arg{'--socket'}, Type => SOCK_STREAM, Listen => 5,
) or exit 1;
my $orphan = $ENV{'AUDIO_TEST_ORPHAN'} ? 1 : 0;
while (my $client = $listener->accept) {
	$client->autoflush(1);
	my $line = <$client>;
	my $obj = eval { JSON::PP->new->decode($line) };
	my $cmd = ref $obj eq 'HASH' ? ($obj->{'cmd'} // '') : '';
	if ($cmd eq 'quit') {
		print {$client} "{\"ok\":true}\n";
		close $client;
		last;
	}
	next if $orphan;    # no status answer: adoption cannot see it
	print {$client} "{\"ok\":true,\"take\":0,\"state\":\"idle\",\"backend\":\"null\",\"device\":\"hw:1,0\"}\n";
	close $client;
}
close $listener;
unlink $arg{'--socket'};
ENGINE

	my $sockpath = "$dir/orphan.sock";
	my $orphan = fork();
	die "fork: $!" unless defined $orphan;
	if (!$orphan) {
		$ENV{'AUDIO_TEST_ORPHAN'} = 1;
		exec $^X, $ENV{'JAWNOS_AUDIO_BINARY'}, '--serve', '--socket', $sockpath
			or POSIX::_exit(127);
	}
	push @children, $orphan;
	ok(wait_for(sub { -S $sockpath }, 5), 'the orphan engine is serving the socket');

	my $status = "$home/.president/audio.json";
	my $log    = "$dir/supervisor.log";
	my $sup = start_supervisor(
		log  => $log,
		args => ['--backend', 'null', '--device', 'hw:1,0', '--socket', $sockpath],
	);

	ok(wait_for(sub { reap_child($orphan) }, 10),
		'the supervisor asked the orphan engine to quit before spawning')
		or diag('log: ' . read_text($log));
	my $s = wait_for(sub {
		my $data = read_status($status);
		return 0 unless $data && defined $data->{'pid'};
		return $data;
	}, 10);
	ok($s, 'and only then started its own engine') or diag('status: ' . read_text($status));
	my $started = $s ? $s->{'pid'} : undef;
	# The status file is written as soon as fork returns; the engine records
	# its own pid a moment later. Wait for the two to name the same process
	# rather than reading that mark when it may still hold only the orphan.
	my $matched = $started && wait_for(sub {
		my @pids = grep { /\A[0-9]+\z/ } split /\n/, read_text($mark);
		return scalar( grep { $_ == $started } @pids );
	}, 5);
	ok($matched, 'the child in the status file is the engine that ran')
		or diag('status pid: ' . ($started // '(none)') . ' mark: ' . read_text($mark));
	push @children, $started if $started;

	my $code = stop_supervisor($sup);
	is($code, 0, 'the orphan-clearing supervisor stops cleanly');
	my $text = read_text($log);
	like($text,
		qr/found engine \Q$orphan\E already serving \Q$sockpath\E but not as my child; asking it to quit/,
		'and logs the engine it found');
	like($text, qr/engine \Q$orphan\E quit/, 'and that the orphan left');
}

# --- a process this supervisor cannot identify is left alone -----------------
{
	my $dir  = tempdir(CLEANUP => 1);
	my $home = "$dir/home";
	make_path("$home/.president", "$dir/bin");
	local $ENV{HOME} = $home;
	delete $ENV{JAWNOS_AUDIO_PLAN};
	my $mark = "$dir/engine.pid";
	local $ENV{AUDIO_TEST_ENGINE_MARK} = $mark;
	local $ENV{JAWNOS_AUDIO_BINARY} = write_script("$dir/engine", <<'ENGINE');
my $mark = $ENV{'AUDIO_TEST_ENGINE_MARK'} || '';
open(my $fh, '>', $mark) or exit 7;
print {$fh} "$$\n";
close $fh;
sleep 600;
ENGINE

	# Same flags, same socket, but a different binary path: not this engine.
	my $sockpath = "$dir/decoy.sock";
	my $decoy_script = write_absolute_script("$dir/decoy", "sleep 600;\n");
	my $decoy = fork();
	die "fork: $!" unless defined $decoy;
	if (!$decoy) {
		exec $^X, $decoy_script, '--serve', '--socket', $sockpath or POSIX::_exit(127);
	}
	push @children, $decoy;
	sleep 0.2;

	my $status = "$home/.president/audio.json";
	my $sup = start_supervisor(
		log  => "$dir/supervisor.log",
		args => ['--backend', 'null', '--device', 'hw:1,0', '--socket', $sockpath],
	);
	my $s = wait_for(sub {
		my $data = read_status($status);
		return 0 unless $data && defined $data->{'pid'};
		return -s $mark ? $data : 0;
	}, 10);
	ok($s, 'a process this supervisor cannot identify does not block its spawn')
		or diag('status: ' . read_text($status) . ' log: ' . read_text("$dir/supervisor.log"));
	ok(kill(0, $decoy), 'and that process is still alive: it was never signalled');

	my $code = stop_supervisor($sup);
	is($code, 0, 'the decoy supervisor stops cleanly');
	kill 'KILL', $decoy;
	waitpid($decoy, 0);
}

# --- the staged binary is a build artifact ------------------------------------
my $audio_src = read_text($audio);
like($audio_src, qr/sub ensure_engine_fresh/,
	'the supervisor checks the staged engine before spawning');
like($audio_src, qr/build_engine\.pl.*--if-stale/s,
	'through the one stale check');
like($audio_src, qr/ensure_engine_fresh\(\);[\s\S]*?unless \(-f \$binary/,
	'before the missing-binary check, so the first run can build it');
like($audio_src, qr/return if defined \$given\{'binary'\}[\s\S]*?JAWNOS_AUDIO_BINARY/,
	'a hand-run supervisor never rebuilds a binary it was given');

done_testing();
