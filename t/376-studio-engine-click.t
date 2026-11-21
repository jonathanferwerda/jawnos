# tests-for: lib/JawnOS/Controller/manager_misc9.pm lib/JawnOS/Audio/Engine.pm public/js/manager/studio.js public/js/manager/studio/01_transport.js public/js/manager/studio/06_controls.js engine/src/socket.rs engine/src/playback.rs
# covers:    The engine take's own metronome click - the record wire carries an
#            optional `click` object ({bpm,beats_per_bar,gain}), the start route
#            validates it before the engine is dialled, and the page sends it
#            only while the metronome is on. The engine builds the click on the
#            monitor output (never the take), a click-only monitor is a legal
#            playback, and the engine-take flag suppresses the browser click so
#            the take hears one click on one sample clock.

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

my $root = abs_path("$FindBin::Bin/..");

# --- a mock engine ------------------------------------------------------------
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
			Type   => SOCK_STREAM,
			Local  => $path,
			Listen => 5,
		) or _exit(1);

		while (1) {
			my $client = $listener->accept or next;
			my $line   = <$client>;
			unless (defined $line) { close $client; next }
			chomp $line;
			my $request = eval { decode_json($line) } || {};

			open(my $fh, '>>', $log) or _exit(1);
			print {$fh} encode_json($request) . "\n";
			close $fh;

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

sub last_line {
	my ($log) = @_;
	my $text = -e $log ? read_file($log) : '';
	my @lines = grep { length } split /\n/, $text;
	return $lines[-1] // '';
}

sub request_count {
	my ($log) = @_;
	my @rows = logged_requests($log);
	return scalar @rows;
}

# --- the controller's sandbox -------------------------------------------------
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
require JawnOS::Audio::Engine;

# --- a fake controller -------------------------------------------------------
package FakeStudioTakeController;
sub new   { return bless { params => $_[1] }, $_[0] }
sub param { return $_[0]->{'params'}{$_[1]} }
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
	$params{'action'} = 'start' unless exists $params{'action'};
	my $fake = FakeStudioTakeController->new({ %params });
	Manager::action_44023($fake);
	$fake->{'status'} = 200 unless defined $fake->{'status'};
	return $fake;
}

