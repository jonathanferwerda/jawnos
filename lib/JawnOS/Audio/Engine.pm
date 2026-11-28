package JawnOS::Audio::Engine;

# The Perl side of the engine's control socket: one JSON object per line, one
# reply, one client at a time (engine/src/socket.rs). This module connects,
# speaks that line and hands back the decoded object; it owns no take, starts
# no process and reads no setting. The route that films a take, the Studio page
# and a later supervisor all share this one client.
#
# The engine is started by whoever owns the box's audio lifecycle, not here.
# Spawning it from a web request would leave a detached daemon behind, owned by
# no worker and killed by no restart; the roadmap's P3 supervisor is the thing
# that will start, watch and stop it. Until then, a missing engine is an answer,
# not a reason to run one.
#
# Every failure is `{ ok => 0, error => "<one sentence>" }`. A caller never has
# to test for undef or catch a die: the route can relay whatever it gets.

use strict;
use warnings;

# Windows has no IO::Socket::UNIX, so it is required only when dialling, the
# same rule lib/JawnOS/Sco/Client.pm follows (t/228 guards it).
use Socket qw(SOCK_STREAM);
use Mojo::JSON qw(decode_json encode_json true false);
use Cwd ();
use File::Basename ();
use File::Spec ();

# Kept as named values so the module and its test agree without repeating a
# literal: five seconds is long enough for a stop that has to join a writer,
# short enough that a hung engine does not hold a worker forever.
our $audio_engine_timeout = 5;
our $audio_engine_not_running = 'the audio engine is not running on this machine';

# `$JAWNOS_AUDIO_SOCKET`, else the engine's own default under the user's data
# dir. The engine reads the same two, so a test and a supervisor can point both
# at one temporary path without a second convention.
sub audio_engine_socket {
	my $override = $ENV{JAWNOS_AUDIO_SOCKET};
	return $override if defined $override && length $override;
	require JawnOS::Platform::Paths;
	my $home = JawnOS::Platform::Paths::home();
	return File::Spec->catfile($home, '.president', 'audio.sock')
		if defined $home && length $home;
	return File::Spec->catfile('.president', 'audio.sock');
}

# `$JAWNOS_AUDIO_PLAN`, else the durable audio state dir (`state_dir/audio`,
# i.e. $XDG_STATE_HOME/jawnos/audio or ~/.local/state/jawnos/audio). This is
# configuration, not run state: `~/.president` is wiped at every boot (jawn),
# so the plan and the picker's pair beside it must live outside it. The
# engine reads the same two names for its startup plan, so a supervisor can
# point both at one temporary path without a second convention.
sub audio_engine_plan_path {
	my $override = $ENV{JAWNOS_AUDIO_PLAN};
	return $override if defined $override && length $override;
	require JawnOS::Platform::Paths;
	return File::Spec->catfile(JawnOS::Platform::Paths::audio_state_dir(), 'audio-plan.json');
}

# Where the old build kept the plan, inside the directory ./jawn wipes. Read
# only by the one-time migration below.
sub audio_engine_plan_legacy_path {
	require JawnOS::Platform::Paths;
	return File::Spec->catfile(JawnOS::Platform::Paths::data_dir(), 'audio-plan.json');
}

# The directory beside the plan: the system-mix state lives here, and the
# supervisor's own status and lock stay under `~/.president` (they are run
# state and belong to the wipe's world). It follows the plan path so a test
# that points JAWNOS_AUDIO_PLAN at a tempdir also points this at it.
sub audio_engine_state_dir {
	my $path = audio_engine_plan_path();
	return File::Basename::dirname($path);
}

