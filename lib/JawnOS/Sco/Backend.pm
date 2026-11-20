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
# Two backends exist, and only one of them can carry a call today:
#
#   pactl   wraps JawnOS::Sco::Mixer and the helper's `--pipe` / `--pcm` modes.
#           This is the path the hierarchy ships on.
#   engine  is phase 4b. The JawnOS audio engine is a take/play control socket
#           with no gateway ports: it cannot bind the caller's PipeWire streams,
#           so every role answers not-ready with the same plain reason. It must
#           not pretend otherwise.
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
#   adapter => 0|1                  a Bluetooth adapter is present
#   pactl   => 0|1                  pactl is on PATH
#
# Any of the three left out is found now.
use strict;
use warnings;

# The engine's one honest answer until it gains gateway ports.
our $ENGINE_BLOCKED = 'the engine has no gateway ports yet';

sub new {
	my ($class, %args) = @_;
	my $name = ($args{'backend'} || 'pactl') eq 'engine' ? 'engine' : 'pactl';
	my $self = bless {
		backend => $name,
		helper  => exists $args{'helper'} ? ($args{'helper'} ? 1 : 0)
			: (-x './perl/sco/sco_helper' ? 1 : 0),
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
	return (0, $ENGINE_BLOCKED) if $self->{'backend'} eq 'engine';
	return (0, 'the audio helper is not built') unless $self->{'helper'};
	return (0, 'no Bluetooth adapter is present') unless $self->{'adapter'};
	return (0, 'pactl is not installed') unless $self->{'pactl'};
	return (1);
}

# Load the null sinks/remap the call uses. Returns how many modules it loaded.
sub prepare {
	my ($self) = @_;
	return _blocked() if $self->{'backend'} eq 'engine';
	return $self->_mixer->ensure();
}

# Move the call's two streams onto this backend's devices. The pactl backend
# answers Mixer's hash (ok, streams, moved), which is what the gateway already
# reads.
sub attach {
	my ($self, $address) = @_;
	return _blocked() if $self->{'backend'} eq 'engine';
	return $self->_mixer->attach($address);
}

# The command that reads the caller's voice (pactl: parec/BlueALSA into the
# caller sink's monitor).
sub in {
	my ($self) = @_;
	return _blocked() if $self->{'backend'} eq 'engine';
	return $self->_mixer->capture_command();
}

# The command that plays the prompt to the caller (pactl: pacat into the prompt
# sink).
sub out {
	my ($self) = @_;
	return _blocked() if $self->{'backend'} eq 'engine';
	return $self->_mixer->playback_command();
}

# The copy a recorder hears. The pactl path has no separate bus: the helper's
# `--tee` FIFO carries that copy, and the engine's monitor bus is the phase 4b
# replacement. Empty says exactly that rather than naming a stream that is not
# there.
sub monitor {
	my ($self) = @_;
	return _blocked() if $self->{'backend'} eq 'engine';
	return '';
}

# Is a call up? A listening pair is not a call; the caller sink being RUNNING is
# what Mixer already looks for.
sub status {
	my ($self) = @_;
	return _blocked() if $self->{'backend'} eq 'engine';
	return { active => ($self->_mixer->call_active() ? 1 : 0) };
}

# Put the call's streams back on the machine's ordinary devices.
sub release {
	my ($self) = @_;
	return _blocked() if $self->{'backend'} eq 'engine';
	return $self->_mixer->detach();
}

sub _blocked { return (0, $ENGINE_BLOCKED) }

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
