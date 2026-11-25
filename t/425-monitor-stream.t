# tests-for: lib/JawnOS/Controller/manager_misc9.pm lib/JawnOS/Routes/manager_misc9.pm lib/JawnOS/Audio/Engine.pm engine/src/socket.rs engine/src/stream.rs perl/Music/02_remote_audio_stream.pl engine/src/main.rs
# covers:    The controller's Studio monitor stream: the route relays through the
#            signed peer rail, the target resolves the controller from the
#            verified peer row, starts the engine's final-output tap and a Music
#            source to that machine, and forwards the PCM blocks the Music
#            receiver already plays. A physical output stays on remote_device.

use strict;
use warnings;

use FindBin;
use Test::More;
use File::Slurp qw(read_file);
use Cwd qw(abs_path);

my $root = abs_path("$FindBin::Bin/..");
my $controller = read_file("$root/lib/JawnOS/Controller/manager_misc9.pm");
my $routes     = read_file("$root/lib/JawnOS/Routes/manager_misc9.pm");
my $engine     = read_file("$root/lib/JawnOS/Audio/Engine.pm");
my $socket     = read_file("$root/engine/src/socket.rs");
my $stream     = read_file("$root/engine/src/stream.rs");
my $patchbay   = read_file("$root/engine/src/patchbay.rs");
my $library    = read_file("$root/engine/src/lib.rs");
my $main       = read_file("$root/engine/src/main.rs");
my $music      = read_file("$root/perl/Music/02_remote_audio_stream.pl");

# --- the route and its action ------------------------------------------------
like($routes, qr/\[\s*44044\s*,\s*'post'\s*,\s*'\/manager\/studio\/monitor_stream'\s*,\s*'action_44044'\s*\]/,
	'POST /manager/studio/monitor_stream is registered with its action');
like($controller, qr/^\s*sub\s+action_44044\b/m, 'the controller defines action_44044');

# --- the controller relay ----------------------------------------------------
like($controller, qr/sub studio_monitor_controller/, 'one helper resolves the controller');
like($controller, qr/\$c->stash\('peer_verified_key'\)/, 'from the verified peer key');
like($controller, qr/remote_machine_lister\(\{ self => 'no', connection => 'active' \}\)/,
	'against the active peers');
like($controller, qr/\$_->\{'connection'\}.*eq 'active'/, 'an inactive peer is not a controller');
like($controller, qr/\$_->\{'device'\}.*ne 'server'/, 'a server has no receiver');
like($controller, qr/studio_remote_relay\(\$c\)/, 'a controller request uses the existing relay');
like($controller, qr/\$c->param\('remote_uuid' => \$peer->\{'uuid'\}\)/, 'naming the checked peer');
like($controller, qr/the controller machine is not an active peer/, 'and an inactive one is refused');

# --- the target's engine tap and Music source --------------------------------
like($engine, qr/sub audio_engine_monitor/, 'the engine client has one monitor helper');
like($engine, qr/cmd => 'monitor', action => \$action/, 'speaking the monitor command');
like($controller, qr/audio_engine_monitor\('start', 0\)/, 'the target starts the tap on a free port');
like($controller, qr/audio_engine_monitor\('stop'\)/, 'and stops it with the stream');
like($controller, qr/rate => 48000/, 'the source hello names 48 kHz');
like($controller, qr/codec => 'pcm'/, 'raw PCM');
like($controller, qr/name => 'studio-monitor'/, 'and a stable name');
like($controller, qr/type => 'audio'/, 'typed as audio, not video');
like($controller, qr/music_source_client_open\(\$c, \$source, \$key, 'stereo'\)/,
	'it opens the existing Music source client');
like($controller, qr/music_source_broadcast_binary\(\$source, \$chunk\)/,
	'and forwards each block to it');
like($music, qr/sub music_source_broadcast_binary/, 'the Music side has the binary forward');
like($music, qr/send\(\{binary => \$bytes\}\)/, 'which sends the PCM unchanged');

