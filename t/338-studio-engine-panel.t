# tests-for: lib/JawnOS/Controller/manager_misc9.pm lib/JawnOS/Audio/Engine.pm templates/studio/markup.html.ep templates/studio/style.html.ep public/js/manager/studio.js public/js/manager/studio/04_knobs.js public/js/manager/studio/06_controls.js perl/help/topics_apps.pl
# covers:    Studio's Engine take panel - POST /manager/studio/take action=param
#            relays one strip knob per name class through a live Unix socket,
#            refuses an unknown name, a bad number and a bad track with a 400
#            and nothing on the wire, relays status, starting and stopping a
#            live listen with a validated input, gain and insert chain, and the
#            one knob addressed to `listen`; the markup, the scripts and the
#            help topic carry the panel.

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

# --- a mock engine ------------------------------------------------------------
# One line in, one line out, one client at a time, exactly the engine's shape.
# The fixture records every request before it replies, so a count from the log
# proves whether a refused request ever reached the socket.
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

sub request_count {
	my ($log) = @_;
	my @rows = logged_requests($log);
	return scalar @rows;
}

# --- the controller's sandbox -------------------------------------------------
# The route module is loaded the way t/336 loads it: from a scratch directory
# that carries config.json and the tree's database seeds, so requiring it never
# writes to the house checkout.
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
	my $fake = FakeStudioTakeController->new({ %params });
	Manager::action_44023($fake);
	$fake->{'status'} = 200 unless defined $fake->{'status'};
	return $fake;
}

# --- param relays for every name class ---------------------------------------
my %reply = (
	param  => '{"ok":true,"track":0,"name":"gain"}',
	status => '{"ok":true,"take":1,"state":"recording","path":"/tmp/take.wav","frames":4800,"dropped":7,"gain":1,"pan":0,"inserts":"tone","error":""}',
	stop   => '{"ok":true,"take":1,"state":"done","frames":48000,"dropped":0,"error":""}',
);

my @names = qw(
	gain pan
	tone.bass tone.mid tone.treble
	distortion.drive
	delay.time delay.feedback delay.mix
	compressor.threshold compressor.attack compressor.mix
	reverb.mix reverb.volume
);

