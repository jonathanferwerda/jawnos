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
#            The playback target is checked too: a correct graph is left alone,
#            a link from the engine's output into the sink it captures is cut
#            and ended if it re-forms, and a spawn whose output is `default`
#            beside that sink is refused before a child starts.
#            An engine the supervisor did not start but can identify as this
#            binary on this socket is asked to quit before a spawn; one that
#            ignores the quit (or cannot be reached because the boot wipe took
#            its socket file) gets TERM and is spawned over; a process it
#            cannot identify is left alone. A refused spawn is recorded and
#            retried, never an exit. With no saved plan the pair is
#            pipewire/default when a sound server answers, alsa/hw:1,0 when
#            none does, and the choice is logged once. The plan defaults to
#            the durable audio state dir, not the wiped ~/.president, and the
#            system-mix state follows the plan beside it. The block the engine
#            is spawned with follows the saved plan's mode: 64/256 while a
#            duplex plan is armed, 256/1024 for playback only, and an operator
#            period or buffer still wins. A plan that flips mode while an engine
#            runs asks it to restart on the new block, except while a take is
#            recording, so an armed WAV is never cut.

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

# The block one saved plan is spawned with, and what the status reports, from a
# child that only logs its argv. Flags pin the backend so the fallback probe
# never runs and the answer does not depend on whether this box has a sound
# server.
sub block_for_plan {
	my ($plan_json, %opt) = @_;
	my $dir  = tempdir(CLEANUP => 1);
	my $home = "$dir/home";
	make_path("$home/.president");
	local $ENV{HOME} = $home;
	delete local $ENV{JAWNOS_AUDIO_PERIOD};
	delete local $ENV{JAWNOS_AUDIO_BUFFER};
	$ENV{JAWNOS_AUDIO_PERIOD} = $opt{'period'} if defined $opt{'period'};
	$ENV{JAWNOS_AUDIO_BUFFER} = $opt{'buffer'} if defined $opt{'buffer'};
	my $plan = "$dir/audio-plan.json";
	if (defined $plan_json) {
		open(my $pfh, '>', $plan) or die "plan: $!";
		print {$pfh} $plan_json;
		close $pfh;
	}
	# Point at the path either way: an absent file is the "no saved plan" case.
	local $ENV{JAWNOS_AUDIO_PLAN} = $plan;
	my $args_log = "$dir/args.log";
	local $ENV{AUDIO_TEST_ARGS} = $args_log;
	local $ENV{JAWNOS_AUDIO_BINARY} = write_script("$dir/block-engine", <<'ENGINE');
open(my $log, '>>', $ENV{'AUDIO_TEST_ARGS'}) or exit 1;
print {$log} join(' ', @ARGV), "\n";
close $log;
sleep 600;
ENGINE
	my $sup = start_supervisor(
		args => [ '--socket', "$dir/audio.sock", '--backend', 'null', '--device', 'hw:9,9' ],
		log  => "$dir/supervisor.log",
	);
	my $args = wait_for( sub { -s $args_log ? read_text($args_log) : 0 }, 10 );
	my $status = wait_for(sub {
		my $got = read_status("$home/.president/audio.json");
		return 0 unless $got;
		return $got->{'pid'} ? $got : 0;
	}, 10);
	stop_supervisor($sup);
	return ( $args // '', $status );
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

# --- a peer plan passes the uplink and its key, and only when both are there -
{
	delete local $ENV{JAWNOS_AUDIO_SESSION_KEY};
	my $key = 'ab' x 32;
	my $run = sub {
		my ($doc) = @_;
		my $dir  = tempdir(CLEANUP => 1);
		my $home = "$dir/home";
		make_path("$home/.president");
		local $ENV{HOME} = $home;
		my $plan = "$dir/audio-plan.json";
		open(my $pfh, '>', $plan) or die "plan: $!";
		print {$pfh} JSON::PP->new->encode($doc);
		close $pfh;
		local $ENV{JAWNOS_AUDIO_PLAN} = $plan;
		my $args_log = "$dir/args.log";
		my $env_log  = "$dir/env.log";
		local $ENV{AUDIO_TEST_ARGS} = $args_log;
		local $ENV{AUDIO_TEST_ENV}  = $env_log;
		local $ENV{JAWNOS_AUDIO_BINARY} = write_script("$dir/uplink-engine", <<'ENGINE');
open(my $log, '>>', $ENV{'AUDIO_TEST_ARGS'}) or exit 1;
print {$log} join(' ', @ARGV), "\n";
close $log;
open(my $env, '>>', $ENV{'AUDIO_TEST_ENV'}) or exit 1;
print {$env} 'SESSION_KEY=' . ($ENV{'JAWNOS_AUDIO_SESSION_KEY'} // '<unset>') . "\n";
close $env;
sleep 600;
ENGINE
		my $sup = start_supervisor(
			args => [ '--socket', "$dir/audio.sock", '--backend', 'null', '--device', 'hw:9,9' ],
			log  => "$dir/supervisor.log",
		);
		wait_for(sub { -s $args_log }, 10);
		my $args = read_text($args_log);
		my $env  = -s $env_log ? read_text($env_log) : '';
		my $log  = read_text("$dir/supervisor.log");
		stop_supervisor($sup);
		return { args => $args, env => $env, log => $log };
	};

	my $peer_plan = {
		manage => 0, backend => 'null', device => 'hw:9,9',
		plan => {
			sources => [ { id => 'phone', kind => 'peer', channel => 0 } ],
			buses   => [], sinks => [], routes => [],
		},
	};

	my $with = $run->({
		%$peer_plan,
		uplink => '127.0.0.1:7060', session_key => $key,
	});
	like($with->{args}, qr/--uplink 127\.0\.0\.1:7060/,
		'a peer plan passes the saved uplink address');
	like($with->{env}, qr/^SESSION_KEY=\Q$key\E$/m,
		'and the session key reaches the child through the environment');
	unlike($with->{args}, qr/\Q$key\E/, 'the key is not in argv');

	my $missing = $run->($peer_plan);
	unlike($missing->{args}, qr/--uplink\b/,
		'a peer plan with no saved address passes no uplink');
	like($missing->{env}, qr/^SESSION_KEY=<unset>$/m, 'and no key reaches the child');
	like($missing->{log}, qr/not passing --uplink: .*no uplink address/,
		'and the supervisor says why');

	my $bad_address = $run->({
		%$peer_plan,
		uplink => 'not-an-address', session_key => $key,
	});
	unlike($bad_address->{args}, qr/--uplink\b/, 'an invalid address passes no uplink');
	like($bad_address->{env}, qr/^SESSION_KEY=<unset>$/m, 'and still no key');
	like($bad_address->{log}, qr/not passing --uplink: .*not a host and port/,
		'and the supervisor names the bad address');

	my $bad_key = $run->({
		%$peer_plan,
		uplink => '127.0.0.1:7060', session_key => 'short',
	});
	unlike($bad_key->{args}, qr/--uplink\b/, 'a missing key passes no uplink');
	like($bad_key->{env}, qr/^SESSION_KEY=<unset>$/m, 'and the child gets no key');
	like($bad_key->{log}, qr/not passing --uplink: .*no session key/,
		'and the supervisor says the key is missing');

	my $far = $run->({
		%$peer_plan,
		uplink => '127.0.0.1:7060', session_key => $key,
		plan => {
			sources => [ { id => 'far', kind => 'peer', machine => 'elsewhere', channel => 0 } ],
			buses   => [], sinks => [], routes => [],
		},
	});
	unlike($far->{args}, qr/--uplink\b/,
		'a peer on another machine opens no uplink here');
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
open(my $order, '>>', "$dir/order.log") or exit 9;
print {$order} join(' ', @ARGV), "\n";
close $order;
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
		open(my $order, '>>', ($ENV{'FAKE_PACTL_DIR'} || '.') . '/order.log') or exit 9;
		print {$order} "engine quit\n";
		close $order;
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

	# The reset leaves only the stop's own order: the quit the old child answered
	# for the plan change is not part of the handover under test.
	open(my $ofh, '>', "$dir/order.log") or die "order log: $!";
	close $ofh;

	my $code = stop_supervisor($sup);
	is($code, 0, 'the managing supervisor stops cleanly');
	is(read_text($default), "alsa_output.real\n", 'the previous default is restored');
	like(read_text($pactl_log), qr/set-default-sink alsa_output\.real/,
		'the restore is the recorded default, not a guess');
	like(read_text($pactl_log), qr/unload-module 42/, 'and the sink is unloaded');
	ok(!-e $rule, 'the card rule is removed so the desktop gets the card back');
	ok(!-e "$dir/audio-system-mix.json", 'nothing is left behind');

	# The handover order: the engine is asked to quit and lets go of the device
	# before the sink goes. Removing it first left the same audio on two paths
	# and then dropped the machine's own streams onto an output held at unity.
	my $order = read_text("$dir/order.log");
	my $quit_at = index($order, 'engine quit');
	my $back_at = index($order, 'set-default-sink alsa_output.real');
	ok($quit_at >= 0, 'the engine is asked to quit on a clean stop');
	ok($back_at >= 0, 'and the machine is handed back');
	ok($quit_at < $back_at, 'only after the engine has let go of the output');
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
unlink $arg{'--socket'} if defined $arg{'--socket'} && -e $arg{'--socket'};
my $listener = IO::Socket::UNIX->new(
	Local => $arg{'--socket'}, Type => SOCK_STREAM, Listen => 5,
) or exit 1;
my $orphan = $ENV{'AUDIO_TEST_ORPHAN'} ? 1 : 0;
my $ignore = $ENV{'AUDIO_TEST_IGNORE_QUIT'} ? 1 : 0;
while (my $client = $listener->accept) {
	$client->autoflush(1);
	my $line = <$client>;
	my $obj = eval { JSON::PP->new->decode($line) };
	my $cmd = ref $obj eq 'HASH' ? ($obj->{'cmd'} // '') : '';
	if ($cmd eq 'quit') {
		print {$client} "{\"ok\":true}\n";
		close $client;
		next if $ignore;    # the request arrived; this engine just will not go
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

# --- an engine that ignores the quit gets TERM, and the spawn follows --------
# The failure this covers: ./jawn's boot wipe deleted audio.sock while an engine
# from the previous boot still held the listening end, so the quit request could
# never arrive. The supervisor used to wait, refuse, and leave the machine with
# an engine it could not reach and no supervisor of its own.
{
	my $dir  = tempdir(CLEANUP => 1);
	my $home = "$dir/home";
	make_path("$home/.president");
	local $ENV{HOME} = $home;
	my $mark = "$dir/engine.pid";
	local $ENV{AUDIO_TEST_ENGINE_MARK} = $mark;
	local $ENV{JAWNOS_AUDIO_BINARY} = write_script("$dir/stubborn-engine", <<'ENGINE');
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
unlink $arg{'--socket'} if defined $arg{'--socket'} && -e $arg{'--socket'};
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
		next;    # the quit arrived; this engine simply does not take it
	}
	next if $orphan;    # no status answer: adoption cannot see it
	print {$client} "{\"ok\":true,\"take\":0,\"state\":\"idle\",\"backend\":\"null\",\"device\":\"hw:1,0\"}\n";
	close $client;
}
close $listener;
ENGINE

	my $sockpath = "$dir/stubborn.sock";
	my $orphan = fork();
	die "fork: $!" unless defined $orphan;
	if (!$orphan) {
		$ENV{'AUDIO_TEST_ORPHAN'} = 1;
		exec $^X, $ENV{'JAWNOS_AUDIO_BINARY'}, '--serve', '--socket', $sockpath
			or POSIX::_exit(127);
	}
	push @children, $orphan;
	ok(wait_for(sub { -S $sockpath }, 5), 'the stubborn engine holds the socket');

	# The boot wipe: the file goes, the listening end does not.
	unlink $sockpath;
	ok(!-S $sockpath, 'the socket file is wiped with the engine still running');

	my $status = "$home/.president/audio.json";
	my $log    = "$dir/supervisor.log";
	my $sup = start_supervisor(
		log  => $log,
		args => ['--backend', 'null', '--device', 'hw:1,0', '--socket', $sockpath],
	);

	ok(wait_for(sub { reap_child($orphan) }, 25),
		'an engine the socket cannot reach is sent TERM and leaves')
		or diag('log: ' . read_text($log));
	my $s = wait_for(sub {
		my $data = read_status($status);
		return 0 unless $data && defined $data->{'pid'};
		return $data;
	}, 15);
	ok($s, 'and the supervisor then starts its own engine')
		or diag('status: ' . read_text($status) . ' log: ' . read_text($log));
	my $started = $s ? $s->{'pid'} : undef;
	ok($started && wait_for(sub {
		my @pids = grep { /\A[0-9]+\z/ } split /\n/, read_text($mark);
		return scalar( grep { $_ == $started } @pids );
	}, 5), 'the child in the status file is the engine that ran')
		or diag('status pid: ' . ($started // '(none)') . ' mark: ' . read_text($mark));
	push @children, $started if $started;

	my $code = stop_supervisor($sup);
	is($code, 0, 'the supervisor that took the ladder stops cleanly');
	my $text = read_text($log);
	like($text, qr/engine \Q$orphan\E did not quit over the socket; sending it TERM/,
		'and the log shows the ladder, not a refusal');
	like($text, qr/engine \Q$orphan\E is gone/, 'with the engine gone');
	unlike($text, qr/not starting a second one/, 'and no refusal to spawn');
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

# --- the engine's `system` value decides the sink ----------------------------
# Each of the engine's four capture states drives one action: `pending` and
# `capturing` keep the mix, `off` removes it without ending the child, and
# `unavailable` removes it and ends the child once. The respawn after that
# carries no source, so a machine that cannot capture cannot loop.
{
	my $dir  = tempdir(CLEANUP => 1);
	my $home = "$dir/home";
	make_path("$home/.president", "$dir/bin");
	local $ENV{HOME} = $home;
	delete $ENV{JAWNOS_AUDIO_SYSTEM_DEVICE};
	delete $ENV{JAWNOS_AUDIO_BACKEND};
	delete $ENV{JAWNOS_AUDIO_DEVICE};

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

	# The engine reads its capture state from a file on every status request, so
	# the test can move it through the four values without a restart, and logs
	# every command so `quit` is countable.
	my $system_file = "$dir/system";
	my $args_log    = "$dir/args.log";
	my $cmd_log     = "$dir/cmds.log";
	open(my $sysfh, '>', $system_file) or die "system: $!";
	print {$sysfh} "capturing\n";
	close $sysfh;
	open(my $afh, '>', $args_log) or die "args: $!";
	close $afh;
	open(my $cfh, '>', $cmd_log) or die "cmds: $!";
	close $cfh;
	local $ENV{JAWNOS_AUDIO_BINARY} = write_script("$dir/value-engine", <<'ENGINE');
use IO::Socket::UNIX;
use Socket qw(SOCK_STREAM);
use JSON::PP ();
my %arg;
for (my $i = 0; $i < @ARGV; $i++) {
	$arg{$ARGV[$i]} = $ARGV[$i + 1] if $ARGV[$i] =~ /^--/;
}
open(my $alog, '>>', $ENV{'FAKE_ENGINE_ARGS'}) or exit 1;
print {$alog} join(' ', @ARGV), "\n";
close $alog;
my $listener = IO::Socket::UNIX->new(
	Local => $arg{'--socket'}, Type => SOCK_STREAM, Listen => 5,
) or exit 1;
while (my $client = $listener->accept) {
	$client->autoflush(1);
	my $line = <$client>;
	my $obj = eval { JSON::PP->new->decode($line) };
	my $cmd = ref $obj eq 'HASH' ? ($obj->{'cmd'} // '') : '';
	open(my $clog, '>>', $ENV{'FAKE_ENGINE_CMDS'}) or exit 1;
	print {$clog} "$cmd\n";
	close $clog;
	if ($cmd eq 'quit') {
		print {$client} "{\"ok\":true}\n";
		close $client;
		last;
	}
	my $system = 'capturing';
	if (open(my $sfh, '<', $ENV{'FAKE_ENGINE_SYSTEM'})) {
		$system = <$sfh> // 'capturing';
		chomp $system;
		close $sfh;
	}
	print {$client} "{\"ok\":true,\"take\":0,\"state\":\"patching\","
		. "\"system\":\"$system\",\"mode\":\"playback\","
		. "\"backend\":\"pipewire\",\"device\":\"default\"}\n";
	close $client;
}
close $listener;
unlink $arg{'--socket'};
ENGINE
	local $ENV{FAKE_ENGINE_ARGS}   = $args_log;
	local $ENV{FAKE_ENGINE_CMDS}   = $cmd_log;
	local $ENV{FAKE_ENGINE_SYSTEM} = $system_file;

	my $sup = start_supervisor(
		args => ['--socket', "$dir/audio.sock"],
		log  => "$dir/supervisor.log",
	);

	my $captured = wait_for(sub {
		return read_text($default) eq "jawn_system\n"
			&& read_text($args_log) =~ /--system-device jawn_system\.monitor/;
	}, 10);
	ok($captured, 'a capturing engine keeps the sink and is given the monitor')
		or diag('default: ' . read_text($default) . ' args: ' . read_text($args_log));

	sleep 2.2;
	is(read_text($default), "jawn_system\n", 'capturing keeps the sink across a probe');
	ok(-e "$dir/audio-system-mix.json", 'and its state survives');

	open(my $pend, '>', $system_file) or die "system: $!";
	print {$pend} "pending\n";
	close $pend;
	sleep 2.2;
	is(read_text($default), "jawn_system\n", 'pending keeps the mix while the capture opens');
	ok(-e "$dir/audio-system-mix.json", 'and keeps its state for that retry');
	unlike(read_text($cmd_log), qr/^quit$/m, 'neither value ends the child');

	open(my $off, '>', $system_file) or die "system: $!";
	print {$off} "off\n";
	close $off;
	my $removed = wait_for(sub {
		return read_text($default) eq "alsa_output.real\n"
			&& read_text($pactl_log) =~ /unload-module 42/
			&& !-e "$dir/audio-system-mix.json";
	}, 10);
	ok($removed, 'off removes a mix the pass no longer asks for')
		or diag('default: ' . read_text($default) . ' log: ' . read_text($pactl_log));
	ok(!-e "$dir/audio-system-mix.json", 'and its state with it');
	unlike(read_text($cmd_log), qr/^quit$/m, 'while the child that reported off keeps running');

	# Back to capturing: the same child, a fresh mix.
	open(my $on, '>', $system_file) or die "system: $!";
	print {$on} "capturing\n";
	close $on;
	my $again = wait_for(sub {
		return read_text($default) eq "jawn_system\n"
			&& -e "$dir/audio-system-mix.json";
	}, 10);
	ok($again, 'capturing again makes the mix the default once more');

	# A capture the engine can never make ends the child, once, and the respawn
	# carries no source: the sink is not recreated and no `quit` loop starts.
	open(my $bad, '>', $system_file) or die "system: $!";
	print {$bad} "unavailable\n";
	close $bad;
	my $ended = wait_for(sub {
		return read_text($default) eq "alsa_output.real\n"
			&& read_text($cmd_log) =~ /^quit$/m;
	}, 10);
	ok($ended, 'unavailable hands the machine back and asks the child to quit')
		or diag('default: ' . read_text($default) . ' cmds: ' . read_text($cmd_log));

	my $respawned = wait_for(sub {
		my @line = grep { length } split /\n/, read_text($args_log);
		return 0 unless @line >= 2;
		return $line[1] !~ /--system-device/ ? 1 : 0;
	}, 10);
	ok($respawned, 'the next spawn is given no system source')
		or diag('args: ' . read_text($args_log));

	sleep 2.5;
	my @quit = read_text($cmd_log) =~ /^quit$/mg;
	is(scalar(@quit), 1, 'the unusable child is asked to quit exactly once');
	unlike(read_text($args_log), qr/--system-device jawn_system\.monitor[\s\S]*--system-device/,
		'and no later spawn recreates the source');

	my $code = stop_supervisor($sup);
	is($code, 0, 'the value-driven supervisor stops cleanly');
	like(read_text("$dir/supervisor.log"), qr/restarting it without that source/,
		'and said the respawn would carry no capture source');
}

# --- a source whose sink pactl does not list is never passed -----------------
# The run this guards: an engine started with `--system-device
# jawn_system.monitor` while no `jawn_system` sink existed. `ensure` had the
# name; the spawn refuses it because `parec` could only retry against it.
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

	my $default = "$dir/default";
	open(my $sfh, '>', "$dir/sinks") or die "sinks: $!";
	print {$sfh} "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n";
	close $sfh;
	open(my $dfh, '>', $default) or die "default: $!";
	print {$dfh} "alsa_output.real\n";
	close $dfh;
	write_script("$dir/bin/pactl", <<'PACTL');
my $dir = $ENV{'FAKE_PACTL_DIR'} or exit 9;
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
exit 0;
PACTL
	local $ENV{PATH} = "$dir/bin:$ENV{PATH}";
	local $ENV{FAKE_PACTL_DIR} = $dir;
	local $ENV{JAWNOS_WIREPLUMBER_DIR} = "$dir/wireplumber";

	my $args_log = "$dir/args.log";
	open(my $afh, '>', $args_log) or die "args: $!";
	close $afh;
	local $ENV{JAWNOS_AUDIO_BINARY} = write_script("$dir/no-sink-engine", <<'ENGINE');
use IO::Socket::UNIX;
use Socket qw(SOCK_STREAM);
use JSON::PP ();
my %arg;
for (my $i = 0; $i < @ARGV; $i++) {
	$arg{$ARGV[$i]} = $ARGV[$i + 1] if $ARGV[$i] =~ /^--/;
}
open(my $alog, '>>', $ENV{'FAKE_ENGINE_ARGS'}) or exit 1;
print {$alog} join(' ', @ARGV), "\n";
close $alog;
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
		. "\"system\":\"off\",\"mode\":\"playback\","
		. "\"backend\":\"pipewire\",\"device\":\"default\"}\n";
	close $client;
}
close $listener;
unlink $arg{'--socket'};
ENGINE
	local $ENV{FAKE_ENGINE_ARGS} = $args_log;

	my $sup = start_supervisor(
		args => ['--socket', "$dir/audio.sock", '--system-device', 'jawn_system.monitor'],
		log  => "$dir/supervisor.log",
	);

	my $ran = wait_for(sub { -s $args_log }, 10);
	ok($ran, 'the engine still starts when its requested source is absent');
	unlike(read_text($args_log), qr/--system-device/,
		'but is not given a source whose sink pactl does not list')
		or diag('args: ' . read_text($args_log));
	like(read_text("$dir/supervisor.log"),
		qr/not passing --system-device jawn_system\.monitor/,
		'and the log names the source it refused');
	is(read_text($default), "alsa_output.real\n",
		'while the machine keeps its own output');

	my $code = stop_supervisor($sup);
	is($code, 0, 'the guarded supervisor stops cleanly');
}

# --- a PipeWire playback that lands where it was told ------------------------
# The incident: the engine captured `jawn_system.monitor`, opened the ALSA
# `default` PCM (the PipeWire backend ignores --device), and autoconnected to
# the mix sink. These fixtures hold the graph still so the supervisor's probe
# can be asserted: the env target, a correct graph left alone, a loop cut and
# then ended, and a spawn refused when no safe output is named.
sub write_graph_pactl {
	my ($dir) = @_;
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
	if ($all eq 'list short sources') { print slurp("$dir/sources"); exit 0; }
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
}

sub write_graph_link {
	my ($dir) = @_;
	write_script("$dir/bin/pw-link", <<'PWLINK');
	my $dir = $ENV{'FAKE_PACTL_DIR'} or exit 9;
	open(my $log, '>>', "$dir/pwlink.log") or exit 9;
	print {$log} join(' ', @ARGV), "\n";
	close $log;
	my $cmd = $ARGV[0] // '';
	if ($cmd eq '-l') {
		open(my $fh, '<', "$dir/pwlink.txt") or exit 0;
		local $/;
		print <$fh>;
		close $fh;
	}
	exit 0;
PWLINK
}

sub write_graph_engine {
	my ($dir) = @_;
	return write_script("$dir/pw-engine", <<'ENGINE');
	use IO::Socket::UNIX;
	use Socket qw(SOCK_STREAM);
	use JSON::PP ();
	open(my $alog, '>>', $ENV{'FAKE_ENGINE_ARGS'}) or exit 1;
	print {$alog} join(' ', @ARGV), "\n";
	close $alog;
	open(my $elog, '>>', $ENV{'FAKE_ENGINE_ENV'}) or exit 1;
	print {$elog} 'PIPEWIRE_NODE=' . ($ENV{'PIPEWIRE_NODE'} // '') . "\n";
	close $elog;
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
			open(my $q, '>>', $ENV{'FAKE_ENGINE_QUIT'}) or exit 1;
			print {$q} "quit\n";
			close $q;
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
}

# The hand-run path from the incident, done correctly: --device names the output
# the mix replaced, so the target reaches pipewire-alsa and the good graph is
# left alone.
{
	my $dir  = tempdir(CLEANUP => 1);
	my $home = "$dir/home";
	make_path("$home/.president", "$dir/bin");
	local $ENV{HOME} = $home;
	local $ENV{PATH} = "$dir/bin:$ENV{PATH}";
	local $ENV{FAKE_PACTL_DIR} = $dir;
	delete $ENV{JAWNOS_AUDIO_SYSTEM_DEVICE};

	# A managed plan: the capture switch is on, so --system-device is the
	# person's explicit source and the supervisor must name the play-out too.
	my $plan = "$dir/audio-plan.json";
	open(my $pfh, '>', $plan) or die "plan: $!";
	print {$pfh} '{"manage":1,"plan":{"sources":[],"buses":[],'
		. '"sinks":[{"id":"out","kind":"interface"}],"routes":[]},'
		. '"backend":"pipewire","device":"default"}';
	close $pfh;
	local $ENV{JAWNOS_AUDIO_PLAN} = $plan;

	open(my $sfh, '>', "$dir/sinks") or die "sinks: $!";
	print {$sfh} "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n"
		. "1\tjawn_system\tmodule-null-sink\ts16le 2ch 48000Hz\n";
	close $sfh;
	open(my $dfh, '>', "$dir/default") or die "default: $!";
	print {$dfh} "jawn_system\n";
	close $dfh;
	open(my $lfh, '>', "$dir/pwlink.txt") or die "links: $!";
	print {$lfh} "jawn_system:monitor_FL\n  |-> parec:input_FL\n\n"
		. "alsa_playback.jawn-audio:output_FL\n"
		. "  |-> alsa_output.real:playback_FL\n";
	close $lfh;
	write_graph_pactl($dir);
	write_graph_link($dir);

	local $ENV{JAWNOS_AUDIO_BINARY} = write_graph_engine($dir);
	local $ENV{FAKE_ENGINE_ARGS} = "$dir/args.log";
	local $ENV{FAKE_ENGINE_ENV}  = "$dir/env.log";
	local $ENV{FAKE_ENGINE_QUIT} = "$dir/quit.log";
	local $ENV{FAKE_ENGINE_SYSTEM} = 'capturing';

	my $sup = start_supervisor(
		args => [
			'--socket', "$dir/audio.sock",
			'--backend', 'pipewire',
			'--device', 'alsa_output.real',
			'--system-device', 'jawn_system.monitor',
		],
		log => "$dir/supervisor.log",
	);

	my $ran = wait_for(sub { -s "$dir/env.log" }, 10);
	ok($ran, 'a hand-run pipewire engine starts with a named output')
		or diag('log: ' . read_text("$dir/supervisor.log"));
	like(read_text("$dir/env.log"), qr/^PIPEWIRE_NODE=alsa_output\.real$/m,
		'the replaced output reaches pipewire-alsa through PIPEWIRE_NODE');
	like(read_text("$dir/args.log"), qr/--system-device jawn_system\.monitor/,
		'and the engine still captures the mix');

	my $checked = wait_for(sub {
		read_text("$dir/pwlink.log") =~ /-l/;
	}, 10);
	ok($checked, 'the supervisor checks the live graph');
	sleep 0.4;
	unlike(read_text("$dir/pwlink.log"), qr/^-d\b/m,
		'a correct graph is not cut');
	ok(!-e "$dir/quit.log", 'and the engine is left running')
		or diag('quit: ' . read_text("$dir/quit.log"));

	my $code = stop_supervisor($sup);
	is($code, 0, 'the supervised engine stops cleanly');
}

# The loop itself: the engine's output is linked into the sink it captures. The
# probe cuts the link; when it re-forms the child is ended rather than left to
# oscillate.
{
	my $dir  = tempdir(CLEANUP => 1);
	my $home = "$dir/home";
	make_path("$home/.president", "$dir/bin");
	local $ENV{HOME} = $home;
	local $ENV{PATH} = "$dir/bin:$ENV{PATH}";
	local $ENV{FAKE_PACTL_DIR} = $dir;
	delete $ENV{JAWNOS_AUDIO_SYSTEM_DEVICE};

	my $plan = "$dir/audio-plan.json";
	open(my $pfh, '>', $plan) or die "plan: $!";
	print {$pfh} '{"manage":1,"plan":{"sources":[],"buses":[],'
		. '"sinks":[{"id":"out","kind":"interface"}],"routes":[]},'
		. '"backend":"pipewire","device":"default"}';
	close $pfh;
	local $ENV{JAWNOS_AUDIO_PLAN} = $plan;

	open(my $sfh, '>', "$dir/sinks") or die "sinks: $!";
	print {$sfh} "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n";
	close $sfh;
	open(my $dfh, '>', "$dir/default") or die "default: $!";
	print {$dfh} "alsa_output.real\n";
	close $dfh;
	open(my $lfh, '>', "$dir/pwlink.txt") or die "links: $!";
	print {$lfh} "jawn_system:monitor_FL\n  |-> parec:input_FL\n\n"
		. "alsa_playback.jawn-audio:output_FL\n"
		. "  |-> jawn_system:playback_FL\n";
	close $lfh;
	write_graph_pactl($dir);
	write_graph_link($dir);

	local $ENV{JAWNOS_AUDIO_BINARY} = write_graph_engine($dir);
	local $ENV{FAKE_ENGINE_ARGS} = "$dir/args.log";
	local $ENV{FAKE_ENGINE_ENV}  = "$dir/env.log";
	local $ENV{FAKE_ENGINE_QUIT} = "$dir/quit.log";
	local $ENV{FAKE_ENGINE_SYSTEM} = 'capturing';

	my $sup = start_supervisor(
		args => ['--socket', "$dir/audio.sock"],
		log  => "$dir/supervisor.log",
	);

	my $cut = wait_for(sub {
		read_text("$dir/pwlink.log") =~ /^-d alsa_playback\.jawn-audio:output_FL jawn_system:playback_FL$/m;
	}, 15);
	ok($cut, 'the engine output is cut away from the sink it captures')
		or diag('log: ' . read_text("$dir/supervisor.log"));
	like(read_text("$dir/supervisor.log"),
		qr/engine's output .* is linked into jawn_system:playback_FL/s,
		'and the log names the loop');

	my $ended = wait_for(sub { -s "$dir/quit.log" }, 15);
	ok($ended, 'a loop that re-forms ends the engine')
		or diag('log: ' . read_text("$dir/supervisor.log"));

	my $code = stop_supervisor($sup);
	is($code, 0, 'the supervisor still stops cleanly');
	# The supervisor's stdout is buffered until it exits (or shells out), so read
	# the re-form line after the clean stop rather than the moment `quit` lands.
	like(read_text("$dir/supervisor.log"), qr/loop into jawn_system re-formed/,
		'and says the loop came back');
}

# A target that cannot be resolved is refused before a child starts. `default`
# after the switch is the mix sink, so an engine given it would loop.
{
	my $dir  = tempdir(CLEANUP => 1);
	my $home = "$dir/home";
	make_path("$home/.president", "$dir/bin");
	local $ENV{HOME} = $home;
	local $ENV{PATH} = "$dir/bin:$ENV{PATH}";
	local $ENV{FAKE_PACTL_DIR} = $dir;
	delete $ENV{JAWNOS_AUDIO_SYSTEM_DEVICE};

	my $plan = "$dir/audio-plan.json";
	open(my $pfh, '>', $plan) or die "plan: $!";
	print {$pfh} '{"manage":1,"plan":{"sources":[],"buses":[],'
		. '"sinks":[{"id":"out","kind":"interface"}],"routes":[]},'
		. '"backend":"pipewire","device":"default"}';
	close $pfh;
	local $ENV{JAWNOS_AUDIO_PLAN} = $plan;

	open(my $sfh, '>', "$dir/sinks") or die "sinks: $!";
	print {$sfh} "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n"
		. "1\tjawn_system\tmodule-null-sink\ts16le 2ch 48000Hz\n";
	close $sfh;
	open(my $dfh, '>', "$dir/default") or die "default: $!";
	print {$dfh} "jawn_system\n";
	close $dfh;
	write_graph_pactl($dir);
	write_graph_link($dir);

	local $ENV{JAWNOS_AUDIO_BINARY} = write_graph_engine($dir);
	local $ENV{FAKE_ENGINE_ARGS} = "$dir/args.log";
	local $ENV{FAKE_ENGINE_ENV}  = "$dir/env.log";
	local $ENV{FAKE_ENGINE_QUIT} = "$dir/quit.log";

	my $sup = start_supervisor(
		args => [
			'--socket', "$dir/audio.sock",
			'--backend', 'pipewire',
			'--device', 'default',
			'--system-device', 'jawn_system.monitor',
		],
		log => "$dir/supervisor.log",
	);

	my $refused = wait_for(sub {
		read_text("$dir/supervisor.log") =~ /not starting an engine that would play into its own capture/;
	}, 10);
	ok($refused, 'a default target beside the captured sink is refused')
		or diag('log: ' . read_text("$dir/supervisor.log"));
	ok(!-s "$dir/args.log", 'and no engine was started')
		or diag('args: ' . read_text("$dir/args.log"));

	my $code = stop_supervisor($sup);
	is($code, 0, 'the refusing supervisor stops cleanly');
}

# --- the engine's block follows the plan's mode -------------------------------
# A duplex plan is capturing a routed input, which is the armed state a
# monitored take needs the studio block for; a playback plan cannot hear 5 ms,
# so it runs the relaxed one and wakes a quarter as often.
{
	my $playback = '{"manage":0,"plan":{"sources":[],"buses":[],"sinks":[],"routes":[]}}';
	my $duplex = '{"manage":0,"plan":{"sources":[{"id":"gtr","kind":"input","channel":0}],'
		. '"buses":[{"id":"house"}],"sinks":[],"routes":[{"from":"gtr","to":"house"}]}}';

	my ( $args, $status ) = block_for_plan($playback);
	like($args, qr/--period 256 --buffer 1024/,
		'a playback-only plan runs the relaxed block')
		or diag("args: $args");
	is($status->{'period'}, 256, 'and the status reports the relaxed period') if $status;
	is($status->{'buffer'}, 1024, 'with the relaxed buffer') if $status;

	my ($duplex_args) = block_for_plan($duplex);
	like($duplex_args, qr/--period 64 --buffer 256/,
		'a duplex plan keeps the studio block') or diag("args: $duplex_args");

	my ($pinned_args) = block_for_plan( $playback, period => 128, buffer => 512 );
	like($pinned_args, qr/--period 128 --buffer 512/,
		'JAWNOS_AUDIO_PERIOD and JAWNOS_AUDIO_BUFFER beat the plan')
		or diag("args: $pinned_args");

	my ($one_knob_args) = block_for_plan( $playback, buffer => 512 );
	like($one_knob_args, qr/--period 64 --buffer 512/,
		'one pinned knob keeps the studio period, so the pair stays valid')
		or diag("args: $one_knob_args");

	my ($bare_args) = block_for_plan(undef);
	like($bare_args, qr/--period 64 --buffer 256/,
		'with no saved plan at all the studio pair stays')
		or diag("args: $bare_args");
}

# --- a plan that flips mode asks the engine to restart on the new block ------
# The pair is chosen at spawn, so without this check a plan that turned duplex
# kept the relaxed block until something else happened to restart the engine.
{
	my $dir  = tempdir(CLEANUP => 1);
	my $home = "$dir/home";
	make_path("$home/.president");
	local $ENV{HOME} = $home;
	my $plan = "$dir/audio-plan.json";
	open(my $pfh, '>', $plan) or die "plan: $!";
	print {$pfh} '{"manage":0,"plan":{"sources":[{"id":"gtr","kind":"input","channel":0}],'
		. '"buses":[{"id":"house"}],"sinks":[],"routes":[{"from":"gtr","to":"house"}]}}';
	close $pfh;
	local $ENV{JAWNOS_AUDIO_PLAN} = $plan;
	local $ENV{AUDIO_TEST_QUIT}   = "$dir/quit.log";
	# An engine that reports the relaxed block the old plan would have chosen:
	# the supervisor must notice the duplex plan asks for the studio one.
	local $ENV{JAWNOS_AUDIO_BINARY} = write_script("$dir/relaxed-engine", <<'ENGINE');
use IO::Socket::UNIX;
use Socket qw(SOCK_STREAM);
use JSON::PP ();
my %arg;
for (my $i = 0; $i < @ARGV; $i++) { $arg{$ARGV[$i]} = $ARGV[$i + 1] if $ARGV[$i] =~ /^--/; }
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
		open(my $q, '>>', $ENV{AUDIO_TEST_QUIT}) or exit 1;
		print {$q} join(' ', @ARGV), "\n";
		close $q;
		close $client;
		last;
	}
	print {$client} "{\"ok\":true,\"take\":0,\"state\":\"idle\",\"backend\":\"null\","
		. "\"device\":\"hw:9,9\",\"period\":256,\"buffer\":1024}\n";
	close $client;
}
close $listener;
unlink $arg{'--socket'};
ENGINE

	my $sup = start_supervisor(
		args => ['--backend', 'null', '--device', 'hw:9,9', '--socket', "$dir/audio.sock"],
		log  => "$dir/supervisor.log",
	);
	my $asked = wait_for(sub { -s "$ENV{AUDIO_TEST_QUIT}" }, 15);
	ok($asked, 'the engine on the relaxed block is asked to restart when the plan turns duplex')
		or diag('supervisor: ' . (-s "$dir/supervisor.log" ? read_text("$dir/supervisor.log") : '(none)'));
	# The supervisor's stdout is block-buffered when it is redirected, so the note
	# is only guaranteed on disk once it has stopped and flushed.
	my $code = stop_supervisor($sup);
	is($code, 0, 'the flipping supervisor stops cleanly');
	like(read_text("$dir/supervisor.log"),
		qr/the engine runs 256\/1024; the saved plan asks for 64\/256/,
		'and the log names the pair the plan asks for');
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

# An orphan the socket cannot reach is taken down by the same ladder as our own
# child, and only after its identity is read again; a spawn it refuses is a
# retry with a reason, never the end of the supervisor.
like($audio_src, qr/sub terminate_orphan[\s\S]*?kill 'TERM', \$pid[\s\S]*?kill 'KILL', \$pid/,
	'an identified orphan gets TERM, then KILL');
like($audio_src, qr/sub still_orphan[\s\S]*?runs_binary[\s\S]*?serves_socket/,
	'after its identity is read again');
like($audio_src,
	qr/\$last_exit = \$spawn_refused[\s\S]*?write_status\(\);[\s\S]*?\$next_start = time \+ \$MISSING_RETRY/,
	'a refused spawn is recorded and retried, not an exit');

done_testing();
