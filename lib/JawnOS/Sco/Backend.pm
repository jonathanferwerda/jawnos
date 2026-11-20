package JawnOS::Sco::Backend;

# The gateway's audio, behind one seam, so the hierarchy never has to know which
# stack is carrying a call.
#
#   prepare    load this backend's devices / plan
#   attach     bind a call's streams to them, by the phone's Bluetooth address
#   in         how the caller's voice is read
#   out        how the prompt reaches the caller
#   monitor    the recorder's copy, when the backend has one of its own
#   status     is a call actually up
#   release    put the streams back where they were
#
# Two backends exist:
#
#   pactl   wraps JawnOS::Sco::Mixer and the helper's `--pipe` / `--pcm` modes.
#           This is the path the hierarchy ships on, and it stays the fallback.
#   engine  is phase 4b-2. The JawnOS audio engine binds the call's inbound port
#           and carries both PCM directions on two FIFOs beside its socket
#           (`docs/ivr-gateway-engine.md`). The mixer still owns the null sinks
#           and the stream moves, so prepare/attach/release are the same calls;
#           the difference is who carries the PCM.
#
# An engine backend is ready only when the socket answers a status whose
# `gateway.capable` is true and the staged helper was built with `--engine`. A
# machine without an engine socket never claims it; the advert keeps `pipewire`.
#
# This is a seam, not a second implementation: the pactl roles are thin calls
# into Mixer, which still owns the null sinks, the stream moves and the commands
# the helper runs. JawnOS::Sco::Audio is unrelated - it names the recorded
# greeting clips.
#
# new() takes the prerequisites the caller already measured (crew.pl computes
# them once for its advert) so a readiness probe cannot disagree with the advert
# beside it:
#
#   backend => 'pactl' | 'engine'   (pactl unless asked for engine)
#   helper  => 0|1                  ./perl/sco/sco_helper is built
#   helper_path => PATH             that binary, so `--engine` can be checked
#   adapter => 0|1                  a Bluetooth adapter is present
#   pactl   => 0|1                  pactl is on PATH
#
# Any of the three left out is found now.
use strict;
use warnings;

# The engine's one honest answer while its ports cannot carry a call.
our $ENGINE_BLOCKED = 'the engine has no gateway ports yet';
# An engine backend whose socket is not there, or does not answer `capable`.
our $ENGINE_NO_PORTS = 'the engine cannot carry the gateway (it needs parec and pacat)';
# The helper binary with no `--engine` is the other half of the same answer.
our $ENGINE_NO_HELPER = 'the audio helper was not built with engine support';

# `--engine` appears in the helper's usage text; a binary scan is cheap, needs no
# process, and is cached for this process's life.
our %HELPER_ENGINE;

sub new {
	my ($class, %args) = @_;
	my $name = ($args{'backend'} || 'pactl') eq 'engine' ? 'engine' : 'pactl';
	my $self = bless {
		backend => $name,
		helper  => exists $args{'helper'} ? ($args{'helper'} ? 1 : 0)
			: (-x './perl/sco/sco_helper' ? 1 : 0),
		helper_path => $args{'helper_path'} || './perl/sco/sco_helper',
		adapter => exists $args{'adapter'} ? ($args{'adapter'} ? 1 : 0)
			: ((scalar glob('/sys/class/bluetooth/hci*') ? 1 : 0)),
		pactl   => exists $args{'pactl'} ? ($args{'pactl'} ? 1 : 0)
			: (_which('pactl') ? 1 : 0),
		mixer   => $args{'mixer'},
	}, $class;
	return $self;
}

# The seam's own word: `pactl` today, `engine` when one can carry a call.
sub name { return $_[0]->{'backend'} }

# The word the machine advert and the pane show for the audio stack. The pactl
# backend is the PipeWire path the house already runs; an engine backend says so.
sub audio {
	my ($self) = @_;
	return 'engine' if $self->{'backend'} eq 'engine';
	return $self->{'pactl'} ? 'pipewire' : '';
}