{
	my ($path, $log) = start_mock(replies => \%reply);
	local $ENV{JAWNOS_AUDIO_SOCKET} = $path;

	my $before = request_count($log);
	for my $name (@names) {
		my $fake = run_take(action => 'param', track => '0', name => $name, value => '0.5');
		is($fake->{'status'}, 200, "$name is accepted");
		is($fake->{'json'}{'ok'}, 1, "$name relays the engine's reply");
		is(request_count($log), $before + 1, "$name sends exactly one line");

		my @sent = logged_requests($log);
		my $request = $sent[-1];
		is($request->{'cmd'}, 'param', "$name is a param command");
		is($request->{'name'}, $name, "$name keeps the engine's spelling");
		is($request->{'track'}, 0, "$name carries the 0-based track");
		is($request->{'value'}, 0.5, "$name carries the number, not a string");
		$before = request_count($log);
	}

	# A non-zero track, a negative value and the exponent form travel too.
	my $deep = run_take(action => 'param', track => '3', name => 'pan', value => '-0.25');
	is($deep->{'status'}, 200, 'track 3 and a negative pan are accepted');
	my $request = (logged_requests($log))[-1];
	is($request->{'track'}, 3, 'the track is passed through');
	is($request->{'value'}, -0.25, 'a negative value keeps its sign');

	my $tiny = run_take(action => 'param', track => '0', name => 'delay.mix', value => '1e-3');
	is($tiny->{'status'}, 200, 'a value in exponent form is a number');
	my $tiny_request = (logged_requests($log))[-1];
	is($tiny_request->{'value'}, 0.001, 'and reaches the engine as 0.001');

	# An insert and control the old whitelist never named now has the
	# contract's shape, so the route forwards it and the engine decides.
	my $new_insert = run_take(action => 'param', track => '0', name => 'flanger.rate', value => '1.4');
	is($new_insert->{'status'}, 200, 'a new insert control is accepted');
	my $new_request = (logged_requests($log))[-1];
	is($new_request->{'name'}, 'flanger.rate', 'and keeps the engine spelling');
	is($new_request->{'value'}, 1.4, 'with its natural-unit value');

	# The master rack is a separate address: no track, `target: master`.
	my $master = run_take(action => 'param', target => 'master', name => 'master_comp.thresh', value => '-20');
	is($master->{'status'}, 200, 'a master knob is accepted');
	my $master_request = (logged_requests($log))[-1];
	is($master_request->{'cmd'}, 'param', 'it is a param command');
	is($master_request->{'target'}, 'master', 'addressed to master');
	is($master_request->{'name'}, 'master_comp.thresh', 'with the master prefix');
	is($master_request->{'value'}, -20, 'and a number');
	ok(!exists $master_request->{'track'}, 'a master knob carries no track');

	# --- a name outside the contract's shape is refused here ----------------
	my $unchanged = request_count($log);
	for my $bad (qw(flanger Gain volume tone_air tone. .mix)) {
		my $fake = run_take(action => 'param', track => '0', name => $bad, value => '0.5');
		is($fake->{'status'}, 400, "the name '$bad' is a 400");
		ok(!$fake->{'json'}{'ok'}, 'with ok false');
		like($fake->{'json'}{'error'}, qr/no such parameter/, 'and names the parameter it refused');
	}
	is(request_count($log), $unchanged, 'an unknown name never reaches the engine');

	# --- a bad track or value is refused here, not by the engine ------------
	my @bad_tracks = ('-1', '1.5', 'x', undef, '32', '');
	for my $track (@bad_tracks) {
		my $fake = run_take(action => 'param', track => $track, name => 'gain', value => '0.5');
		is($fake->{'status'}, 400, 'track ' . (defined $track ? "'$track'" : '(missing)') . ' is a 400');
		like($fake->{'json'}{'error'}, qr/track must be a whole number/,
			'and the refusal names the track rule');
	}
	is(request_count($log), $unchanged, 'a malformed track never reaches the engine');

	my @bad_values = ('abc', '', undef, 'NaN', 'Inf', '-Inf', '1e999', '0x10', '1,5');
	for my $value (@bad_values) {
		my $fake = run_take(action => 'param', track => '0', name => 'gain', value => $value);
		is($fake->{'status'}, 400, 'value ' . (defined $value ? "'$value'" : '(missing)') . ' is a 400');
		like($fake->{'json'}{'error'}, qr/value must be a finite number/,
			'and the refusal names the number rule');
	}
	is(request_count($log), $unchanged, 'a non-number never reaches the engine');

	# --- status is relayed field for field ---------------------------------
	my $status = run_take(action => 'status');
	is($status->{'status'}, 200, 'status is 200');
	is($status->{'json'}{'state'}, 'recording', 'and relays the engine state');
	is($status->{'json'}{'frames'}, 4800, 'with the frame count');
	is($status->{'json'}{'dropped'}, 7, 'and the dropped count');
	is((logged_requests($log))[-1]{'cmd'}, 'status', 'status went over the socket');
}

# --- the engine's own refusal is relayed verbatim ----------------------------
{
	my ($path, $log) = start_mock(replies => {
		param => '{"ok":false,"error":"no take is running"}',
	});
	local $ENV{JAWNOS_AUDIO_SOCKET} = $path;

	my $fake = run_take(action => 'param', track => '0', name => 'gain', value => '1');
	is($fake->{'status'}, 200, 'a refused knob is the engine answer, not a route fault');
	is($fake->{'json'}{'error'}, 'no take is running',
		'the engine sentence is relayed word for word');
	is(request_count($log), 1, 'and the request did reach the socket');
}