# Move the durable pair out of the wipe's reach, once. A plan or mix state
# written by an older build sits next to the run state under `~/.president`;
# the next boot would delete it. A file already at the new path wins, and the
# stale old copy is removed so this runs at most once. An explicit
# JAWNOS_AUDIO_PLAN is a test or a hand-run pin: never migrate a real file into
# it. The caller (./jawn, the supervisor, the manager's boot write) ignores a
# failure; the settings rows rebuild the file anyway.
sub audio_engine_plan_migrate {
	return { ok => 1, migrated => 0, skipped => 'explicit plan path' }
		if defined $ENV{JAWNOS_AUDIO_PLAN} && length $ENV{JAWNOS_AUDIO_PLAN};

	require File::Path;
	my $new_dir = audio_engine_state_dir();
	my $old_dir = audio_engine_plan_legacy_path();
	$old_dir = File::Basename::dirname($old_dir);
	return { ok => 1, migrated => 0 }
		unless defined $old_dir && defined $new_dir && $old_dir ne $new_dir;

	my @moved;
	for my $name ('audio-plan.json', 'audio-system-mix.json') {
		my $old = File::Spec->catfile($old_dir, $name);
		my $new = File::Spec->catfile($new_dir, $name);
		next unless -e $old;
		if (-e $new) {
			unlink $old;
			next;
		}
		eval { File::Path::make_path($new_dir) };
		my $done = rename $old, $new;
		unless ($done) {
			require File::Copy;
			$done = eval { File::Copy::copy($old, $new) && unlink $old };
		}
		push @moved, $name if $done;
	}
	return { ok => 1, migrated => scalar @moved, moved => \@moved, dir => $new_dir };
}

# The staged engine under the tree, resolved from this file rather than from the
# process's working directory: a worker, a probe and a test all run from
# different places. The binary is optional; `available` below is about the
# socket, not this path.
sub audio_engine_binary {
	my $dir = File::Basename::dirname(__FILE__);
	my $root = Cwd::abs_path("$dir/../../..");
	$root = Cwd::abs_path('.') // '.' unless defined $root && length $root;
	return File::Spec->catfile($root, 'perl', 'audio', 'jawn-audio');
}

# A live engine is a socket a connect reaches. A stale socket file left by a
# crash is not available, and `-S` alone would call it one.
sub audio_engine_available {
	my $path = audio_engine_socket();
	return 0 unless defined $path && length $path && -S $path;
	require IO::Socket::UNIX;
	my $socket = eval { IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $path) };
	return 0 unless $socket;
	close $socket;
	return 1;
}

# One request, one reply. The reply is whatever the engine wrote as one JSON
# object; a timeout, a closed connection, an unreadable line and a non-object
# are all reported as the same shape so the route has one thing to relay.
sub audio_engine_command {
	my ($request, $timeout) = @_;
	my $reply = _audio_engine_command_once($request, $timeout);
	return $reply unless ref $reply eq 'HASH'
		&& !$reply->{ok}
		&& ($reply->{error} // '') eq 'a client is already connected';
	# The engine serves one client at a time and refuses a second connection
	# before it reads the line. The command therefore never ran, so one short
	# retry is safe and keeps a poller from losing a turn to the previous
	# client's close.
	select undef, undef, undef, 0.02;
	return _audio_engine_command_once($request, $timeout);
}

sub _audio_engine_command_once {
	my ($request, $timeout) = @_;

	return { ok => 0, error => 'a command needs one request object' }
		unless ref $request eq 'HASH';

	$timeout = $audio_engine_timeout
		unless defined $timeout && $timeout =~ /\A\d+\z/ && $timeout > 0;

	my $path = audio_engine_socket();
	return { ok => 0, error => $audio_engine_not_running }
		unless defined $path && length $path && -S $path;

	require IO::Socket::UNIX;
	my $socket = eval { IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $path) };
	return { ok => 0, error => $audio_engine_not_running } unless $socket;
	$socket->autoflush(1);

	my $line = eval { encode_json($request) };
	unless (defined $line) {
		close $socket;
		return { ok => 0, error => 'the command could not be encoded' };
	}

	my $sent = eval { $socket->print($line . "\n") };
	unless ($sent) {
		close $socket;
		return { ok => 0, error => 'the audio engine closed the connection before the command was sent' };
	}

	# A blocking read bounded by an alarm: the engine answers in microseconds
	# when it is healthy, and a worker must not sit on a wedged one. alarm is a
	# whole number of seconds; five is the default and one is a usable test.
	my $reply;
	my $why = '';
	my $answered = eval {
		local $SIG{ALRM} = sub { die "timeout\n" };
		alarm $timeout;
		local $/ = "\n";
		$reply = <$socket>;
		alarm 0;
		1;
	};
	alarm 0;
	$why = "$@" unless $answered;
	close $socket;

	return { ok => 0, error => 'the audio engine did not answer in time' }
		if $why =~ /\Atimeout/;
	return { ok => 0, error => 'the audio engine connection failed' }
		unless $answered;
	return { ok => 0, error => 'the audio engine closed the connection without an answer' }
		unless defined $reply && length $reply;

	my $decoded = eval { decode_json($reply) };
	return { ok => 0, error => 'the audio engine sent a reply that is not one JSON object' }
		unless ref $decoded eq 'HASH';
	return $decoded;
}

