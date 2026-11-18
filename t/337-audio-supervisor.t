# tests-for: perl/Audio.pl
# covers:    the audio supervisor: a live engine found on its socket at start is
#            adopted (no child, no second engine, --check 0) and replaced only
#            once it stops answering, a stale socket file is removed and an
#            engine started, a quick-exit engine is restarted on a growing
#            backoff with the count and last exit in the status file, a live
#            engine makes --check 0 and --status name it, a second supervisor
#            refuses the lock without touching the first, and a missing binary
#            is reported once while the supervisor keeps waiting.

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
# engine. Like the engine it exits on quit and unlinks its socket; a KILL from
# the test leaves the socket file behind, which is the stale case.
sub start_fake_engine {
	my ($path, $ready) = @_;
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
			print {$client} qq({"ok":true,"take":0,"state":"idle"}\n);
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
	my $fake = start_fake_engine($sockpath, "$dir/fake.ready");
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

	kill 'KILL', $fake;
	waitpid($fake, 0);

	my $s = wait_for(sub {
		my $data = read_status($status);
		return 0 unless $data && defined $data->{'pid'} && -s $mark;
		return $data;
	}, 15);
	ok($s, 'the supervisor starts its own engine after the adopted one dies');
	ok(!$s->{'adopted'}, 'the status file no longer says adopted') if $s;
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

done_testing();