# --- live listening: start, stop and its one knob ---------------------------
{
	my ($path, $log) = start_mock(replies => {
		listen => '{"ok":true,"state":"listening","channel":1,"gain":0.8,"pan":0,"frames":0,"error":""}',
		status => '{"ok":true,"state":"listening","channel":1,"frames":2048,"dropped":0,"error":""}',
		stop   => '{"ok":true,"state":"done","frames":2048,"error":""}',
		param  => '{"ok":true,"target":"listen","name":"gain","frames":2048}',
	});
	local $ENV{JAWNOS_AUDIO_SOCKET} = $path;

	my $before = request_count($log);
	my $started = run_take(action => 'listen_start', channel => '1', gain => '0.8', inserts => 'tone');
	is($started->{'status'}, 200, 'listen_start is 200');
	is($started->{'json'}{'state'}, 'listening', 'and relays the engine state');
	is(request_count($log), $before + 1, 'listen_start sends exactly one line');
	my $request = (logged_requests($log))[-1];
	is($request->{'cmd'}, 'listen', 'it is a listen command');
	is($request->{'channel'}, 1, 'the channel is numeric');
	is($request->{'gain'}, 0.8, 'the gain is numeric');
	is($request->{'pan'}, 0, 'pan defaults to zero');
	is_deeply($request->{'inserts'}, ['tone'], 'the insert chain is the take whitelist');
	ok($request->{'system'}, 'the standalone Listen keeps the house mix');

	# The song's rack rides after the strip's pan, in the transport's own shape.
	my $with_rack = run_take(
		action => 'listen_start', channel => '1', gain => '0.8',
		master_json => '["master_limiter"]',
		master_values_json => '[{"name":"master_limiter","control":"bypass","value":1},{"name":"master_limiter","control":"ceiling","value":-3}]',
	);
	is($with_rack->{'status'}, 200, 'a listen with the song rack is 200');
	my $rack = (logged_requests($log))[-1];
	is_deeply($rack->{'master'}, ['master_limiter'], 'the armed rack travels with the listen');
	is_deeply(
		$rack->{'master_values'},
		[
			{ name => 'master_limiter.bypass', value => 1 },
			{ name => 'master_limiter.ceiling', value => -3 },
		],
		'and its footswitch and knobs are the flattened engine shape',
	);

	my $bad_rack = run_take(action => 'listen_start', channel => '1', master_json => '["tone"]');
	is($bad_rack->{'status'}, 400, 'a track pedal in the rack is a 400');
	like($bad_rack->{'json'}{'error'}, qr/no such master insert/, 'and names the rack rule');

	my $monitor = run_take(action => 'listen_start', channel => '1', gain => '0.8', system => '0');
	is($monitor->{'status'}, 200, 'a Monitor listen is 200');
	ok(!(logged_requests($log))[-1]{'system'}, 'and asks the engine for its input alone');
	my $bad_system = run_take(action => 'listen_start', channel => '0', system => 'maybe');
	is($bad_system->{'status'}, 400, 'an unknown system flag is a 400');
	like($bad_system->{'json'}{'error'}, qr/system must be 0 or 1/, 'and names the flag');

	my $mic = run_take(action => 'listen_start', channel => '0', gain => '0.5');
	is($mic->{'status'}, 200, 'channel zero is the microphone');
	is((logged_requests($log))[-1]{'channel'}, 0, 'and travels as zero');

	my $loud = run_take(action => 'listen_start', channel => '0', gain => '9');
	is($loud->{'status'}, 200, 'a gain above the range is accepted');
	is((logged_requests($log))[-1]{'gain'}, 4, 'and clamped to four');
	run_take(action => 'listen_start', channel => '0', gain => '-2');
	is((logged_requests($log))[-1]{'gain'}, 0, 'a negative gain is clamped to zero');
	run_take(action => 'listen_start', channel => '0');
	is((logged_requests($log))[-1]{'gain'}, 0.8, 'a missing gain takes the default');

	my $unchanged = request_count($log);
	for my $channel ('2', '-1', 'mic', '', undef) {
		my $fake = run_take(action => 'listen_start', channel => $channel, gain => '0.5');
		is($fake->{'status'}, 400, 'channel ' . (defined $channel ? "'$channel'" : '(missing)') . ' is a 400');
		like($fake->{'json'}{'error'}, qr/channel must be 0/, 'and names the two inputs');
	}
	for my $bad_gain ('abc', 'NaN', 'Inf', '1e999') {
		my $fake = run_take(action => 'listen_start', channel => '0', gain => $bad_gain);
		is($fake->{'status'}, 400, "gain '$bad_gain' is a 400");
		like($fake->{'json'}{'error'}, qr/gain must be a finite number/, 'and names the rule');
	}
	my $bad_insert = run_take(action => 'listen_start', channel => '0', gain => '0.5', inserts => 'tone,wobble');
	is($bad_insert->{'status'}, 400, 'an unknown insert is a 400');
	like($bad_insert->{'json'}{'error'}, qr/no such insert: wobble/, 'and names the insert');
	is(request_count($log), $unchanged, 'a refused listen never reaches the engine');

	my $stop = run_take(action => 'listen_stop');
	is($stop->{'status'}, 200, 'listen_stop is 200');
	is((logged_requests($log))[-1]{'cmd'}, 'stop', 'and sends stop');

	my $knob = run_take(action => 'param', target => 'listen', name => 'gain', value => '0.25');
	is($knob->{'status'}, 200, 'a listen knob is 200');
	$request = (logged_requests($log))[-1];
	is($request->{'cmd'}, 'param', 'it is a param command');
	is($request->{'target'}, 'listen', 'addressed to listen');
	is($request->{'name'}, 'gain', 'with the knob name');
	is($request->{'value'}, 0.25, 'and a number');
	ok(!exists $request->{'track'}, 'a listen knob carries no track');

	my $effect = run_take(action => 'param', target => 'listen', name => 'delay.mix', value => '0.5');
	is($effect->{'status'}, 200, 'an effect parameter is accepted');

	my $count = request_count($log);
	for my $bad (qw(flanger Gain tonemix '')) {
		my $fake = run_take(action => 'param', target => 'listen', name => $bad, value => '0.5');
		is($fake->{'status'}, 400, "the listen name '$bad' is a 400");
		like($fake->{'json'}{'error'}, qr/no such parameter/, 'and names the parameter');
	}
	for my $bad_value ('NaN', 'Inf', 'x') {
		my $fake = run_take(action => 'param', target => 'listen', name => 'gain', value => $bad_value);
		is($fake->{'status'}, 400, "the listen value '$bad_value' is a 400");
	}
	is(request_count($log), $count, 'a refused listen knob never reaches the engine');

	# The client wrapper is the same one the route relays through.
	my $direct = JawnOS::Audio::Engine::audio_engine_listen(1, 0.4, -0.2, [qw(tone delay)]);
	is($direct->{'ok'}, 1, 'the client wrapper speaks listen');
	my $direct_request = (logged_requests($log))[-1];
	is($direct_request->{'channel'}, 1, 'with the input number');
	is($direct_request->{'gain'}, 0.4, 'and the gain');
	is($direct_request->{'pan'}, -0.2, 'and the pan');
	is_deeply($direct_request->{'inserts'}, [qw(tone delay)], 'and the chain');
	my $direct_off = JawnOS::Audio::Engine::audio_engine_listen(1, 0.4, 0, [], 0);
	is($direct_off->{'ok'}, 1, 'the wrapper can ask for the input alone');
	ok(!(logged_requests($log))[-1]{'system'}, 'and sends system false');
}