# The commands, in the engine's spelling. Absent values are left out rather
# than sent as null, so the engine's own default is the one that runs.
#
# `$extra` is the optional take plan: `tracks` is either the historical count
# or the engine's per-track array of objects, `inputs` is the parallel channel
# list, `master` is the enabled mastering inserts the take arms, `click` is the
# metronome `{bpm,beats_per_bar,gain}` the engine generates on the monitor
# output (never in the take's WAV), `bus` names one bus of the running patch so
# the take records that mix instead of the capture, and
# `monitor_input`/`monitor_gain` arm the live input on the monitor bus,
# `align_samples` is the capture offset the monitor starts early by, and
# `calibrate` asks the engine to measure that offset with the patch cable. Only
# those keys are forwarded, so a caller cannot turn this into a way to smuggle a
# field the engine never promised; an empty or absent hash keeps the old
# three-argument call exactly as it was. The switches are JSON booleans and go
# out only when they are on; the gain goes out only when it has a number.
sub audio_engine_record {
	my ($out_abs, $seconds, $start_at, $extra) = @_;
	my $request = { cmd => 'record' };
	$request->{'out'} = $out_abs if defined $out_abs;
	$request->{'seconds'} = $seconds if defined $seconds;
	$request->{'start_at'} = $start_at if defined $start_at;
	if (ref $extra eq 'HASH') {
		for my $key (qw(tracks inputs master click bus monitor_track align_samples)) {
			next unless exists $extra->{$key};
			$request->{$key} = $extra->{$key};
		}
		$request->{'monitor_input'} = true if $extra->{'monitor_input'};
		$request->{'calibrate'} = true if $extra->{'calibrate'};
		$request->{'monitor_gain'} = $extra->{'monitor_gain'}
			if defined $extra->{'monitor_gain'};
	}
	return audio_engine_command($request);
}

# One strip knob of a running take: `{"cmd":"param","track":0,"name":"gain",
# "value":0.5}`. The route validates the name and the numbers; this only
# speaks the line, so the engine's clamping and its "no take is running"
# refusal are the answers a caller relays.
#
# A live listen has no track: its knobs are addressed with
# `"target":"listen"`, so the optional fourth argument switches the addressing
# and leaves the three-argument call every existing caller makes alone.
sub audio_engine_param {
	my ($track, $name, $value, $target) = @_;
	my $request = { cmd => 'param', name => $name, value => $value };
	if (defined $target && length $target) {
		$request->{'target'} = $target;
	}
	else {
		$request->{'track'} = $track;
	}
	return audio_engine_command($request);
}

# Live monitoring on one input: `{"cmd":"listen","channel":1,"gain":0.8,
# "pan":0,"inserts":["tone"]}`. The channel is an input number the route has
# already narrowed to 0 (microphone) or 1 (instrument); no device name is
# carried. The optional `master` and `master_values` are the song's rack after
# the strip's pan, in the same shape a transport update uses, so the monitor
# sounds like the playback. The engine answers `state:"listening"`, and `stop`
# ends it.
sub audio_engine_listen {
	my ($channel, $gain, $pan, $inserts, $system, $master, $master_values) = @_;
	my $request = { cmd => 'listen' };
	$request->{'channel'} = $channel if defined $channel;
	$request->{'gain'} = $gain if defined $gain;
	$request->{'pan'} = $pan if defined $pan;
	$request->{'inserts'} = $inserts if ref $inserts eq 'ARRAY';
	$request->{'system'} = $system ? true : false if defined $system;
	$request->{'master'} = $master if ref $master eq 'ARRAY' && @$master;
	$request->{'master_values'} = $master_values
		if ref $master_values eq 'ARRAY' && @$master_values;
	return audio_engine_command($request);
}

