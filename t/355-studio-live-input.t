# tests-for: lib/JawnOS/Controller/manager_misc9.pm lib/JawnOS/Audio/Engine.pm docs/studio-effects.md public/js/manager/studio.js public/js/manager/studio/05_inputs.js public/js/manager/studio/06_controls.js public/js/manager/studio/15_house_patch.js templates/studio/plug_selection.html.ep
# covers:    the live-input contract on the manager side - audio_engine_record
#            puts `monitor_input` and `monitor_gain` on the record wire and
#            leaves them out when off or undefined, a take's per-track plan
#            accepts `channels` 1 or 2 and refuses anything else, a stereo pair
#            claims both device channels so an overlap names the two tracks,
#            the start route validates and clamps the monitor switch and its
#            gain, and the fourth `param` target forwards one `gain` knob.
#            The input picker opens on the plan's saved node, including a source
#            that names this machine explicitly.

use strict;
use warnings;
# The route's engine hooks are replaced with `local *...` in one test block, and
# that single mention would otherwise be reported as a possible typo.
no warnings 'once';

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
# scratch directory, so nothing here may depend on the working directory.
my $root = abs_path("$FindBin::Bin/..");

# --- a mock engine ------------------------------------------------------------
# One line in, one line out, one client at a time, exactly the engine's shape.
# Every request is logged before the reply, so a count proves whether a refused
# request ever reached the socket.
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
# The route module is loaded from a scratch directory carrying config.json and
# the tree's database seeds, so requiring it never writes to the house checkout.
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