# --- no engine is an answer too, and validation happens first ----------------
{
	local $ENV{JAWNOS_AUDIO_SOCKET} = tempdir(CLEANUP => 1) . '/absent.sock';

	my $missing = run_take(action => 'param', track => '0', name => 'gain', value => '1');
	is($missing->{'status'}, 200, 'a missing engine is still a relayed answer');
	is($missing->{'json'}{'error'}, 'the audio engine is not running on this machine',
		'with the client sentence');

	my $bad = run_take(action => 'param', track => '0', name => 'flanger', value => '1');
	is($bad->{'status'}, 400, 'a bad name is refused before the engine is dialled');
	like($bad->{'json'}{'error'}, qr/no such parameter/, 'with the name it refused');
}

# --- the panel's markup -------------------------------------------------------
my $markup = read_file("$root/templates/studio/markup.html.ep");
for my $id (qw(studio_engine_panel studio_engine_start studio_engine_stop
	studio_engine_seconds studio_engine_tracks studio_engine_inputs
	studio_engine_inserts studio_engine_error studio_engine_strips)) {
	like($markup, qr/id="$id"/, "the markup carries #$id");
}
like($markup, qr/id="studio_engine_seconds" value="10"/, 'seconds default to ten');
like($markup, qr/for my \$n \(1 \.\. 8\)/, 'the tracks picker offers one to eight');
like($markup, qr/id="studio_engine_inputs_rows"/, 'the markup carries the per-track picker rows');
like($markup, qr/<input type="hidden" id="studio_engine_inputs">/, 'the old Inputs id survives as a hidden comma list');
like($markup, qr/id="studio_engine_monitor"/, 'and the monitor dropped readout');
like($markup, qr/&subs::ui\('Start take'\)/, 'the Start take button is translatable');
like($markup, qr/&subs::ui\('Stop take'\)/, 'the Stop take button is translatable');
for my $id (qw(studio_listen_toggle studio_listen_input studio_listen_gain
	studio_listen_state studio_listen_input_text studio_listen_frames)) {
	like($markup, qr/id="$id"/, "the markup carries #$id");
}
like($markup, qr/&subs::ui\('Listen'\)/, 'the Listen button is translatable');
like($markup, qr/<option value="0">/, 'the input picker offers channel zero');
like($markup, qr/<option value="1">/, 'and channel one');
like($markup, qr/id="studio_listen_gain"[^>]*min="0"[^>]*max="4"/,
	'the listen gain spans zero to four');