# Several inputs monitored at once: `{"cmd":"listen","channels":[0,1],
# "gain":0.8,"pan":0,"inserts":["tone"]}`. The engine builds one strip per
# channel and sums them on the output; the single-input `audio_engine_listen`
# above keeps its historical line and its one-input path. The route validates
# the channel numbers; the engine refuses one the device does not have.
sub audio_engine_listen_channels {
	my ($channels, $gain, $pan, $inserts, $system) = @_;
	my $request = { cmd => 'listen' };
	$request->{'channels'} = $channels if ref $channels eq 'ARRAY';
	$request->{'gain'} = $gain if defined $gain;
	$request->{'pan'} = $pan if defined $pan;
	$request->{'inserts'} = $inserts if ref $inserts eq 'ARRAY';
	$request->{'system'} = $system ? true : false if defined $system;
	return audio_engine_command($request);
}

# The house patchbay: `{"cmd":"patch","plan":{...}}`. The plan is the saved
# object `JawnOS::Audio::Plan` normalises, and the engine compiles it before it
# opens the device. The answer is `state:"patching"` with the plan's shape and
# the nodes this machine cannot bind; a bad plan is the engine's refusal.
#
# `system_device` names this machine's ordinary-audio source (the virtual sink's
# monitor). It rides the command as well as the engine's startup flags, so
# turning the mixer switch on for an engine that started before the switch does
# not need a restart to begin carrying Music and the rest.
sub audio_engine_patch {
	my ($plan, $system_device) = @_;
	return { ok => 0, error => 'a patch needs one plan object' }
		unless ref $plan eq 'HASH';
	my $request = { cmd => 'patch', plan => $plan };
	$request->{'system_device'} = $system_device
		if defined $system_device && !ref $system_device && length $system_device;
	return audio_engine_command($request);
}

# One live fader of the running patch: `{"cmd":"param","target":"patch",
# "route":0,"name":"gain","value":0.5}`. The route number is the 0-based
# index in the plan's `routes` array, and a muted route is refused by the
# engine. The route validates the name and the numbers; this only speaks the
# line, so the engine's clamping and its refusal are the answers a caller
# relays. It is separate from `audio_engine_param`, whose track/listen knobs
# keep their existing callers unchanged.
sub audio_engine_patch_param {
	my ($route, $name, $value) = @_;
	return audio_engine_command({
		cmd => 'param', target => 'patch', route => $route,
		name => $name, value => $value,
	});
}

# One source's trim, footswitch or insert knob of the running patch:
# `{"cmd":"param","target":"patch_source","source":0,
# "name":"distortion.drive","value":75}`. `source` is the 0-based index in
# the plan's `sources` array; `name` is `gain`, `mute` or `<insert>.<control>`.
# The route validates the name and the numbers; the engine refuses a source that
# is not in the plan and an insert the source did not arm, and its answer is
# what a caller relays.
sub audio_engine_patch_source_param {
	my ($source, $name, $value) = @_;
	return audio_engine_command({
		cmd => 'param', target => 'patch_source', source => $source,
		name => $name, value => $value,
	});
}

# The engine's live monitor stream: `{"cmd":"monitor","action":"start",
# "port":0}`. `start` binds a loopback TCP port (0 asks the engine for one) and
# answers the "port" it got; raw interleaved S16LE at 48 kHz stereo arrives on
# that port, taken from the final output after the master rack. `stop` closes
# it and `status` answers its `stream` object. It is the same PCM path the Music
# receiver already plays through `pacat`, so no browser decoder is involved.
sub audio_engine_monitor {
	my ($action, $port) = @_;
	my $request = { cmd => 'monitor', action => $action };
	$request->{'port'} = int($port)
		if defined $port && !ref $port && $port =~ /\A\d+\z/;
	return audio_engine_command($request);
}

