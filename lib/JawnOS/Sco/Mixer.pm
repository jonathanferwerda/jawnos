package JawnOS::Sco::Mixer;

# The virtual handset: two null sinks and a remapped microphone that stand in
# for the laptop's speaker and mic while a screened call is up.
#
# The Bluetooth gateway profile plays the caller to the default sink and takes
# its input from the default source - which is why the caller heard the room.
# We do not change the defaults (music would land in the call): we move the
# call's own two streams onto devices we own, and leave everything else alone.
#
#   jawn_call_in   - the caller's voice lands here; the gateway captures its
#                    monitor.
#   jawn_prompt    - what the gateway plays here reaches the caller through
#                    jawn_ivr_mic.
#   jawn_ivr_mic   - remap of jawn_prompt.monitor, presented as the "microphone"
#                    the gateway reads.
use strict;
use warnings;
use Mojo::JSON qw(decode_json);

our $SINK_IN = 'jawn_call_in';
our $SINK_OUT = 'jawn_prompt';
our $SOURCE = 'jawn_ivr_mic';

sub new {
	my ($class) = @_;
	return bless { loaded => [], moved => [], attached => undef }, $class;
}

sub pactl {
	my (@args) = @_;
	my $out = '';
	if (open(my $fh, '-|', 'pactl', @args)) {
		local $/;
		$out = <$fh> // '';
		close $fh;
	}
	return $out;
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

# The two streams a call owns, with the device each one is on right now: the id
# alone says nothing about whether it still needs moving, and moving a stream
# that is already ours re-links it and drops a word of the greeting.
sub call_streams {
	my ($self, $address) = @_;
	my $want = $address ? lc $address : '';
	return { sink_input => undef, source_output => undef } unless $want;
	my ($sink_name, $source_name);
	my ($sink_input, $source_output, $sink, $source);
	foreach my $block ( &_blocks(&pactl('list', 'sink-inputs')) ) {
		next unless lc($block) =~ /\Q$want\E/;
		($sink_input) = $block =~ /Sink Input #(\d+)/;
		my ($id) = $block =~ /^\s*Sink:\s*(\d+)/m;
		if ($id) {
			$sink_name ||= { &_device_names('sinks') };
			$sink = $sink_name->{$id};
		}
	}
	foreach my $block ( &_blocks(&pactl('list', 'source-outputs')) ) {
		next unless lc($block) =~ /\Q$want\E/;
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

# Move the call's streams onto our devices - but only the ones that are not
# there already. The caller's voice comes to jawn_call_in, and the phone's
# input reads jawn_ivr_mic.
sub attach {
	my ($self, $address) = @_;
	$self->ensure();
	my $streams = $self->call_streams($address);
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
	$self->{'attached'} = $streams;
	$self->{'moved'} = \@moved;
	return { ok => (scalar @moved ? 1 : 0), streams => $streams, moved => \@moved };
}

# Put the streams back on this machine's ordinary devices.
sub detach {
	my ($self) = @_;
	my $streams = $self->{'attached'} || {};
	my $sink = &pactl('get-default-sink');
	my $source = &pactl('get-default-source');
	$sink =~ s/\s+//g;
	$source =~ s/\s+//g;
	&pactl('move-sink-input', $streams->{'sink_input'}, $sink)
		if $streams->{'sink_input'} && $sink;
	&pactl('move-source-output', $streams->{'source_output'}, $source)
		if $streams->{'source_output'} && $source;
	$self->{'attached'} = undef;
	$self->{'moved'} = [];
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
	return 'parec --client-name=jawn-sco-caller --stream-name=jawn-sco-caller'
		. ' --raw --format=s16le --rate=8000 --channels=1 --latency-msec=20 --device='
		. $SINK_IN . '.monitor';
}

sub playback_command {
	my ($self) = @_;
	return 'pacat --client-name=jawn-sco-prompt --stream-name=jawn-sco-prompt'
		. ' --raw --format=s16le --rate=8000 --channels=1 --latency-msec=20 --playback --device='
		. $SINK_OUT;
}

1;
