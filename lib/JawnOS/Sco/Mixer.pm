package JawnOS::Sco::Mixer;

# The virtual handset: two null sinks and a remapped microphone that stand in
# for the laptop's speaker and mic while a screened call is up.
#
# The gateway machine is the Hands-Free unit (the phone keeps the call and is
# the Audio Gateway), so the caller arrives on one of the phone's streams and
# our prompt leaves on the other. We do not change the machine's defaults
# (music would land in the call): we move the call's own two streams onto
# devices we own, and leave everything else alone.
#
#   jawn_call_in   - the caller's voice lands here; the gateway captures its
#                    monitor.
#   jawn_prompt    - what the gateway plays here reaches the caller through
#                    jawn_ivr_mic.
#   jawn_ivr_mic   - remap of jawn_prompt.monitor, presented as the "microphone"
#                    the gateway reads.
#
# The card's profile name is not a guide to the direction: a card that reports
# `audio-gateway` still carries the caller's voice as a sink-input and our
# prompt as a source-output, exactly like a `headset-head-unit` card. What
# actually decides who hears the prompt is the HFP role the two ends
# negotiated (the phone must be the AG); if the phone ends up as the HF it
# plays our prompt into its own earpiece and the caller never hears it. That
# is a host setting on the gateway (WirePlumber's `bluez5.roles`), not
# something this mixer can route around.
BEGIN {
	require File::Basename;
	require Cwd;
	my $dir = Cwd::abs_path(File::Basename::dirname(__FILE__));
	unshift @INC, "$dir/../.." if $dir && -d "$dir/../..";
}

use strict;
use warnings;
use Mojo::JSON qw(decode_json);
use JawnOS::Platform::Audio ();

our $SINK_IN = 'jawn_call_in';
our $SINK_OUT = 'jawn_prompt';
our $SOURCE = 'jawn_ivr_mic';

sub new {
	my ($class) = @_;
	return bless {
		loaded => [], moved => [], attached => undef,
		original_sink => '', original_source => '',
	}, $class;
}

sub pactl {
	my (@args) = @_;
	return JawnOS::Platform::Audio::run('pactl', @args);
}

sub module_loaded {
	my ($name) = @_;
	my $mods = &pactl('list', 'short', 'modules');
	return $mods =~ /\bmodule-null-sink\b/ && $mods =~ /\bmodule-remap-source\b/;
}

# Create the pair once. Returns the ids it loaded (kept so a teardown can undo
# them if the house ever wants the devices gone).
sub ensure {
	my ($self) = @_;
	my $sinks = &pactl('list', 'short', 'sinks');
	my @loaded;
	unless ($sinks =~ /\b\Q$SINK_IN\E\b/) {
		my $id = &pactl('load-module', 'module-null-sink', 'sink_name=' . $SINK_IN);
		$id =~ s/\D//g;
		push @loaded, $id if length $id;
	}
	unless ($sinks =~ /\b\Q$SINK_OUT\E\b/) {
		my $id = &pactl('load-module', 'module-null-sink', 'sink_name=' . $SINK_OUT);
		$id =~ s/\D//g;
		push @loaded, $id if length $id;
	}
	my $sources = &pactl('list', 'short', 'sources');
	unless ($sources =~ /\b\Q$SOURCE\E\b/) {
		my $id = &pactl('load-module', 'module-remap-source',
			'master=' . $SINK_OUT . '.monitor', 'source_name=' . $SOURCE);
		$id =~ s/\D//g;
		push @loaded, $id if length $id;
	}
	$self->{'loaded'} = \@loaded if @loaded;
	return scalar @loaded;
}

# The two streams a call owns: the playback of the caller's voice, and the
# capture the phone takes. Matched on the Bluetooth card's address, which is
# the one property that cannot be confused with media playing on the laptop.
sub _blocks {
	my ($text) = @_;
	return grep { /\S/ } split /\n\s*\n/, $text;
}

sub _device_names {
	my ($kind) = @_;
	my %name;
	foreach my $line ( split /\n/, &pactl('list', 'short', $kind) ) {
		my @field = split /\t/, $line;
		$name{ $field[0] } = $field[1] if @field > 1;
	}
	return %name;
}

