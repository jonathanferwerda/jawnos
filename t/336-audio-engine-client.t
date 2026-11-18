# tests-for: lib/JawnOS/Audio/Engine.pm lib/JawnOS/Controller/manager_misc9.pm lib/JawnOS/Routes/manager_misc9.pm
# covers:    the engine's line protocol client (one JSON object per line, a
#            timeout that is reported rather than hung, a missing engine that is
#            an answer) and Studio's take route (start/status/stop, a server-
#            chosen path under misc/rec_location, and no path from the request).

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path getcwd);
use IO::Socket::UNIX;
use Mojo::JSON qw(decode_json encode_json);
use JSON::PP ();
use POSIX qw(_exit);
use Time::HiRes qw(time);

# FindBin, not RepoSource or Probe: the pre-push guard compiles this file in a
# scratch directory, and anything that only exists relative to t/ would make
# the guard refuse the push rather than judge the code.
my $root = abs_path("$FindBin::Bin/..");
require JawnOS::Audio::Engine;

# --- the socket and the binary ------------------------------------------------
{
	local $ENV{JAWNOS_AUDIO_SOCKET} = '/tmp/engine-test.sock';
	is(JawnOS::Audio::Engine::audio_engine_socket(), '/tmp/engine-test.sock',
		'the environment names the socket first');

	delete $ENV{JAWNOS_AUDIO_SOCKET};
	local $ENV{HOME} = '/tmp/engine-test-home';
	is(JawnOS::Audio::Engine::audio_engine_socket(), '/tmp/engine-test-home/.president/audio.sock',
		'otherwise it is the engine default under the home directory');
}

is(JawnOS::Audio::Engine::audio_engine_binary(), "$root/perl/audio/jawn-audio",
	'the staged engine is found under the tree, not under the cwd');

# --- a mock engine ------------------------------------------------------------
# One line in, one line out, one client at a time, exactly the engine's shape.
# The fixture records every request before it replies, so asserting on the log
# after a wrapper returns proves what went over the socket.
my @server_pids;
END { kill 'KILL', grep { defined } @server_pids }

sub start_mock {
	my (%opt) = @_;
	my $dir  = tempdir(CLEANUP => 1);
	my $path = "$dir/audio.sock";
	my $log  = "$dir/commands.log";
	open(my $touch, '>', $log) or die "touch $log: $!";
	close $touch;

	my $pid = fork();
	die "fork: $!" unless defined $pid;
	if ($pid == 0) {
		my $listener = IO::Socket::UNIX->new(
			Type    => SOCK_STREAM,
			Local   => $path,
			Listen  => 5,
		) or _exit(1);

		while (1) {
			my $client = $listener->accept or next;
			my $line   = <$client>;
			# `available` connects and closes without a request: that is a liveness
			# probe, not a command.
			unless (defined $line) { close $client; next }
			chomp $line;
			my $request = eval { decode_json($line) } || {};

			open(my $fh, '>>', $log) or _exit(1);
			print {$fh} encode_json($request) . "\n";
			close $fh;

			# The timeout fixture accepts and then says nothing at all.
			if ($opt{'silent'}) { sleep 30; _exit(0) }

			my $cmd   = $request->{'cmd'} // '';
			my $reply = $opt{'replies'}{$cmd} // '{"ok":false,"error":"unknown command"}';
			print {$client} $reply . "\n";
			close $client;
			last if $cmd eq 'quit';
		}
		close $listener;
		_exit(0);
	}

	push @server_pids, $pid;
	my $deadline = time + 3;
	until (-S $path) {
		last if time > $deadline;
		select undef, undef, undef, 0.01;
	}
	die "mock engine did not listen on $path\n" unless -S $path;
	return ($path, $log, $pid);
}

sub logged_requests {
	my ($log) = @_;
	my $text = -e $log ? read_file($log) : '';
	return map { eval { decode_json($_) } } grep { length } split /\n/, $text;
}

