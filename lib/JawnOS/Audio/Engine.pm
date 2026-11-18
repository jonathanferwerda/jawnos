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
use Mojo::JSON qw(decode_json encode_json);
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

# `$JAWNOS_AUDIO_PLAN`, else the engine's own default under the user's data
# dir. The engine reads the same two for its startup plan, so a supervisor can
# point both at one temporary path without a second convention. It mirrors
# `audio_engine_socket` and never shells out.
sub audio_engine_plan_path {
	my $override = $ENV{JAWNOS_AUDIO_PLAN};
	return $override if defined $override && length $override;
	require JawnOS::Platform::Paths;
	my $home = JawnOS::Platform::Paths::home();
	return File::Spec->catfile($home, '.president', 'audio-plan.json')
		if defined $home && length $home;
	return File::Spec->catfile('.president', 'audio-plan.json');
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
# or the engine's per-track array of objects, and `inputs` is the parallel
# channel list. Only those two keys are forwarded, so a caller cannot turn this
# into a way to smuggle a field the engine never promised; an empty or absent
# hash keeps the old three-argument call exactly as it was.
sub audio_engine_record {
	my ($out_abs, $seconds, $start_at, $extra) = @_;
	my $request = { cmd => 'record' };
	$request->{'out'} = $out_abs if defined $out_abs;
	$request->{'seconds'} = $seconds if defined $seconds;
	$request->{'start_at'} = $start_at if defined $start_at;
	if (ref $extra eq 'HASH') {
		for my $key (qw(tracks inputs)) {
			next unless exists $extra->{$key};
			$request->{$key} = $extra->{$key};
		}
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
# carried. The engine answers `state:"listening"`, and `stop` ends it.
sub audio_engine_listen {
	my ($channel, $gain, $pan, $inserts) = @_;
	my $request = { cmd => 'listen' };
	$request->{'channel'} = $channel if defined $channel;
	$request->{'gain'} = $gain if defined $gain;
	$request->{'pan'} = $pan if defined $pan;
	$request->{'inserts'} = $inserts if ref $inserts eq 'ARRAY';
	return audio_engine_command($request);
}

# The house patchbay: `{"cmd":"patch","plan":{...}}`. The plan is the saved
# object `JawnOS::Audio::Plan` normalises, and the engine compiles it before it
# opens the device. The answer is `state:"patching"` with the plan's shape and
# the nodes this machine cannot bind; a bad plan is the engine's refusal.
sub audio_engine_patch {
	my ($plan) = @_;
	return { ok => 0, error => 'a patch needs one plan object' }
		unless ref $plan eq 'HASH';
	return audio_engine_command({ cmd => 'patch', plan => $plan });
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

# `unpatch` ends the patchbay and nothing else: the mixer switch's off must not
# stop a take or a listen that happens to be sharing the engine.
sub audio_engine_unpatch {
	return audio_engine_command({ cmd => 'unpatch' });
}

sub audio_engine_status {
	return audio_engine_command({ cmd => 'status' });
}

sub audio_engine_stop {
	return audio_engine_command({ cmd => 'stop' });
}

sub audio_engine_quit {
	return audio_engine_command({ cmd => 'quit' });
}

1;