# `unpatch` ends the patchbay and nothing else: the mixer switch's off must not
# stop a take or a listen that happens to be sharing the engine.
sub audio_engine_unpatch {
	return audio_engine_command({ cmd => 'unpatch' });
}

sub audio_engine_status {
	return audio_engine_command({ cmd => 'status' });
}

# The engine's transport: `{"cmd":"transport","action":"start",
# "position":0,"bpm":120,"beats_per_bar":4,"gain":0.5,
# "loop_start":0,"loop_end":0,"clips":[...],"master":[...],
# "master_values":[{"name":"master_comp.thresh","value":-18}]}`. Positions
# are seconds on the song timeline. Only the fields the engine promised are
# forwarded, so a caller cannot smuggle another key through this helper;
# `action` is one of `start`, `stop`, `seek`, `update` or `status`, and the
# engine validates every value before a thread or a device exists. `clips` is
# the optional plan of recorded takes (absolute WAV path, timeline start, source
# offset, gain, pan and the rest); `master` is the enabled mastering inserts
# the clip mix runs through; `master_values` is those inserts' live knob
# positions. An absent plan is the click-only clock. `update` replaces the clip
# and master plan of a running transport in place, or moves only the master
# values when `clips` is absent: the device stays open, so a take moved,
# trimmed, split, deleted or added is heard at the next block, and a knob turn
# never re-reads a take.
our @audio_engine_transport_fields = qw(
	position bpm beats_per_bar gain loop_start loop_end clips sends master master_values drums synth_clips
);

sub audio_engine_transport {
	my ($action, $fields) = @_;
	my $request = { cmd => 'transport', action => $action };
	if (ref $fields eq 'HASH') {
		for my $key (@audio_engine_transport_fields) {
			next unless exists $fields->{$key};
			$request->{$key} = $fields->{$key};
		}
	}
	return audio_engine_command($request);
}

# The engine's live voices, carried by the running transport: the Synth app
# hands over its patch once (`patch`), then one key event per note, and the
# drum panel sends a one-shot `hit` so a pad auditions the kit the transport
# will play. Only the promised fields are forwarded; the engine refuses every
# one of them while no transport is playing, because the output is the song's.
our @audio_engine_synth_fields = qw(patch note velocity on routing);
our @audio_engine_drum_fields  = qw(voice velocity);

sub audio_engine_synth {
	my ($action, $fields) = @_;
	my $request = { cmd => 'synth', action => $action };
	if (ref $fields eq 'HASH') {
		for my $key (@audio_engine_synth_fields) {
			next unless exists $fields->{$key};
			$request->{$key} = $fields->{$key};
		}
	}
	return audio_engine_command($request);
}

sub audio_engine_drum_hit {
	my ($fields) = @_;
	my $request = { cmd => 'drums', action => 'hit' };
	if (ref $fields eq 'HASH') {
		for my $key (@audio_engine_drum_fields) {
			next unless exists $fields->{$key};
			$request->{$key} = $fields->{$key};
		}
	}
	return audio_engine_command($request);
}

sub audio_engine_stop {
	return audio_engine_command({ cmd => 'stop' });
}

# Stop one take and nothing else: `{"cmd":"record","action":"stop"}`. A
# take that records beside the engine transport borrowed the transport's one
# output, so the engine detaches its live input and leaves the transport
# playing. The global `stop` above also joins the transport, so it is the wrong
# line for Studio's Stop take.
sub audio_engine_record_stop {
	return audio_engine_command({ cmd => 'record', action => 'stop' });
}

# Stop the live Listen and nothing else: `{"cmd":"listen","action":"stop"}`.
# A listen beside the engine transport rides the transport's output, so this
# detaches only the listen; the transport (and any recording take) keeps
# running. The global `stop` above is the wrong line for Studio's Listen stop.
sub audio_engine_listen_stop {
	return audio_engine_command({ cmd => 'listen', action => 'stop' });
}

sub audio_engine_quit {
	return audio_engine_command({ cmd => 'quit' });
}

1;