# (1) when this machine can carry a gateway call's audio right now, or
# (0, $why) with a reason a person can read. Readiness is the backend's own
# prerequisites, not the machine's load: an idle box with no helper still cannot
# answer a call.
sub ready {
	my ($self) = @_;
	if ($self->{'backend'} eq 'engine') {
		return (0, 'the audio helper is not built') unless $self->{'helper'};
		return (0, $ENGINE_NO_HELPER) unless $self->helper_engine_capable();
		# The engine carries the PCM, not the radio: without an adapter the
		# helper can never take the Hands-Free link, so no port matters.
		return (0, 'no Bluetooth adapter is present') unless $self->{'adapter'};
		my $status = eval {
			require JawnOS::Audio::Engine;
			JawnOS::Audio::Engine::audio_engine_command({ cmd => 'status' }, 1);
		};
		unless (ref $status eq 'HASH' && $status->{'ok'}) {
			my $why = ref $status eq 'HASH' && defined $status->{'error'} && length $status->{'error'}
				? $status->{'error'}
				: 'the audio engine is not running on this machine';
			return (0, $why);
		}
		my $gateway = $status->{'gateway'};
		return (0, $ENGINE_BLOCKED) unless ref $gateway eq 'HASH';
		return (0, $ENGINE_NO_PORTS) unless $gateway->{'capable'};
		return (1);
	}
	return (0, 'the audio helper is not built') unless $self->{'helper'};
	return (0, 'no Bluetooth adapter is present') unless $self->{'adapter'};
	return (0, 'pactl is not installed') unless $self->{'pactl'};
	return (1);
}

# Whether the staged helper speaks `--engine`. The usage text names the flag,
# so one scan of the binary answers without running it. The answer is cached by
# path, mtime and size, so a helper rebuilt in place is re-read rather than
# reported stale for the life of a long-lived manager.
sub helper_engine_capable {
	my ($self) = @_;
	my $path = $self->{'helper_path'};
	return 0 unless defined $path && length $path && -f $path;
	my @stat = stat($path);
	my $key = @stat ? join("\0", $path, $stat[9], $stat[7]) : $path;
	return $HELPER_ENGINE{$key} if exists $HELPER_ENGINE{$key};
	my $found = 0;
	if (open(my $fh, '<', $path)) {
		binmode $fh;
		my $tail = '';
		while (my $read = read($fh, my $chunk, 65536)) {
			my $window = $tail . $chunk;
			if (index($window, '--engine') >= 0) { $found = 1; last }
			# keep enough of the end for a flag split across two reads
			$tail = length($window) > 16 ? substr($window, -16) : $window;
		}
		close $fh;
	}
	$HELPER_ENGINE{$key} = $found;
	return $found;
}

# Load the null sinks/remap the call uses. Returns how many modules it loaded.
# Both backends need them: the engine captures `jawn_call_in.monitor` and plays
# the prompt into `jawn_prompt`, and the mixer still owns both.
sub prepare {
	my ($self) = @_;
	return $self->_mixer->ensure();
}

# Move the call's two streams onto this backend's devices. Both backends answer
# Mixer's hash (ok, streams, moved), which is what the gateway already reads.
sub attach {
	my ($self, $address) = @_;
	return $self->_mixer->attach($address);
}

# The command that reads the caller's voice. The engine has no command: the
# helper opens the FIFOs `gateway bind` named, so this role answers with the one
# honest reason rather than a stream that does not exist.
sub in {
	my ($self) = @_;
	return (0, $ENGINE_NO_PORTS) if $self->{'backend'} eq 'engine';
	return $self->_mixer->capture_command();
}

# The command that plays the prompt to the caller; same split as `in`.
sub out {
	my ($self) = @_;
	return (0, $ENGINE_NO_PORTS) if $self->{'backend'} eq 'engine';
	return $self->_mixer->playback_command();
}

# The copy a recorder hears. Neither backend has a separate bus today: the
# helper's `--tee` FIFO carries the copy, and `monitor:"helper"` in the engine's
# status says so.
sub monitor {
	my ($self) = @_;
	return '';
}

# Is a call up? A listening pair is not a call; the caller sink being RUNNING is
# what Mixer already looks for.
sub status {
	my ($self) = @_;
	return { active => ($self->_mixer->call_active() ? 1 : 0) };
}

# Put the call's streams back on the machine's ordinary devices.
sub release {
	my ($self) = @_;
	return $self->_mixer->detach();
}

# The mixer is lazy: a readiness probe must not load PipeWire, and a test that
# only asks a backend's name must not reach for pactl at all.
sub _mixer {
	my ($self) = @_;
	return $self->{'mixer'} if $self->{'mixer'};
	require JawnOS::Sco::Mixer;
	$self->{'mixer'} = JawnOS::Sco::Mixer->new();
	return $self->{'mixer'};
}

sub _which {
	my ($name) = @_;
	return '' unless defined $name && length $name;
	foreach my $dir ( split /:/, ($ENV{'PATH'} || '') ) {
		next unless length $dir;
		my $path = $dir . '/' . $name;
		return $path if -f $path && -x $path;
	}
	return '';
}

1;