# --- the panel's scripts ------------------------------------------------------
my $studio_js = read_file("$root/public/js/manager/studio.js");
like($studio_js, qr{url: '/manager/studio/take'}, 'the panel posts to the take route');
like($studio_js, qr/action: 'param'/, 'a strip slider sends param');
like($studio_js, qr/action: 'status'/, 'the panel asks for status');
like($studio_js, qr/setInterval\(studioEngineStatus, 750\)/,
	'status is polled every 750 ms while a take records');
like($studio_js, qr/function studioEngineParam\(/, 'the panel has one param sender');
like($studio_js, qr/studioAudioLabel\('Gain'\)/, 'Gain goes through the translation helper');
like($studio_js, qr/typeof jawnosT === 'function'/, 'and that helper is jawnosT');
like($studio_js, qr/studioEngineNumber/,
	'numbers are shown only when the engine reported them');
like($studio_js, qr/function studioEngineInputRow\(/, 'the panel builds one row per engine track');
like($studio_js, qr/studioAudioLabel\('Input'\)/, 'the Input picker options are translatable');
like($studio_js, qr/studioAudioLabel\('Mono'\)/, 'the Source picker offers Mono');
like($studio_js, qr/studioAudioLabel\('Stereo'\)/, 'and Stereo');
like($studio_js, qr/data\.device_channels/, 'the input list follows the engine\'s capture width');
like($studio_js, qr/entry\.channels = \(index < sources\.length/,
	'the track plan sends each device-fed track\'s channels');
like($studio_js, qr/monitor_input:/, 'starting a take sends monitor_input');
like($studio_js, qr/monitor_gain:/, 'and monitor_gain');
like($studio_js, qr/function studioEngineMonitorGain\(/,
	'the transport Monitor has its own input-gain sender');
like($studio_js, qr/target: 'input'/,
	'addressed to the input, not a track');
like($studio_js, qr/studioAudioLabel\('in'\)/, 'a strip names its input and source');
like($studio_js, qr/monitor_dropped/, 'the panel reads the engine\'s monitor_dropped');
like($studio_js, qr/studioAudioLabel\('monitor dropped'\)/, 'as a small readout');

my $controls_js = read_file("$root/public/js/manager/studio/06_controls.js");
my $inputs_js = read_file("$root/public/js/manager/studio/05_inputs.js");
like($controls_js, qr/'#studio_engine_start'/, 'Start take is bound in the controls part');
like($controls_js, qr/'#studio_engine_stop'/, 'Stop take is bound in the controls part');
like($controls_js, qr/'#studio_engine_tracks'/, 'the Tracks select rebuilds the pickers');
like($controls_js, qr/\.studio_engine_input_pick, \.studio_engine_source_pick/,
	'both per-track pickers are bound');
like($controls_js, qr/\.studio_engine_gain, \.studio_engine_pan/,
	'both strip sliders are bound');
like($controls_js, qr/studioEngineParam\(\$\(this\)\.attr\('data-track'\)/,
	'a slider sends its own track');
like($controls_js, qr/'#studio_listen_toggle'/, 'Listen is bound in the controls part');
like($controls_js, qr/'#studio_listen_input'/, 'the input picker is bound');
like($controls_js, qr/'#studio_listen_gain'/, 'the listen gain slider is bound');
like($controls_js, qr/action: 'listen_start'/, 'Listen starts the engine monitor');
like($controls_js, qr/action: 'listen_stop'/, 'and stops it');
like($controls_js, qr/target: 'listen'/, 'the gain is a param addressed to listen');
like($controls_js, qr/setInterval\(studioListenStatus, 750\)/,
	'listen status is polled while it runs');
like($controls_js, qr/function studioListenInserts\(/, 'Listen takes the selected track\'s rack');
like($controls_js, qr/request\.master_json = JSON\.stringify\(master\)/,
	'and the song\'s master rack rides the engine Listen too');
like($controls_js, qr/request\.master_values_json = JSON\.stringify\(values\)/,
	'with its knobs and footswitches');
like($controls_js, qr/inserts: studioListenInserts\(ch\)/, 'and sends the monitored track\'s chain to the monitor');
like($markup, qr/class="studio_track_monitor/, 'every track carries a Monitor button');
like($controls_js, qr/\.studio_track_monitor/, 'the track Monitor buttons are bound');
like($controls_js, qr/function studioSetMonitor/, 'one track is monitored at a time');
like($controls_js, qr/function studioMonitoredChannel/, 'the monitored track is readable');
like($controls_js, qr/setting="monitor"/, 'and drives the monitor setting the config panel owns');
like($controls_js, qr/function studioMonitorButtonRender/, 'one renderer keeps the button and the setting in step');
like($studio_js, qr/var picked = \(typeof studioMonitorBackend === 'function'\)/,
	'a track Monitor honours the Monitor through picker');
like($studio_js, qr/var picked_native = \(picked === 'usb' \|\| picked === 'oboe'\)/,
	'so Direct USB reaches Monitor with no house engine');
like($controls_js, qr/window\.localStorage\.setItem\('jawnos\.studio\.monitor_backend'/,
	'and the chosen path survives a reload');
like($controls_js, qr/if \(studioEngineRecording\) \{[\s\S]*?studioEngineMonitorGain\(on \? 1 : 0\)/,
	'a recording engine take arms or silences the live input from the Monitor button');
unlike($controls_js, qr/studioEngineRecording && studioEngineMonitorArmed/,
	'and no guard blocks arming a take that started with Monitor off');
like($controls_js, qr/studioEngineMonitorArmed === true && studioEngineMonitorLevel > 0/,
	'the button prefers the engine\'s monitor_input while a take records');
like($studio_js, qr/studioEngineMonitorArmed = \(data\.monitor_input === true\)/,
	'the status render stores the engine\'s monitor_input');
like($studio_js, qr/studioEngineMonitorLevel = data\.monitor_gain/,
	'and the gain that says whether the input is armed or silenced');
like($controls_js, qr/!ins\.bypassed && studioEffectBuilder\(ins\.name\)/, 'only enabled, real pedals');
like($markup, qr/Input 1 \(channel 0\)/, 'the input picker names the interface channels');
like($markup, qr/Input 2 \(channel 1\)/, 'both of them');

# --- the help topic speaks in the panel's words ------------------------------
require "$root/perl/help.pl";
my $topic = help::get('studio');
ok(ref $topic eq 'HASH', 'the studio help topic resolves');
my $body = join "\n", @{ $topic->{'body'} || [] };
like($body, qr/Engine take/, 'the topic names the Engine take block');
like($body, qr/Start take/, 'and its Start take control');
like($body, qr/Stop take/, 'and its Stop take control');
like($body, qr/Gain/, 'and the strip knob');
like($body, qr/Pan/, 'and its partner');
like($body, qr/Listen, below those controls, starts live monitoring/, 'help names the Listen control');
like($body, qr/choose Input 1 or Input 2 \(the interface's two channels\)/, 'help names the interface channels');
like($body, qr/selected track's pedals are the monitor's chain/, 'and says the monitor uses the selected rack');
like($body, qr/Only one capture is available/, 'help says listening and recording exclude each other');
like($body, qr/Source picker/, 'help names the per-track Source choice');
like($body, qr/Mono reads that one channel/, 'and what Mono and Stereo read');
like($body, qr/silences or restores the live input it armed/,
	'and what Monitor does during an engine take');
like($body, qr/Pressing Monitor while it records starts the live input from that moment/,
	'and that Monitor arms a take that started without it');
unlike($body, qr/A take started with Monitor off armed no live input/,
	'with the old start-the-next-take wording gone');

like($markup, qr/id="studio_monitor_note"/, 'the transport carries a monitor note');
like($studio_js, qr/function studioApplyMonitor\(from_user, force_tap_device\)/, 'Monitor takes a user flag and the engine-refusal path');
like($studio_js, qr/studioListenStart\(false, listen_channel, active, true\)/, 'a user Monitor starts the engine Listen with the browser fallback');
like($studio_js, qr/studioListenStop\(\)/, 'and switching it off stops it');
like($controls_js, qr/function studioAudioBackend/, 'a native backend is chosen');
like($controls_js, qr/studioAudioBackendMemo = 'oboe'/, 'Oboe wins');
like($controls_js, qr/studioEngineInstalled/, 'then the house engine');
like($controls_js, qr/studioInputReleaseForMonitor/, 'the browser capture is released while a native stream monitors');
like($controls_js, qr/function studioListenStart\(quiet, channel, ch, fallback\)/, 'Listen can start quietly, name its input and rack, and take the browser fallback flag');
like($controls_js, qr/function studioListenNotRunning/, 'and knows the not-running sentence');
like($studio_js, qr/var engine = !!\(device && listen_channel <= 1\s*&& \(picked_native \|\| \(nativeish && !studioMonitorEngineFailed/,
	'a real device on a native backend is the engine Listen while its socket is live');
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
like($studio_js, qr/studioListenStart\(false, listen_channel, active, true\)/,
	'Monitor names the device input and the monitored track, and asks for the fallback');
like($studio_js, qr/else if \(studioListenActive\) \{ studioListenStop\(\); \}/,
	'an app input or no input never starts the engine');
like($inputs_js, qr/function studioChannelInput\(/,
	'the track\'s chosen input is readable from its plug');
like($inputs_js, qr/function studioInputIsApp\(/,
	'an app input is recognised');
like($inputs_js, qr/function studioInputIsDevice\(/,
	'and a real audio device is distinguished from a camera or screen share');
like($inputs_js, qr/function studioInputListenChannel\(/,
	'whose engine input number follows the plug');
like($inputs_js, qr/data\.input = input;/, 'the device number is stored with the plug');
like($controls_js, qr/\$\('#studio_monitor_note'\)\.text\(text\)/, 'listen errors reach the transport note');
like($body, qr/Monitor starts the engine's live Listen/,
	'help says Monitor starts the engine Listen with no take');
like($body, qr/Each track's Monitor button/, 'help says Monitor is per track');
like($body, qr/one track is monitored at a time/, 'and that one input is monitored at a time');
like($body, qr/With no input chosen it is silent and opens no microphone/,
	'help says a track with no input is silent');
like($body, qr/With Synth, Drums, Music or Marker it plays that app/,
	'help says an app input is heard through the browser tap');
like($body, qr/Input 1 is channel 0 and Input 2 is channel 1/,
	'and names the engine input each device number reaches');

like($controls_js, qr/function studioNativeAudio\(/, 'the app bridge is detected on the phone');
like($controls_js, qr/window\.JawnAudioOboe/, 'and named');
like($controls_js, qr/if \(backend === 'oboe' && studioNativeAudio\(\)\) \{ studioNativeStart\(quiet\); return; \}/,
	'Listen prefers the phone\'s native stream when the picker says Oboe');
like($controls_js, qr/if \(backend === 'usb'\) \{ studioUsbListenStart\(/,
	'and the direct USB path when the picker says Direct USB');
like($controls_js, qr/no USB audio interface is attached/,
	'and the picker says why Direct USB is missing rather than looking empty');
like($controls_js, qr/studioMonitorProbeStart\(\);/,
	'opening Configure re-reads the monitor picker, so a late cable appears');
like($controls_js, qr/setInterval\(studioMonitorBackendRender, 2000\)/,
	'and it keeps probing while the sheet is open');
like($controls_js, qr/bridge\.start\(String\(rate\), '192', String\(gain\)\)/,
	'the native stream opens at the house rate, a 4 ms burst and the Listen gain');
like($controls_js, qr/if \(studioNativeListening\) \{ studioNativeStatus\(\); return; \}/,
	'status is read from the native stream while it runs');
like($controls_js, qr/bridge\.stats\(\)/, 'the native facts come from stats()');
like($controls_js, qr/native\.systemVolumeApplied/, 'and say whether the engine or the mixer applied the level');
like($controls_js, qr/bridge\.setGain\(value\)/, 'the gain slider moves the engine gain');
like($controls_js, qr/bridge\.stop\(\)/, 'stopping Listen stops the native stream');
like($studio_js, qr/c\.live\.gain\.value = live \? 1 : 0;/,
	'the live path is silent while the engine Listen owns the device');

done_testing();