my %reply = (
	record => '{"ok":true,"take":1,"state":"recording","start_sample":96000}',
	status => '{"ok":true,"take":1,"state":"recording","path":"/tmp/take.wav","frames":4800,"dropped":0,"start_sample":96000,"xruns":2,"error":""}',
	stop   => '{"ok":true,"take":1,"state":"done","path":"/tmp/take.wav","frames":48000,"dropped":0,"start_sample":96000,"xruns":2,"error":""}',
	quit   => '{"ok":true}',
);

{
	my ($path, $log, $pid) = start_mock(replies => \%reply);
	local $ENV{JAWNOS_AUDIO_SOCKET} = $path;

	ok(JawnOS::Audio::Engine::audio_engine_available(),
		'a listening socket is an available engine');

	my $out   = '/tmp/studio-take-test.wav';
	my $start = JawnOS::Audio::Engine::audio_engine_record($out, 10, 96000);
	ok($start->{'ok'}, 'record returns the decoded reply');
	is($start->{'take'}, 1, 'with the take number');
	is($start->{'state'}, 'recording', 'and the state');
	is($start->{'start_sample'}, 96000, 'and the start sample');

	my $status = JawnOS::Audio::Engine::audio_engine_status();
	is($status->{'state'}, 'recording', 'status returns the decoded reply');
	is($status->{'frames'}, 4800, 'and every field is relayed');
	is($status->{'xruns'}, 2, 'including the counters');

	my $stop = JawnOS::Audio::Engine::audio_engine_stop();
	is($stop->{'state'}, 'done', 'stop returns the final status');

	my $quit = JawnOS::Audio::Engine::audio_engine_quit();
	ok($quit->{'ok'}, 'quit is acknowledged');

	my @seen = logged_requests($log);
	is_deeply([ map { $_->{'cmd'} } @seen ], [qw(record status stop quit)],
		'each wrapper sends its own cmd, in order');
	is($seen[0]{'out'}, $out, 'record sends the output path');
	is($seen[0]{'seconds'}, 10, 'and the length');
	is($seen[0]{'start_at'}, 96000, 'and the start sample');

	waitpid($pid, 0);
	$server_pids[-1] = undef;
}

# --- a missing engine is a sentence, not a die -------------------------------
{
	my $dir = tempdir(CLEANUP => 1);
	local $ENV{JAWNOS_AUDIO_SOCKET} = "$dir/not-here.sock";

	ok(!JawnOS::Audio::Engine::audio_engine_available(), 'no socket means not available');
	my $answer = eval { JawnOS::Audio::Engine::audio_engine_status() };
	is($@, '', 'a missing engine does not die');
	is($answer->{'ok'}, 0, 'it answers ok false');
	is($answer->{'error'}, 'the audio engine is not running on this machine',
		'with the sentence the route shows');
}

# --- a timeout is reported, not hung ----------------------------------------
{
	my ($path, undef, $pid) = start_mock(silent => 1);
	local $ENV{JAWNOS_AUDIO_SOCKET} = $path;

	my $started = time;
	my $answer  = eval { JawnOS::Audio::Engine::audio_engine_command({ cmd => 'status' }, 1) };
	my $elapsed = time - $started;

	is($@, '', 'a silent engine does not die');
	is($answer->{'ok'}, 0, 'it answers ok false');
	like($answer->{'error'}, qr/did not answer in time/, 'and names the timeout');
	cmp_ok($elapsed, '<', 4, 'the read is bounded by the alarm');

	kill 'KILL', $pid;
	waitpid($pid, 0);
	$server_pids[-1] = undef;
}