# --- the record wire carries the click ---------------------------------------
{
	my ($path, $log) = start_mock(replies => {
		record => '{"ok":true,"take":1,"state":"recording"}',
	});
	local $ENV{JAWNOS_AUDIO_SOCKET} = $path;

	my $answer = JawnOS::Audio::Engine::audio_engine_record(
		'/tmp/take.wav', 5, 0,
		{ click => { bpm => 120, beats_per_bar => 4, gain => 0.5 } },
	);
	ok($answer->{'ok'}, 'a take with a click is accepted');
	my $request = (logged_requests($log))[-1];
	is_deeply($request->{'click'},
		{ bpm => 120, beats_per_bar => 4, gain => 0.5 },
		'the click travels as one object');
	like(last_line($log), qr/"click":\{.*"bpm":120/,
		'and is a nested JSON object on the wire');

	JawnOS::Audio::Engine::audio_engine_record('/tmp/take.wav', 5, 0);
	my $plain = (logged_requests($log))[-1];
	ok(!exists $plain->{'click'}, 'a take without a click sends none');
	unlike(last_line($log), qr/"click"/, 'the word does not appear on the plain take');
}

# --- the start route validates the click before dialling the engine ----------
{
	my $rec_dir = tempdir(CLEANUP => 1);
	&subs::setting_setter({
		app => 'misc', setting => 'rec_location', value => $rec_dir,
		device => &subs::device_setter(),
	});

	my @calls;
	local *JawnOS::Audio::Engine::audio_engine_available = sub { return 1 };
	local *JawnOS::Audio::Engine::audio_engine_record = sub {
		push @calls, [@_];
		return { ok => 1, take => 1, state => 'recording' };
	};

	my $fake = run_take(
		seconds => '5',
		click_json => encode_json({ bpm => 120, beats_per_bar => 4, gain => 0.5 }),
	);
	is($fake->{'status'}, 200, 'a click on a take is accepted');
	my $extra = $calls[-1][3];
	is_deeply($extra->{'click'},
		{ bpm => 120, beats_per_bar => 4, gain => 0.5 },
		'and reaches audio_engine_record as numbers');

	# The signature's numerator is the whole contract; a missing gain is half.
	my $defaulted = run_take(
		seconds => '5',
		click_json => encode_json({ bpm => 96.5, beats_per_bar => 7 }),
	);
	is($defaulted->{'status'}, 200, 'a fractional tempo and an odd bar are accepted');
	is($calls[-1][3]{'click'}{'bpm'}, 96.5, 'the tempo is not rounded');
	is($calls[-1][3]{'click'}{'beats_per_bar'}, 7, 'the bar keeps its numerator');
	is($calls[-1][3]{'click'}{'gain'}, 0.5, 'a missing gain defaults to half');

	# Absent or empty: no click on the record plan.
	for my $off (undef, '') {
		my $bare = run_take(
			seconds => '5',
			(defined $off ? (click_json => $off) : ()),
		);
		is($bare->{'status'}, 200, 'a take with no click is accepted');
		ok(!exists $calls[-1][3]{'click'}, 'and sends no click in the plan');
	}

	my $before = scalar @calls;
	my @bad = (
		[ 'not json',                    qr/one JSON object/ ],
		[ encode_json([]),               qr/one JSON object/ ],
		[ encode_json({ beats_per_bar => 4 }), qr/finite number greater than zero/ ],
		[ encode_json({ bpm => 0, beats_per_bar => 4 }), qr/greater than zero/ ],
		[ encode_json({ bpm => 120, beats_per_bar => 0 }), qr/from 1 to 32/ ],
		[ encode_json({ bpm => 120, beats_per_bar => 33 }), qr/from 1 to 32/ ],
		[ encode_json({ bpm => 120, beats_per_bar => 2.5 }), qr/from 1 to 32/ ],
		[ encode_json({ bpm => 120, beats_per_bar => 4, gain => 1.5 }), qr/from 0 to 1/ ],
		[ encode_json({ bpm => 120, beats_per_bar => 4, gain => -0.1 }), qr/from 0 to 1/ ],
	);
	for my $case (@bad) {
		my ($json, $error) = @$case;
		my $refused = run_take(seconds => '5', click_json => $json);
		is($refused->{'status'}, 400, "a malformed click is a 400: $json");
		like($refused->{'json'}{'error'}, $error, 'and names the rule it broke');
	}
	is(scalar @calls, $before, 'a malformed click never reaches the engine');
}

# --- the page sends the click only while the metronome is on -----------------
my $studio    = read_file("$root/public/js/manager/studio.js");
my $transport = read_file("$root/public/js/manager/studio/01_transport.js");
my $controls  = read_file("$root/public/js/manager/studio/06_controls.js");

sub body {
	my ($src, $name) = @_;
	my ($b) = $src =~ /^(?:async )?function \Q$name\E\([^)]*\) \{(.*?)^\}/ms;
	return defined $b ? $b : '';
}

my $click = body($studio, 'studioEngineClick');
ok(length $click, 'the engine click builder is one function');
like($click, qr/mixer\['time'\]\['metronome'\] != 'yes'/, 'it only builds a click with the metronome on');
like($click, qr/mixer\['time'\]\['bpm'\]/, 'the tempo comes from the transport');
like($click, qr/mixer\['time'\]\['sig'\]/, 'the signature comes from the transport');
like($click, qr/\.knob_control\[channel="metronome"\]\[control="volume"\]/,
	'and the metronome volume knob is the trim');