# Which HFP role the phone's card took does not change the two streams' shape.
# On the gateway machine the caller's voice is always the sink-input (the SCO
# source feeding a sink here) and our prompt is always the source-output (the
# SCO sink taking from one of our sources). The old code trusted the card's
# `Active Profile`, which says `audio-gateway` even when the phone is the AG
# and the direction is the ordinary one - reading it as a cue to swap the two
# broke the prompt and recorded the room.
sub call_streams {
	my ($self, $address) = @_;
	my $want = $address ? lc $address : '';
	# Only a Bluetooth address names the phone's streams. Anything else - the
	# helper reports its transport as "pcm" in pipe mode - used to match every
	# block, because each one contains `Format: pcm`; the mixer then moved our
	# own prompt player into jawn_call_in and our capture onto jawn_ivr_mic, so
	# the "caller" recorded was the greeting (or digital silence).
	return { sink_input => undef, source_output => undef }
		unless $want =~ /^[0-9a-f]{2}(?::[0-9a-f]{2}){5}$/;
	my $spelled = join('[:_]', split /:/, $want);
	my $belongs = sub {
		my ($block) = @_;
		return 0 unless lc($block) =~ /\Q$want\E|$spelled/;
		# never our own helper streams, whatever their saved route says
		return 0 if $block =~ /application\.name = "jawn-sco-/;
		return 1;
	};
	# The HFP stream carries its codec in media.name; prefer it over an A2DP
	# stream that also names the phone's address.
	my $pick = sub {
		my ($kind) = @_;
		my @hit = grep { $belongs->($_) } &_blocks(&pactl('list', $kind));
		my ($block) = grep { /media\.name = ".*\(codec / } @hit;
		return $block || $hit[0];
	};
	my ($sink_name, $source_name);
	my ($sink_input, $source_output, $sink, $source);
	if (my $block = $pick->('sink-inputs')) {
		($sink_input) = $block =~ /Sink Input #(\d+)/;
		my ($id) = $block =~ /^\s*Sink:\s*(\d+)/m;
		if ($id) {
			$sink_name ||= { &_device_names('sinks') };
			$sink = $sink_name->{$id};
		}
	}
	if (my $block = $pick->('source-outputs')) {
		($source_output) = $block =~ /Source Output #(\d+)/;
		my ($id) = $block =~ /^\s*Source:\s*(\d+)/m;
		if ($id) {
			$source_name ||= { &_device_names('sources') };
			$source = $source_name->{$id};
		}
	}
	return {
		sink_input => $sink_input,
		source_output => $source_output,
		sink => $sink,
		source => $source,
	};
}

# The prompt player the helper owns, found by the name it gives its stream.
#
# WirePlumber keeps a target per application name and applies it when a stream
# starts; on this stack the prompt has been seen to land on - or be moved to -
# jawn_call_in mid-greeting, so the caller heard one word and the rest was
# recorded as if the caller had said it. Naming our streams stopped one route
# but not the session manager's own choice, so the sink is re-asserted instead.
sub prompt_stream {
	my ($self) = @_;
	foreach my $block ( &_blocks(&pactl('list', 'sink-inputs')) ) {
		next unless $block =~ /application\.name = "jawn-sco-prompt"/;
		my ($id) = $block =~ /Sink Input #(\d+)/;
		next unless $id;
		my ($sid) = $block =~ /^\s*Sink:\s*(\d+)/m;
		my $sink = $sid ? { &_device_names('sinks') }->{$sid} : undef;
		return { id => $id, sink => $sink };
	}
	return undef;
}

# Our own capture stream, found the way the prompt player is. WirePlumber has
# been seen to restore the saved route for `jawn-sco-caller` onto jawn_ivr_mic,
# which is our own prompt: the "caller" then records the greeting. Nothing else
# re-asserts it, so attach does.
sub caller_stream {
	my ($self) = @_;
	foreach my $block ( &_blocks(&pactl('list', 'source-outputs')) ) {
		next unless $block =~ /application\.name = "jawn-sco-caller"/;
		my ($id) = $block =~ /Source Output #(\d+)/;
		next unless $id;
		my ($sid) = $block =~ /^\s*Source:\s*(\d+)/m;
		my $source = $sid ? { &_device_names('sources') }->{$sid} : undef;
		return { id => $id, source => $source };
	}
	return undef;
}

# Move the call's streams onto our devices - but only the ones that are not
# there already. The caller's voice comes to jawn_call_in, and the phone's
# input reads jawn_ivr_mic.
sub attach {
	my ($self, $address) = @_;
	$self->ensure();
	my $streams = $self->call_streams($address);
	# Remember the phone's own devices before the first move, so a teardown can
	# put the pair back where the phone had it rather than on this machine's
	# default sink/source.
	if (!length $self->{'original_sink'} && defined $streams->{'sink'} && length $streams->{'sink'}
		&& $streams->{'sink'} ne $SINK_IN && $streams->{'sink'} ne $SINK_OUT) {
		$self->{'original_sink'} = $streams->{'sink'};
	}
	if (!length $self->{'original_source'} && defined $streams->{'source'} && length $streams->{'source'}
		&& $streams->{'source'} ne $SOURCE) {
		$self->{'original_source'} = $streams->{'source'};
	}
	my @moved;
	if ($streams->{'sink_input'} && ($streams->{'sink'} // '') ne $SINK_IN) {
		&pactl('move-sink-input', $streams->{'sink_input'}, $SINK_IN);
		push @moved, 'sink-input';
	}
	if ($streams->{'source_output'} && ($streams->{'source'} // '') ne $SOURCE) {
		&pactl('move-source-output', $streams->{'source_output'}, $SOURCE);
		push @moved, 'source-output';
	}
	# The prompt is ours, not the caller's: put it back if it was moved away.
	my $prompt = $self->prompt_stream();
	if ($prompt && ($prompt->{'sink'} // '') ne $SINK_OUT) {
		&pactl('move-sink-input', $prompt->{'id'}, $SINK_OUT);
		push @moved, 'prompt';
	}
	# Our own capture is the other half of the same trap: a saved route can put
	# it on jawn_ivr_mic, where it records the prompt instead of the caller.
	my $caller = $self->caller_stream();
	if ($caller && defined $caller->{'source'} && $caller->{'source'} ne $SINK_IN . '.monitor') {
		&pactl('move-source-output', $caller->{'id'}, $SINK_IN . '.monitor');
		push @moved, 'caller';
	}
	$self->{'attached'} = $streams;
	$self->{'moved'} = \@moved;
	return { ok => (scalar @moved ? 1 : 0), streams => $streams, moved => \@moved };
}

# Put the streams back on this machine's ordinary devices.
sub detach {
	my ($self) = @_;
	my $streams = $self->{'attached'} || {};
	my $sink = $self->{'original_sink'} || &pactl('get-default-sink');
	my $source = $self->{'original_source'} || &pactl('get-default-source');
	$sink =~ s/\s+//g;
	$source =~ s/\s+//g;
	&pactl('move-sink-input', $streams->{'sink_input'}, $sink)
		if $streams->{'sink_input'} && $sink;
	&pactl('move-source-output', $streams->{'source_output'}, $source)
		if $streams->{'source_output'} && $source;
	$self->{'attached'} = undef;
	$self->{'moved'} = [];
	$self->{'original_sink'} = '';
	$self->{'original_source'} = '';
	return 1;
}

# Is the caller actually being played into our sink? A call's two streams
# outlive the call (the phone's gateway profile keeps its nodes), so a listed
# pair is not a call. What is: the sink itself is RUNNING because something is
# feeding it. That is how the gateway tells a live line from the leftovers of
# the last one.
sub call_active {
	my ($self) = @_;
	foreach my $line ( split /\n/, &pactl('list', 'short', 'sinks') ) {
		my @field = split /\t/, $line;
		next unless @field > 4 && $field[1] eq $SINK_IN;
		return $field[4] =~ /^RUNNING$/i ? 1 : 0;
	}
	return 0;
}

# The two commands the audio helper runs.
#
# Both carry a name of their own, never the bare `pacat`/`parec`. WirePlumber
# remembers the last device per application name in stream-properties and
# restores it when the stream starts, so an ordinary `pacat` that once played
# into jawn_call_in during a test was moved off the prompt sink the moment a
# real prompt began: the caller heard one word, the rest of the greeting (and
# the beep) went into jawn_call_in and was recorded as if the caller had said
# it. A named stream has no saved route to inherit, and --device steers it.
sub capture_command {
	my ($self) = @_;
	return join ' ', JawnOS::Platform::Audio::record_argv(
		client => 'jawn-sco-caller', stream => 'jawn-sco-caller',
		rate => 8000, channels => 1, latency => 20,
		device => $SINK_IN . '.monitor');
}

sub playback_command {
	my ($self) = @_;
	return join ' ', JawnOS::Platform::Audio::play_argv(
		client => 'jawn-sco-prompt', stream => 'jawn-sco-prompt',
		rate => 8000, channels => 1, latency => 20,
		volume => &playback_volume() . '%', device => $SINK_OUT);
}

# The launcher's phone channel is a gain on every prompt the call hears. pacat
# takes a stream volume as a percentage, so the 0..1 gain becomes 0..100; a
# machine with no setting row keeps the full 100% today's command carried.
sub playback_volume {
	my $gain = eval { &subs::sound_channel_gain('phone') } // 1;
	my $percent = int($gain * 100 + 0.5);
	$percent = 0 if $percent < 0;
	$percent = 100 if $percent > 100;
	return $percent;
}

# The WebRTC bridge's own pair. A second application name on purpose: the plan's
# helper keeps its streams, and both stay named so WirePlumber has no saved
# route to restore onto the wrong device. 48 kHz because that is what Opus
# speaks; PipeWire resamples the 8 kHz SCO link at the edges.
sub bridge_capture_command {
	my ($self) = @_;
	return join ' ', JawnOS::Platform::Audio::record_argv(
		client => 'jawn-sco-bridge', stream => 'jawn-sco-bridge',
		rate => 48000, channels => 1, latency => 20,
		device => $SINK_IN . '.monitor');
}

sub bridge_playback_command {
	my ($self) = @_;
	return join ' ', JawnOS::Platform::Audio::play_argv(
		client => 'jawn-sco-bridge', stream => 'jawn-sco-bridge',
		rate => 48000, channels => 1, latency => 20,
		volume => &playback_volume() . '%', device => $SINK_OUT);
}

1;