ok(Manager->can('studio_take_json_plan'), 'the controller defines the plan builder');
ok(Manager->can('studio_monitor_start'), 'and the monitor-start validator');

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
sub render_to_string {
	my ($self, @args) = @_;
	my %args;
	while (@args) {
		my $name  = shift @args;
		my $value = shift @args;
		$args{$name} = $value;
	}
	$self->{'rendered'} = \%args;
	return '';
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

# --- the record wire carries the monitor fields ------------------------------
{
	my ($path, $log) = start_mock(replies => {
		record => '{"ok":true,"take":1,"state":"recording","path":"/tmp/take.wav"}',
	});
	local $ENV{JAWNOS_AUDIO_SOCKET} = $path;

	my $answer = JawnOS::Audio::Engine::audio_engine_record(
		'/tmp/take.wav', 10, 0,
		{
			tracks        => [ { input => 0, channels => 2, inserts => [] } ],
			master        => ['master_comp'],
			monitor_input => 1,
			monitor_gain  => 0.9,
		},
	);
	ok($answer->{'ok'}, 'a monitored take is accepted');
	my $request = (logged_requests($log))[-1];
	ok($request->{'monitor_input'}, 'monitor_input is forwarded when it is on');
	is($request->{'monitor_gain'}, 0.9, 'monitor_gain is forwarded as a number');
	like(last_line($log), qr/"monitor_input":true/, 'the switch is a JSON boolean');
	like(last_line($log), qr/"monitor_gain":0\.9/, 'the gain is a JSON number');
	is_deeply($request->{'tracks'}, [ { input => 0, channels => 2, inserts => [] } ],
		'the per-track plan still travels unchanged');
	is_deeply($request->{'master'}, ['master_comp'], 'and the master rack still travels');

	# Off is absent: a false switch is not sent at all.
	JawnOS::Audio::Engine::audio_engine_record(
		'/tmp/take.wav', 5, 0, { monitor_input => 0 },
	);
	my $off = (logged_requests($log))[-1];
	ok(!exists $off->{'monitor_input'}, 'a switched-off monitor is not on the wire');
	ok(!exists $off->{'monitor_gain'}, 'and no gain accompanies it');
	unlike(last_line($log), qr/monitor_input/, 'neither word appears in the line');

	# An on switch with no gain leaves the engine's own default in charge.
	JawnOS::Audio::Engine::audio_engine_record(
		'/tmp/take.wav', 5, 0, { monitor_input => 1 },
	);
	my $bare = (logged_requests($log))[-1];
	ok($bare->{'monitor_input'}, 'the switch is still on');
	ok(!exists $bare->{'monitor_gain'}, 'an undefined gain is left to the engine');

	# A gain without the switch is forwarded on its own; the engine ignores it.
	JawnOS::Audio::Engine::audio_engine_record(
		'/tmp/take.wav', 5, 0, { monitor_gain => 0.5 },
	);
	my $gain_only = (logged_requests($log))[-1];
	ok(!exists $gain_only->{'monitor_input'}, 'a gain alone does not arm the switch');
	is($gain_only->{'monitor_gain'}, 0.5, 'but a defined gain still travels');

	# The old three-argument call is untouched.
	JawnOS::Audio::Engine::audio_engine_record('/tmp/take.wav', 1, 0);
	my $plain = (logged_requests($log))[-1];
	is_deeply([sort keys %$plain], [qw(cmd out seconds start_at)],
		'a plain record sends only its three fields');
}

# --- channels on a take plan --------------------------------------------------
{
	my ($error, $plan) = Manager::studio_take_json_plan(encode_json([ { input => 0 } ]));
	is($error, undef, 'a track with no channels is accepted');
	is_deeply($plan, [ { input => 0, inserts => [] } ],
		'and stays the historical mono shape');

	($error, $plan) = Manager::studio_take_json_plan(
		encode_json([ { input => 0, channels => 1, inserts => [] } ]),
	);
	is($error, undef, 'channels 1 is accepted');
	ok(!exists $plan->[0]{'channels'}, 'and is not sent, because mono is the default');

	($error, $plan) = Manager::studio_take_json_plan(
		encode_json([ { input => 2, channels => 2, inserts => ['tone'] } ]),
	);
	is($error, undef, 'channels 2 is accepted');
	is($plan->[0]{'channels'}, 2, 'and is sent to the engine');
	is($plan->[0]{'input'}, 2, 'with the first device channel');
	is_deeply($plan->[0]{'inserts'}, ['tone'], 'and the track\'s chain');

	for my $bad (0, 3, 1.5, 'two') {
		my ($why, $refused) = Manager::studio_take_json_plan(
			encode_json([ { input => 0, channels => $bad } ]),
		);
		ok(defined $why, "channels '$bad' is refused");
		like($why, qr/channels must be 1 \(mono\) or 2 \(stereo\)/,
			'with the two source words');
		ok(!defined $refused, "channels '$bad' builds no plan");
	}

	# A stereo pair claims two device channels: the mono at 1 is an overlap.
	($error, $plan) = Manager::studio_take_json_plan(encode_json([
		{ input => 0, channels => 2 },
		{ input => 1, channels => 1 },
	]));
	is($error,
		"tracks_json track 2 input 1 overlaps track 1's stereo pair 0-1",
		'an overlap names both tracks and the claimed pair');
	ok(!defined $plan, 'and no plan is handed on');

	# The same overlap is refused the other way round, and names the mono first.
	($error) = Manager::studio_take_json_plan(encode_json([
		{ input => 1, channels => 1 },
		{ input => 0, channels => 2 },
	]));
	is($error,
		"tracks_json track 2 input 0 overlaps track 1's input 1",
		'a pair overlapping an earlier mono names that input');

	# A pair may read 30 and 31, but not claim a channel past the bound.
	($error, $plan) = Manager::studio_take_json_plan(
		encode_json([ { input => 30, channels => 2 } ]),
	);
	is($error, undef, 'a pair on the last two channels is accepted');
	($error) = Manager::studio_take_json_plan(
		encode_json([ { input => 31, channels => 2 } ]),
	);
	like($error, qr/between 0 and 30 for a stereo pair/,
		'a pair that would claim channel 32 is refused');
	($error, $plan) = Manager::studio_take_json_plan(
		encode_json([ { input => 31, channels => 1 } ]),
	);
	is($error, undef, 'a mono may still use channel 31');

	# Two tracks on the same input keep the older, clearer sentence.
	($error) = Manager::studio_take_json_plan(encode_json([
		{ input => 0 }, { input => 0 },
	]));
	is($error, 'tracks_json track 2 names input 0 twice',
		'a repeated input keeps the duplicate sentence');

	# A channel send: the destination names the source track instead of a
	# device input, and keeps its own insert chain.
	($error, $plan) = Manager::studio_take_json_plan(encode_json([
		{ input => 0, inserts => ['tone'] },
		{ from => 0, inserts => ['delay'] },
	]));
	is($error, undef, 'a track fed by another track is accepted');
	is_deeply($plan, [
		{ input => 0, inserts => ['tone'] },
		{ from => 0, inserts => ['delay'] },
	], 'and the send reaches the engine instead of an input');

	for my $case (
		[ 'its own output', [ { from => 0 } ], qr/cannot take its own output/ ],
		[ 'a missing track', [ { input => 0 }, { from => 4 } ], qr/outside the take's 2 tracks/ ],
		[ 'an input too', [ { input => 1 }, { from => 0, input => 1 } ], qr/cannot also name "input"/ ],
		[ 'channels too', [ { input => 1 }, { from => 0, channels => 2 } ], qr/cannot also name "channels"/ ],
		[ 'one source twice', [ { input => 0 }, { from => 0 }, { from => 0 } ], qr/one destination/ ],
		[ 'a loop', [ { from => 1 }, { from => 0 } ], qr/channel send loop/ ],
	) {
		my ($why, $entries, $error_match) = @$case;
		my ($refused) = Manager::studio_take_json_plan(encode_json($entries));
		ok(defined $refused, "a send with $why is refused");
		like($refused, $error_match, "and the sentence names $why");
	}
}

# --- the start route validates and forwards the monitor ----------------------
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

	# Absent: every accepted spelling of off leaves $extra unarmed.
	for my $off (undef, '', 'false', 'no') {
		my $fake = run_take(
			seconds => '5',
			(defined $off ? (monitor_input => $off) : ()),
		);
		is($fake->{'status'}, 200,
			'monitor_input ' . (defined $off ? "'$off'" : '(missing)') . ' is accepted');
		ok(!defined $calls[-1][3], 'and sends no plan at all');
	}

	# On: the switch and its unity default reach the engine's plan hash.
	for my $on ('true', '1', 'yes') {
		my $fake = run_take(seconds => '5', monitor_input => $on);
		is($fake->{'status'}, 200, "monitor_input '$on' is on");
		my $extra = $calls[-1][3];
		is($extra->{'monitor_input'}, 1, 'the switch is on in the plan');
		is($extra->{'monitor_gain'}, 1, 'and the gain defaults to one');
	}

	my $gain = run_take(seconds => '5', monitor_input => 'true', monitor_gain => '0.9');
	is($gain->{'status'}, 200, 'a gain on a monitored take is accepted');
	is($calls[-1][3]{'monitor_gain'}, 0.9, 'and is forwarded');

	my $loud = run_take(seconds => '5', monitor_input => 'true', monitor_gain => '9');
	is($calls[-1][3]{'monitor_gain'}, 4, 'a gain above four is clamped');
	my $quiet = run_take(seconds => '5', monitor_input => 'true', monitor_gain => '-2');
	is($calls[-1][3]{'monitor_gain'}, 0, 'a negative gain is clamped to zero');

	my $before = scalar @calls;
	my $bad_word = run_take(seconds => '5', monitor_input => 'maybe');
	is($bad_word->{'status'}, 400, 'an unknown switch word is a 400');
	is($bad_word->{'json'}{'error'}, 'monitor_input must be on or off',
		'and says the switch is on or off');
	is(scalar @calls, $before, 'and nothing is sent');

	my $bad_gain = run_take(seconds => '5', monitor_input => 'true', monitor_gain => 'loud');
	is($bad_gain->{'status'}, 400, 'a non-number gain is a 400');
	is($bad_gain->{'json'}{'error'}, 'monitor_gain must be a finite number',
		'and is not silently defaulted');
	is(scalar @calls, $before, 'and nothing is sent');
}

# --- the fourth param target --------------------------------------------------
{
	my ($path, $log) = start_mock(replies => {
		param => '{"ok":true,"target":"input","name":"gain","frames":2048}',
	});
	local $ENV{JAWNOS_AUDIO_SOCKET} = $path;

	my $fake = run_take(action => 'param', target => 'input', name => 'gain', value => '0.5');
	is($fake->{'status'}, 200, 'an input knob is 200');
	is($fake->{'json'}{'ok'}, 1, 'and relays the engine answer');
	my $request = (logged_requests($log))[-1];
	is($request->{'cmd'}, 'param', 'it is a param command');
	is($request->{'target'}, 'input', 'addressed to input');
	is($request->{'name'}, 'gain', 'with the one name it carries');
	is($request->{'value'}, 0.5, 'and a number');
	ok(!exists $request->{'track'}, 'an input knob carries no track');

	run_take(action => 'param', target => 'input', name => 'gain', value => '9');
	is((logged_requests($log))[-1]{'value'}, 4, 'above four is clamped');
	run_take(action => 'param', target => 'input', name => 'gain', value => '-1');
	is((logged_requests($log))[-1]{'value'}, 0, 'below zero is clamped');

	my $before = request_count($log);
	for my $bad (qw(pan gainx tone.bass '')) {
		my $refused = run_take(action => 'param', target => 'input', name => $bad, value => '0.5');
		is($refused->{'status'}, 400, "the input name '$bad' is a 400");
		is($refused->{'json'}{'error'}, 'target "input" only carries "gain"',
			'and names the one control');
	}
	my $bad_value = run_take(action => 'param', target => 'input', name => 'gain', value => 'loud');
	is($bad_value->{'status'}, 400, 'a non-number is a 400');
	like($bad_value->{'json'}{'error'}, qr/value must be a finite number/,
		'and names the number rule');
	is(request_count($log), $before, 'a refused input knob never reaches the engine');
}

# --- the docs pin the same contract -------------------------------------------
my $doc = read_file("$root/docs/studio-effects.md");
like($doc, qr/`monitor_input`.*boolean/s, 'the docs name the monitor switch');
like($doc, qr/`monitor_gain`.*finite number/s, 'and its finite gain');
like($doc, qr/`channels`, a whole `1` or `2`/, 'and the per-track source width');
like($doc, qr/overlaps track 1's stereo pair\s+0-1/,
	'including the overlap sentence it refuses');
like($doc, qr/target: "input"/, 'and the fourth param target');

# --- Monitor follows the track's input, not the machine ----------------------
# The page chooses the monitor path from the track's plug: no input is silence,
# an app is the browser's post-FX tap, and a real device is the engine's Listen
# on its own numbered input. Only the real-device path may open a microphone.
my $studio_js = read_file("$root/public/js/manager/studio.js");
my $controls_js = read_file("$root/public/js/manager/studio/06_controls.js");
my $inputs_js = read_file("$root/public/js/manager/studio/05_inputs.js");

like($inputs_js, qr/function studioChannelInput\(/, 'the track\'s plug is readable');
like($inputs_js, qr/\['marker', 'music', 'synth', 'drums'\]\.indexOf\(/,
	'an app input is named by its app');
like($inputs_js, qr/plug\['type'\] == 'usermedia' && plug\['av'\] == 'a'/,
	'a real audio device is the one the engine can open');
like($inputs_js, qr/function studioInputListenChannel\(/,
	'and its input number is the engine\'s Listen channel');
like($inputs_js, qr/if \(direction == 'input' && type == 'usermedia' && av == 'a'\) \{ data\.input = input; \}/,
	'the device number is stored with the plug when it is chosen');

# The lane's live stereo waveform reads the same record path through one
# splitter with an analyser per channel; the canvas mirrors a mono input.
like($studio_js, qr/recSplit: ctx\.createChannelSplitter\(2\)/, 'the record path grows a stereo split');
like($studio_js, qr/c\.recAnalyserL\.fftSize = 1024;/, 'the left analyser is sized for the lane');
like($studio_js, qr/c\.recAnalyserR\.fftSize = 1024;/, 'and the right');
like($studio_js, qr/c\.recSplit\.connect\(c\.recAnalyserL, 0\);/, 'the splitter feeds the left analyser');
like($studio_js, qr/c\.recSplit\.connect\(c\.recAnalyserR, 1\);/, 'and the right one');
like($inputs_js, qr/if \(typeof studioDrawTracks === 'function'\) \{ studioDrawTracks\(\); \}/,
	'a take handed over after the recorder stops repaints the lane');

like($studio_js, qr/var engine = !!\(device && listen_channel <= 1\s*&& \(picked_native \|\|/,
	'a device on a native backend is the engine Listen');
like($studio_js, qr/&& \(typeof studioEngineAvailable === 'undefined' \|\| studioEngineAvailable !== false\)/,
	'only while the engine is known to be available');
like($studio_js, qr/function studioMonitorEngineFallback\(\)/,
	'and a refused Listen has a browser fallback');
like($studio_js, qr/var listening = \(engine && \(studioListenActive \|\| from_user\)\)/,
	'a restored Monitor stays on the tap until the engine Listen runs');
like($studio_js, qr/engine_path && studioEngineListening/,
	'a confirmed engine Listen keeps the browser tap off');
like($studio_js, qr/var app_monitor = ch_app && on && !!input;/,
	'Monitor on an app swaps it to the In chain');
like($studio_js, qr/var live = \(!ch_drums && ch_app && !app_monitor\) \|\| \(on && !ch_app && !!input && !listening\);/,
	'an app is live while patched, the kit and a device only while Monitor is on');
like($studio_js, qr/c\.live\.gain\.value = live \? 1 : 0;/,
	'the live path is the channel output');
like($studio_js, qr/c\.monGain\.gain\.value = app_monitor \? 1 : 0;/,
	'the In tap is only the app Monitor comparison');
like($studio_js, qr/if \(engine\) \{[\s\S]*?studioListenStart\(false, listen_channel, active, true\)/,
	'a device starts the engine on its own input, asking for the fallback');
like($studio_js, qr/else if \(studioListenActive\) \{ studioListenStop\(\); \}/,
	'an app or no input does not start the engine Listen');
like($studio_js, qr/function studioApplyMonitor\(from_user, force_tap_device\)/,
	'the browser fallback can open a device capture without a fresh press');
like($studio_js, qr/studioApplyMonitor\(false, true\)/,
	'a refused engine Listen re-applies with the browser device');
like($studio_js, qr/studioMonitorAttachDevice\(active\)/,
	'a browser-monitored device opens its capture');
like($inputs_js, qr/function studioMonitorAttachDevice\(ch\)/,
	'and the device monitor knows when an armed track already owns the capture');
like($inputs_js, qr/function studioMonitorDetachDevice\(ch\)/,
	'leaving the monitor closes only the capture it opened');

like($controls_js, qr/function studioListenStart\(quiet, channel, ch, fallback\)/,
	'Listen can name the input and the monitored rack, and take the fallback flag');
like($controls_js, qr/channel: listen_channel/, 'and sends that input to the engine');
like($controls_js, qr/inserts: studioListenInserts\(ch\)/,
	'through the monitored track\'s pedals');
like($controls_js, qr/if \(fallback\) \{ request\.system = 0; \}/,
	'Monitor asks for its input alone, without the house mix');

# --- the engine is only the monitor while its socket is live ------------------
# The status reply names `available`; studioEngineStatus stores it, and the
# monitor side reads it before choosing the engine or the browser capture.
like($controls_js, qr/var studioEngineAvailable = false;/,
	'the page starts without a known live engine');
like($studio_js, qr/studioEngineAvailable = \(data\.available === 1\);\n\t\t\tif \(typeof studioAudioBackendReset/,
	'the status answer records the live socket');
unlike($controls_js, qr/studioEngineAnswer = function/,
	'no part monkey-patches the shared status hook');
like($controls_js, qr/function studioSetMonitor\(ch, on, from_user\) \{[\s\S]{0,300}?studioMonitorEngineFailed = false;/,
	'pressing Monitor tries the engine again');
my $fallback_calls = () = $controls_js =~ /if \(fallback && typeof studioMonitorEngineFallback === 'function'\) \{ studioMonitorEngineFallback\(\); \}/g;
is($fallback_calls, 5, 'a refused engine Listen, a refused transport and every USB refusal (including a plan that cannot be built) fall back to the browser');
like($controls_js, qr/if \(next_channel !== undefined\) \{ studioListenStart\(false, next_channel, ch, true\); \}/,
	'moving the one Listen keeps the fallback request');

# An app has no device behind it, so Monitor may build its graph itself on an
# unarmed track; a device is the engine's Listen and never the browser capture.
like($inputs_js, qr/function studioAttachAppInput\(/, 'one app attach path serves Monitor and the arm button');
like($inputs_js, qr/function studioMonitorAttachApp\(/, 'Monitor attaches an app on an unarmed track');
like($inputs_js, qr/function studioMonitorDetachApp\(/, 'and detaches it when Monitor lets go');
like($inputs_js, qr/if \(state === 'rec' \|\| state === 'loop'\) \{ return false; \}/,
	'an armed track keeps its own graph');
like($studio_js, qr/studioMonitorAttachApp\(active\)/, 'Monitor builds the app graph');
like($studio_js, qr/studioMonitorDetachApp\(previous_app\)/, 'and detaches the one it built');
like($inputs_js, qr/if \(typeof studioApplyMonitor === 'function'\) \{ studioApplyMonitor\(\); \}/,
	'the arm button re-applies a monitored app');

my ($monitor_attach) = $inputs_js =~ /(function studioMonitorAttachApp\b.*?)(?=\nfunction studioMonitorDetachApp\b)/s;
ok(defined $monitor_attach, 'the Monitor attach helper is readable');
unlike($monitor_attach // '', qr/getUserMedia|studioInputStreamGrabber/,
	'Monitor never opens the browser capture for an app');
my ($app_attach) = $inputs_js =~ /(function studioAttachAppInput\b.*?)(?=\nasync function studioInputStreamGrabber\b)/s;
ok(defined $app_attach, 'the app attach path is readable');
unlike($app_attach // '', qr/getUserMedia/, 'the app attach path never opens a device');

unlike($studio_js, qr/c\.monGain\.gain\.value = \(on && !nativeish\) \? 1 : 0/,
	'the tap is not muted for every native backend');

# --- every audio device row names its interface input -----------------------
# The UM2 has two inputs; a channel must be able to say which one it takes
# instead of inferring it from the device's place in the list.
my $template = read_file("$root/templates/studio/plug_selection.html.ep");
like($template, qr/class="studio_input_channel"/,
	'an audio input row carries its own interface-input selector');
like($template, qr/<option value="0"[^>]*>.*?Input 1 \(channel 0\)/,
	'Input 1 is channel 0');
like($template, qr/<option value="1"[^>]*>.*?Input 2 \(channel 1\)/,
	'and Input 2 is channel 1');
like($template, qr/\$av->\{'kind'\} eq 'audioinput'\) \{\s*%>\s*<br><select class="studio_input_channel"/,
	'a camera or an output row keeps no selector');
like($template, qr/\$input \? ' selected' : ''/, 'the saved input is the row selected');
like($inputs_js, qr/input = Number\(sis\.find\('\.studio_input_channel'\)\.val\(\)\) \|\| 0;/,
	'a real audio input takes the interface input its row names');
like($inputs_js, qr/if \(input > 1\) \{ input = 1; \}/, 'and the number is clamped to the two inputs');
unlike($inputs_js, qr/\.index\(sis\)/, 'not its place in the device list');
like($inputs_js, qr/data\.input = input;/, 'and that number is stored with the plug');

# A real input is opened by the device the picker names; an audio interface is
# asked for two channels, so the splitter can take Input 2. A screen share keeps
# getDisplayMedia's stream.
like($inputs_js, qr/if \(plug\['type'\] == 'usermedia'\) \{\s*if \(plug\['id'\]\) \{ audio\.deviceId = \{ exact: plug\['id'\] \}; \}/,
	'a camera or microphone opens the device its plug names');
like($inputs_js, qr/if \(plug\['type'\] == 'usermedia' && plug\['av'\] == 'a'\) \{\s*audio\.channelCount = Math\.max\(2, channels \|\| 0\);/,
	'and an audio interface asks for both interface channels');
like($inputs_js, qr/audio\.channelCount = Math\.max\(2, channels \|\| 0\);/,
	'and asks for both interface channels');

# --- the House patch section -------------------------------------------------
# The input picker also carries the plan's other sources: a voice and a deck
# cannot own a track take, so their monitor, effects and the bus take live here.
my $house_js = read_file("$root/public/js/manager/studio/15_house_patch.js");
my $plan_pm = read_file("$root/lib/JawnOS/Audio/Plan.pm");

like($template, qr/id="studio_house_patch"/, 'the input picker has a House patch section');
like($template, qr/<%= &subs::ui\('House patch'\) %>/, 'named House patch');
like($template, qr/defined \$direction && \$direction eq 'input'/, 'only an input panel shows it');
like($template, qr/studio_house_patch_take/, 'and the bus take has its own box');
like($inputs_js, qr/studioHouseFill\(sis, x, y\)/, 'the picker fills it after it is shown');
like($inputs_js, qr/function studioPlugClamp\(/, 'the panel is clamped again when the rows arrive');

like($house_js, qr#url: '/manager/sound/plan'#, 'the section reads the saved plan');
like($house_js, qr#url: '/manager/sound/param'#, 'a monitor move is a live fader');
like($house_js, qr/target: 'patch_source', source: index, name: name/, 'addressed to the source');
like($house_js, qr/source\.gain = value/, 'the source trim moves in the plan');
like($house_js, qr/studioHouseSourceParam\(id, 'mute', on\)/, 'the mute is a live footswitch');
like($house_js, qr/function studioHouseSourceEffects\(/, 'the engine reports each source');
like($house_js, qr/engine\.source_effects/, 'the page reads the live trim and mute');
like($house_js, qr#url: '/manager/sound/plan',\s*type: 'POST'#s, 'a plan fact is saved through the plan');
like($house_js, qr/studioHouseTakeBus/, 'the bus take chooses a bus');
like($house_js, qr/if \(\$\.inArray\('mix', ids\) >= 0\) \{ return 'mix'; \}/, 'the mix bus is offered first');
like($house_js, qr/action: 'start',\s*bus: bus,\s*seconds: seconds,\s*click_json:/s, 'Record house mix sends the bus take');
like($house_js, qr/data: \{ action: 'status' \}/, 'and polls the engine status');
like($house_js, qr/data: \{ action: 'stop' \}/, 'Stop ends the bus take');
like($house_js, qr/function studioHouseClick\(/, 'the click comes from the transport');
like($house_js, qr/mixer\['time'\]\['bpm'\]/, 'with its tempo');
like($house_js, qr/mixer\['time'\]\['sig'\]/, 'and signature');
like($house_js, qr/function studioHouseSourceState\(/, 'a source has a state');
like($house_js, qr/engine\.silent/, 'silent comes from the engine');
like($house_js, qr/engine\.inputs/, 'bound comes from the bound inputs');
like($house_js, qr/studio_house_state_/, 'and the state is drawn');
like($house_js, qr/studio_house_insert_select/, 'an effect can be chosen');
like($house_js, qr/source\.inserts\.push\(\{ name: name, bypass: 0, controls: \{\} \}\)/, 'adding an insert writes the plan shape');

# The page offers exactly the names the plan accepts, in the same order.
my ($plan_names) = $plan_pm =~ /our \@audio_plan_insert_names = qw\((.*?)\);/s;
my @plan_names = grep { length } split /\s+/, ($plan_names || '');
my ($js_names) = $house_js =~ /var studioHouseInsertNames = \[(.*?)\];/s;
my @js_names = ($js_names || '') =~ /'([^']+)'/g;
is_deeply(\@js_names, \@plan_names, 'the page offers exactly the engine effect names the plan accepts');

# The insert shape the engine agent compiles is documented here.
my $effects = read_file("$root/docs/studio-effects.md");
like($effects, qr/A source's inserts in the house plan/, 'the docs name the source inserts');
like($effects, qr/"inserts":\s*\[/s, 'and show the array');
like($effects, qr/"name": "reverb", "bypass": 0, "controls"/, 'with name, bypass and controls');
like($effects, qr/Order is the chain/, 'and chain order');

# --- the input picker opens on the saved source ------------------------------
# A plan may name this machine explicitly: Sound's source form writes it and
# the engine writes the hostname, so a `machine` equal to this host is still
# this machine's source, and its node is the one the picker opens on.
{
	require Sys::Hostname;
	no warnings 'redefine';
	local *Sys::Hostname::hostname = sub { 'table' };
	my $node = 'alsa_input.usb-BEHRINGER_UMC202HD-00.analog-stereo';
	local *subs::audio_plan_read = sub {
		return { sources => [
			{ id => 'um2-in0', kind => 'input', machine => 'table', channel => 0, node => $node },
		] };
	};
	local *subs::audio_capture_sources = sub { return [] };

	my $fake = FakeStudioTakeController->new({
		channel     => 'plug-1',
		direction   => 'input',
		information => encode_json({ input => 0 }),
		constraints => encode_json({}),
		apps        => encode_json([]),
	});
	Manager::action_28457($fake);
	is($fake->{'rendered'}{input_node}, $node,
		'a source tagged with this machine hands the picker its saved node');

	local *Sys::Hostname::hostname = sub { 'elsewhere' };
	Manager::action_28457($fake);
	is($fake->{'rendered'}{input_node}, '',
		'and a source on another machine is not offered');
}

done_testing();