like($click, qr/volume \/ 100/, 'the knob 0..100 becomes the engine 0..1');
like($click, qr/Math\.max\(0, Math\.min\(1,/, 'the trim is clamped to the engine range');

my $start = body($studio, 'studioEngineStart');
ok(length $start, 'the engine take start is one function');
like($start, qr/var click = studioEngineClick\(\);/, 'the start builds the click');
like($start, qr/click_json: click \? JSON\.stringify\(click\) : ''/,
	'and sends it only when the builder returned one');
like($start, qr/mixer\['time'\]\['engine_take'\] = true/,
	'a started take marks the engine as the click owner');
like($start, qr/studioFlushClicks\(\)/,
	'and drops the clicks already placed in the browser lookahead');
like($start, qr/var wasRecording = studioEngineRecording;/,
	'a refused start remembers whether an earlier take still owns the click');
like($start, qr/mixer\['time'\]\['engine_take'\] = wasRecording/,
	'and keeps the flag for a take that is still recording');

my $status = body($studio, 'studioEngineStatus');
like($status, qr/mixer\['time'\]\['engine_take'\] = studioEngineRecording/,
	'a completed take hands the click back');
like($status, qr/mixer\['time'\]\['engine_take'\] = false/,
	'and a dead engine socket clears the flag too');

my $failed = body($studio, 'studioEngineFailed');
like($failed, qr/mixer\['time'\]\['engine_take'\] = false/, 'a failure clears the flag');
my $stop = body($studio, 'studioEngineStop');
like($stop, qr/mixer\['time'\]\['engine_take'\] = false/, 'a stop clears the flag');
my $teardown = body($controls, 'studioTeardown');
like($teardown, qr/engine_take'\] = false/, 'teardown clears the flag too');

my $sched = body($transport, 'studioScheduleClicks');
ok(length $sched, 'the browser click scheduler is still one function');
like($sched, qr/if \(mixer\['time'\] && mixer\['time'\]\['engine_take'\]\) \{ return; \}/,
	'the browser adds no second click during an engine take');
like($sched, qr/osc\.frequency\.value = accent \? 1100 : 900;/,
	'the browser click itself is unchanged');

# --- the engine source names the click/record contract -----------------------
my $socket   = read_file("$root/engine/src/socket.rs");
my $playback = read_file("$root/engine/src/playback.rs");

like($socket, qr/let click = match parse_click\(get\(object, "click"\)\)/,
	'record parses the click before any file or thread exists');
like($socket, qr/!monitor_tracks\.is_empty\(\) \|\| monitor_input \|\| click\.is_some\(\)/,
	'a click-only monitor opens the output');
like($socket, qr/Playback::click_only\(config\.rate, length\.unwrap_or\(0\)\)/,
	'and is a legal playback with no live input');
like($socket, qr/let live_length = if monitor_input \|\| click\.is_some\(\)/,
	'the click runs for the take, not only while a live input is armed');

like($playback, qr/pub struct ClickSpec/, 'the click request is one public type');
like($playback, qr/pub fn click_only\(/, 'a click-only playback is constructible');
like($playback, qr/pub fn with_click\(/, 'a playback accepts the take\'s click');
like($playback, qr/fn render_into\(/, 'the block loop only adds the click');
like($playback, qr/beats_per_bar/, 'the accent follows the bar');
like($playback, qr/CLICK_ACCENT_HZ/, 'and has its own pitch');

# The click is added after the master chain and before the system mix.
my $render_at = index($playback, 'pub fn render(&mut self, out: &mut [f32])');
my $render_end = index($playback, '/// What a device loop asks for');
my $render = substr($playback, $render_at, $render_end - $render_at);
my $mix_at = index($render, 'mix_with_live');
my $click_at = index($render, 'click.render_into(out');
my $system_at = index($render, 'system.consumer.pop');
ok($mix_at >= 0 && $click_at > $mix_at,
	'the click is mixed after the master chain');
ok($system_at >= 0 && $click_at < $system_at,
	'and before the machine mix, still on the monitor output only');

# The take's capture path never hears the click.
my $run_take_at = index($socket, 'fn run_take(');
my $run_take_end = index($socket, 'fn ', $run_take_at + length 'fn run_take(');
my $run_take = $run_take_at >= 0
	? substr($socket, $run_take_at, $run_take_end - $run_take_at)
	: '';
ok(length $run_take, 'the take worker is one function');
unlike($run_take, qr/[Cc]lick/, 'the take\'s capture path never names the click');

done_testing();