# --- the stream's lifecycle --------------------------------------------------
like($controller, qr/IO::Socket::INET->new/, 'the manager dials the loopback port');
like($controller, qr/studio_monitor_watch_start/, 'a watch catches a controller leaving');
like($controller, qr/on\(close => sub \{[\s\S]{0,160}studio_monitor_stream_stop/,
	'a closed engine socket ends the stream only after a real stop');
like($controller, qr/the controller stopped listening/, 'and a silent link is named');
like($controller, qr/the engine stream ended/, 'and a real engine stop or shutdown is named');

# --- the two modes are exclusive and the answer has one shape ----------------
like($controller, qr/a physical output is chosen with \/manager\/studio\/remote_device/,
	'a physical output points at the existing route');
like($controller, qr/studio_monitor_stream_stop\(undef, 1\) if \$ok/,
	'choosing a physical output ends any stream, so the modes stay exclusive');
like($controller, qr/ok => \$ok \? 1 : 0,\s*\n\s*streaming => \$streaming \? 1 : 0,/,
	'the reply leads with ok and streaming');
like($controller, qr/output => .*stream/, 'names the stream output');
like($controller, qr/at => &subs::rightNow\(\)/, 'and carries a timestamp');
like($controller, qr/error => defined \$error \? \$error : ''/, 'with one error key');

# --- the engine side ---------------------------------------------------------
like($socket, qr/"monitor" => Action::Reply\(self\.monitor_command/, 'the socket dispatches monitor');
like($socket, qr/fn monitor_command/, 'with one handler');
like($socket, qr/self\.monitor\.control\(\)\.start\(port\)/, 'start binds the requested port');
like($socket, qr/jawn_audio::stream::TapSource::new\(source, monitor\.producer\(\)\)/,
	'the transport is wrapped in the final-output tap');
unlike($socket, qr/monitor\.stop\(\)/, 'the transport ending no longer stops the stream');
like($socket, qr/attach_monitor\(self\.monitor\.control\(\)\.producer\(\)\)/,
	'the house patch feeds the same monitor ring');
like($patchbay, qr/pub fn attach_monitor/, 'the patchbay takes the monitor producer');
like($patchbay, qr/producer\.push\(&self\.mix\[\.\.stereo\]\)/,
	'and pushes its final mix into the ring');
like($socket, qr/fn add_monitor/, 'status gains a monitor fragment');
like($socket, qr/\\"streaming\\":/, 'the top-level streaming flag');
like($socket, qr/\\"stream\\":/, 'and the stream object');
like($stream, qr/pub struct MonitorTap/, 'the tap owns a writer thread');
like($stream, qr/pub struct TapSource/, 'and a render-source adapter');
like($stream, qr/127\.0\.0\.1/, 'the listener is loopback only');
like($stream, qr/MONITOR_RATE: u32 = 48_000/, 'the stream is 48 kHz');
like($stream, qr/MONITOR_CHANNELS: usize = 2/, 'and stereo');
like($stream, qr/self\.inner\.block\(out\)\?;[\s\S]{0,240}push\(out\)/,
	'the tap runs after the source rendered');
like($stream, qr/to_i16/, 'and converts to S16');
like($stream, qr/to_le_bytes/, 'little-endian');
like($stream, qr/set_write_timeout/, 'a stalled controller is dropped');
like($library, qr/pub mod stream/, 'the module is part of the crate');
like($main, qr/cmd\\":\\"monitor/, 'the --help names the monitor command');

# --- the action refuses what it cannot do without booting the app ------------
{
	package subs;
	no warnings 'redefine';
	sub rightNow { 1_700_000_000_000 }
	sub remote_machine_lister { return [] }

	package FakeMonitorRequest;
	sub new { my ($class, %args) = @_; return bless { body => ($args{'body'} // '') }, $class }
	sub body { return $_[0]->{'body'} }
	sub json { return undef }

	package FakeMonitorController;
	sub new { my ($class, %args) = @_; return bless { %args }, $class }
	sub param { my ($self, $name) = @_; return $self->{'params'}->{$name} }
	sub req { return $_[0]->{'req'} }
	sub stash {
		my ($self, $name) = @_;
		return $name ? $self->{'stash'}->{$name} : $self->{'stash'};
	}
	sub render {
		my ($self, %args) = @_;
		$self->{'status'} = $args{'status'};
		$self->{'json'} = $args{'json'};
		return;
	}

	package main;
}

require "$root/lib/JawnOS/Controller/manager_misc9.pm";

{
	my $c = FakeMonitorController->new(
		params => { action => 'play', output => 'stream' },
		req => FakeMonitorRequest->new,
		stash => {},
	);
	Manager::action_44044($c);
	is($c->{'status'}, 400, 'an unknown monitor action is a 400');
	is($c->{'json'}{'ok'}, 0, 'and not ok');
	is($c->{'json'}{'streaming'}, 0, 'and not streaming');
	is($c->{'json'}{'output'}, 'stream', 'the output keeps its name');
	like($c->{'json'}{'error'}, qr/start, stop or status/, 'with the choices');
}

{
	my $c = FakeMonitorController->new(
		params => { action => 'start', output => 'alsa_output.pci', remoted => 'yes' },
		req => FakeMonitorRequest->new,
		stash => {},
	);
	Manager::action_44044($c);
	is($c->{'status'}, 400, 'a physical output is refused here');
	like($c->{'json'}{'error'}, qr/remote_device/, 'and points at the physical-output route');
}

{
	my $c = FakeMonitorController->new(
		params => { action => 'start', output => 'stream', remoted => 'yes' },
		req => FakeMonitorRequest->new,
		stash => {},
	);
	Manager::action_44044($c);
	is($c->{'status'}, 409, 'a start with no verified controller is refused');
	like($c->{'json'}{'error'}, qr/not an active peer/, 'naming the reason');
}

done_testing();