# --- a sandbox database for the route --------------------------------------
# The route reads misc/rec_location through subs::setting_grabber, so the test
# needs the app's own settings table. This is the same shape as the shared
# harness (a throwaway tree with the source symlinked and its own config), kept
# here so the file still compiles with only FindBin and core modules.
sub sandbox_database {
	my $dir = tempdir(CLEANUP => 1);
	symlink("$root/perl", "$dir/perl") or die "symlink perl: $!";
	symlink("$root/lib",  "$dir/lib")  or die "symlink lib: $!";
	make_path("$dir/database", "$dir/.president");
	for my $seed (qw(initial.enc schema.sql)) {
		next unless -e "$root/database/$seed";
		symlink("$root/database/$seed", "$dir/database/$seed")
			or die "symlink database/$seed: $!";
	}
	open(my $fh, '>', "$dir/config.json") or die "config.json: $!";
	print {$fh} JSON::PP->new->canonical->encode({
		device       => 'computer',
		language     => 'en',
		environment  => 'test',
		logfile      => "$dir/manager.log",
		port         => '3000',
		working_port => '3001',
		ws_port      => '3001',
	});
	close $fh;

	my $cwd = getcwd();
	chdir $dir or die "chdir $dir: $!";
	require './perl/subroutines.pl';
	chdir $cwd or die "chdir $cwd: $!";
	{
		no warnings 'once';
		$subs::install_dir = $dir;
	}
	return $dir;
}

my $sandbox = sandbox_database();
require "$root/lib/JawnOS/Controller/manager_misc9.pm";

ok(Manager->can('action_44023'), 'the controller defines action_44023');

# --- the route row is plain text, the t/58 shape ----------------------------
my $route_text = join '', map { read_file($_) } sort glob("$root/lib/JawnOS/Routes/*.pm");
like(
	$route_text,
	qr/\[\s*44023\s*,\s*'post'\s*,\s*'\/manager\/studio\/take'\s*,\s*'action_44023'\s*\]/,
	'POST /manager/studio/take is registered with its action'
);

# --- a fake controller -------------------------------------------------------
package FakeStudioTakeController;
sub new    { return bless { params => $_[1] }, $_[0] }
sub param  { return $_[0]->{'params'}{$_[1]} }
sub render {
	my ($self, @args) = @_;
	while (@args) {
		my $name  = shift @args;
		my $value = shift @args;
		$self->{$name} = $value;
	}
	return;
}
package main;

sub run_take {
	my (%params) = @_;
	my $fake = FakeStudioTakeController->new({ action => 'start', %params });
	Manager::action_44023($fake);
	$fake->{'status'} = 200 unless defined $fake->{'status'};
	return $fake;
}

# --- the take path is the server's -----------------------------------------
{
	my $rec_dir = tempdir(CLEANUP => 1);
	&subs::setting_setter({
		app => 'misc', setting => 'rec_location', value => $rec_dir,
		device => &subs::device_setter(),
	});

	my (@calls, @available);
	local *JawnOS::Audio::Engine::audio_engine_available = sub { push @available, 1; return 1 };
	local *JawnOS::Audio::Engine::audio_engine_record = sub {
		push @calls, [@_];
		return { ok => 1, take => 1, state => 'recording', start_sample => $_[2] };
	};

	my $fake = run_take(seconds => '0', start_at => '96000', path => '/tmp/from-the-browser.wav');
	is($fake->{'status'}, 200, 'a started take is 200');
	ok($fake->{'json'}{'ok'}, 'the engine reply is relayed');
	is(scalar @calls, 1, 'record was called once');
	my ($out, $seconds, $start_at) = @{ $calls[0] };
	is($seconds, 1, 'a zero length is clamped up to one second');
	is($start_at, 96000, 'and the start sample is passed through');
	is($fake->{'json'}{'path'}, $out, 'the reply names the file the engine was given');
	like($out, qr{\A\Q$rec_dir\E/studio-take-\d+-\d+\.wav\z},
		'the file is under the configured recording folder');
	unlike($out, qr/from-the-browser/, 'a path parameter never becomes the output path');
	is(JawnOS::Audio::Engine::audio_engine_binary(), "$root/perl/audio/jawn-audio",
		'and the client still names the staged binary');

	my $clamped = run_take(seconds => '99999', start_at => '-4');
	is($clamped->{'status'}, 200, 'an oversized length is accepted');
	is($calls[-1][1], 3600, 'and clamped to an hour');
	is($calls[-1][2], 0, 'a negative start sample becomes zero');

	my $default = run_take();
	is($default->{'status'}, 200, 'a take with no length is accepted');
	is($calls[-1][1], 10, 'and defaults to ten seconds');

	my $controller = read_file("$root/lib/JawnOS/Controller/manager_misc9.pm");
	unlike($controller, qr/param\(\s*['"]path['"]\s*\)/, 'the controller never reads a path parameter');
}

# --- no recording folder is a clear refusal ---------------------------------
{
	&subs::setting_setter({
		app => 'misc', setting => 'rec_location', value => '',
		device => &subs::device_setter(),
	});
	my @calls;
	local *JawnOS::Audio::Engine::audio_engine_available = sub { return 1 };
	local *JawnOS::Audio::Engine::audio_engine_record = sub { push @calls, [@_]; return { ok => 1 } };

	my $fake = run_take();
	is($fake->{'status'}, 503, 'an unset folder is refused as a server condition');
	ok(!$fake->{'json'}{'ok'}, 'with ok false');
	like($fake->{'json'}{'error'}, qr/no recording folder/, 'and an error a person can act on');
	is(scalar @calls, 0, 'no take is started');
}

# --- a missing engine is 503, but status and stop still relay ---------------
{
	my $rec_dir = tempdir(CLEANUP => 1);
	&subs::setting_setter({
		app => 'misc', setting => 'rec_location', value => $rec_dir,
		device => &subs::device_setter(),
	});
	local *JawnOS::Audio::Engine::audio_engine_available = sub { return 0 };
	my @calls;
	local *JawnOS::Audio::Engine::audio_engine_record = sub { push @calls, [@_]; return { ok => 1 } };

	my $fake = run_take();
	is($fake->{'status'}, 503, 'an absent engine refuses a start');
	is($fake->{'json'}{'error'}, 'the audio engine is not running on this machine',
		'with the promised sentence');
	is(scalar @calls, 0, 'and no command is sent');

	# The liveness probe can race an engine that exits; the command's own answer
	# must still be the same 503 rather than a 200 carrying a server fault.
	local *JawnOS::Audio::Engine::audio_engine_available = sub { return 1 };
	local *JawnOS::Audio::Engine::audio_engine_record = sub {
		return { ok => 0, error => 'the audio engine is not running on this machine' };
	};
	my $raced = run_take();
	is($raced->{'status'}, 503, 'an engine that vanishes between probe and record is still 503');
	is($raced->{'json'}{'error'}, 'the audio engine is not running on this machine',
		'and keeps the sentence');

	local *JawnOS::Audio::Engine::audio_engine_status = sub {
		return { ok => 1, take => 1, state => 'recording', path => '/tmp/x.wav' };
	};
	my $status = run_take(action => 'status');
	is($status->{'status'}, 200, 'status is always 200');
	is($status->{'json'}{'state'}, 'recording', 'and relays the engine object');
	is($status->{'json'}{'path'}, '/tmp/x.wav', 'field for field');

	local *JawnOS::Audio::Engine::audio_engine_stop = sub {
		return { ok => 1, take => 1, state => 'done', frames => 48000 };
	};
	my $stop = run_take(action => 'stop');
	is($stop->{'status'}, 200, 'stop is 200');
	is($stop->{'json'}{'state'}, 'done', 'and relays the final status');
}

# --- a malformed action is 400 ---------------------------------------------
{
	my $fake = run_take(action => 'dance');
	is($fake->{'status'}, 400, 'an unknown action is a 400');
	ok(!$fake->{'json'}{'ok'}, 'with ok false');
	like($fake->{'json'}{'error'}, qr/choose an action: start, stop or status/,
		'and names the three choices');

	my $missing = run_take(action => undef);
	is($missing->{'status'}, 400, 'a missing action is a 400 too');
}

done_testing();
