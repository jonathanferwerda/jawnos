package subs;

# Sound: the machine's audio devices, volume and mute.
#
# The Sound app is the first of the keyboard's panels to become a real app. It
# reads the output and input devices, the default speaker and microphone, and
# the volume/mute of the default output. A write is one fixed command array:
# pactl first, then wpctl, then amixer, and the Android bridge on a phone. No
# request value ever reaches a shell, and a device id is checked against the
# backend's own shape before it is handed to the command.
#
# The Clock's own alarm volume lives in Domain::Pay2 (clock_system_volume_*).
# It is deliberately left alone: the clock's ring ducks and restores the sink
# on its own and must keep working even when this app's view of the default
# device changes.
#
# Loaded on demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;

# The backend is discovered once per worker, like the Clock's mixer probe. A
# machine with no mixer is 'none' rather than an error: the app says so.
our $sound_backend_memo;

# Find a command on PATH without a shell. The returned path is a bare word we
# hand to exec as argv[0], never a string assembled into a command line.
sub sound_which {
	my ($name) = @_;
	return undef unless defined $name && $name =~ /^[A-Za-z0-9_.\-]+$/;
	foreach my $dir (split /:/, ($ENV{'PATH'} || '')) {
		next unless length $dir;
		my $path = "$dir/$name";
		return $path if -f $path && -x _;
	}
	return undef;
}

# Run a fixed argv and return its stdout. The list form of open skips the
# shell, so a device name with a space or a quote is one argument, not code.
sub sound_run {
	my (@cmd) = @_;
	return undef unless @cmd;
	open(my $fh, '-|', @cmd) or return undef;
	local $/;
	my $out = <$fh>;
	close $fh;
	return defined $out ? $out : '';
}

sub sound_mobile {
	return ((&subs::device_setter() || '') eq 'mobile') ? 1 : 0;
}

sub sound_backend {
	return $sound_backend_memo if ref $sound_backend_memo eq 'HASH';
	my $found;

	# A phone answers through the app's audio.volume bridge; a Termux install
	# with a real PulseAudio still falls back to pactl below when it does not.
	if (&sound_mobile()) {
		my $probe = eval { &subs::device_call('audio.volume') };
		$found = { kind => 'android', bin => '' }
			if ref $probe eq 'HASH' && ref $probe->{'streams'} eq 'ARRAY';
	}

	if (!$found) {
		my $pactl = &sound_which('pactl');
		if ($pactl) {
			my $info = &sound_run($pactl, 'info');
			$found = { kind => 'pactl', bin => $pactl }
				if defined $info && $info =~ /Server Name:/;
		}
	}

	if (!$found) {
		my $wpctl = &sound_which('wpctl');
		if ($wpctl) {
			my $status = &sound_run($wpctl, 'status');
			$found = { kind => 'wpctl', bin => $wpctl }
				if defined $status && $status =~ /(?:PipeWire|Audio)/;
		}
	}

	if (!$found) {
		my $amixer = &sound_which('amixer');
		if ($amixer) {
			foreach my $control (qw(Master PCM Speaker)) {
				my $out = &sound_run($amixer, 'sget', $control);
				next unless defined $out && $out =~ /\[(\d+)%\]/;
				$found = { kind => 'amixer', bin => $amixer, control => $control };
				last;
			}
		}
	}

	$sound_backend_memo = $found || { kind => 'none', bin => '' };
	return $sound_backend_memo;
}

# ---- pactl ------------------------------------------------------------------
# `pactl list sinks` gives a block per device: Name, Description, Mute and one
# or more Volume lines. A device's id is its Name, which is what the set- and
# default- verbs take.
sub sound_parse_pactl_devices {
	my ($text, $kind) = @_;
	my $header = $kind eq 'input' ? 'Source' : 'Sink';
	my (@devices, $current);
	foreach my $line (split /\n/, ($text || '')) {
		if ($line =~ /^\s*$header #(\d+)/) {
			$current = { index => $1 + 0, kind => ($kind eq 'input' ? 'source' : 'sink') };
			push @devices, $current;
			next;
		}
		next unless $current;
		if ($line =~ /^\s+Name:\s*(.+?)\s*$/) {
			$current->{'id'} = $1;
		}
		elsif ($line =~ /^\s+Description:\s*(.+?)\s*$/) {
			$current->{'name'} = $1;
		}
		elsif ($line =~ /^\s+Mute:\s*(yes|no)\s*$/i) {
			$current->{'muted'} = lc($1) eq 'yes' ? 1 : 0;
		}
		elsif (!defined $current->{'volume'} && $line =~ /^\s+Volume:.*?(\d+)%/) {
			$current->{'volume'} = $1 + 0;
		}
	}
	@devices = grep { defined $_->{'id'} && length $_->{'id'} } @devices;
	foreach my $device (@devices) {
		$device->{'name'} = $device->{'id'}
			unless defined $device->{'name'} && length $device->{'name'};
		$device->{'volume'} = 0 unless defined $device->{'volume'};
		$device->{'muted'} = 0 unless defined $device->{'muted'};
	}
	return \@devices;
}

# A short listing is the fallback when the long one is unreadable: the name is
# column two and every other column is informational.
sub sound_parse_pactl_short {
	my ($text, $kind) = @_;
	my @devices;
	foreach my $line (split /\n/, ($text || '')) {
		my @field = split /\t/, $line;
		next unless @field >= 2 && length $field[1];
		push @devices, {
			id => $field[1],
			name => $field[1],
			index => $field[0] + 0,
			volume => 0,
			muted => 0,
			kind => ($kind eq 'input' ? 'source' : 'sink'),
		};
	}
	return \@devices;
}

# The default device's own verbs are the authority for its level and mute, even
# when the long listing missed them. Other devices keep what the listing said.
sub sound_pactl_devices {
	my ($bin, $kind) = @_;
	my $type = $kind eq 'input' ? 'sources' : 'sinks';
	my $default = ($kind eq 'input' ? 'get-default-source' : 'get-default-sink');
	my $default_id = '';
	my $default_out = &sound_run($bin, $default);
	$default_id = $1 if defined $default_out && $default_out =~ /^\s*(\S+)/;

	my $long = &sound_run($bin, 'list', $type);
	my $devices = &sound_parse_pactl_devices($long, $kind);
	$devices = &sound_parse_pactl_short(&sound_run($bin, 'list', 'short', $type), $kind)
		unless @{$devices};

	foreach my $device (@{$devices}) {
		$device->{'default'} = ($default_id ne '' && $device->{'id'} eq $default_id) ? 1 : 0;
		next unless $device->{'default'};
		my $vol_verb = $kind eq 'input' ? 'get-source-volume' : 'get-sink-volume';
		my $mute_verb = $kind eq 'input' ? 'get-source-mute' : 'get-sink-mute';
		my $vol = &sound_run($bin, $vol_verb, $device->{'id'});
		$device->{'volume'} = $1 + 0 if defined $vol && $vol =~ /(\d+)%/;
		my $mute = &sound_run($bin, $mute_verb, $device->{'id'});
		$device->{'muted'} = lc($1) eq 'yes' ? 1 : 0
			if defined $mute && $mute =~ /Mute:\s*(yes|no)/i;
	}
	return $devices;
}

# ---- wpctl ------------------------------------------------------------------
# `wpctl status` draws a tree. A device line in the Sinks or Sources section is
# `  *   45. Built-in Audio Analog Stereo [vol: 0.70]`; the star is the default
# and MUTED inside the bracket is the mute state.
sub sound_parse_wpctl {
	my ($text) = @_;
	my (@outputs, @inputs);
	my $section = '';
	foreach my $line (split /\n/, ($text || '')) {
		if ($line =~ /^\s*[^\w]*Sinks:\s*$/) { $section = 'output'; next; }
		if ($line =~ /^\s*[^\w]*Sources:\s*$/) { $section = 'input'; next; }
		if ($line =~ /^\s*[^\w]*(?:Devices|Filters|Streams|Clients|Video|Audio):\s*$/) {
			$section = '';
			next;
		}
		next unless $section;
		next unless $line =~ /^\s*[^\w*]*(\*)?\s*(\d+)\.\s+(.+?)\s+\[vol:\s*([0-9.]+)(\s+MUTED)?\]/i;
		my ($star, $id, $name, $volume, $muted) = ($1, $2, $3, $4, $5);
		my $device = {
			id => $id,
			index => $id + 0,
			name => $name,
			volume => int(($volume * 100) + 0.5),
			muted => (defined $muted && length $muted) ? 1 : 0,
			default => $star ? 1 : 0,
			kind => ($section eq 'input' ? 'source' : 'sink'),
		};
		push @{ $section eq 'input' ? \@inputs : \@outputs }, $device;
	}
	return (\@outputs, \@inputs);
}

# ---- amixer -----------------------------------------------------------------
# One control per direction. The volume is the first percentage in `sget`, and
# `[off]` is the mute switch.
sub sound_amixer_control {
	my ($bin, $control) = @_;
	return undef unless defined $control && $control =~ /^(?:Master|PCM|Speaker|Capture|Mic)$/;
	my $out = &sound_run($bin, 'sget', $control);
	return undef unless defined $out;
	my ($volume) = $out =~ /\[(\d+)%\]/;
	return undef unless defined $volume;
	my ($switch) = $out =~ /\[(on|off)\]/i;
	return {
		id => $control,
		name => $control,
		volume => $volume + 0,
		muted => (defined $switch && lc($switch) eq 'off') ? 1 : 0,
		kind => 'sink',
	};
}

sub sound_amixer_devices {
	my ($bin) = @_;
	my (@outputs, @inputs);
	foreach my $control (qw(Master PCM Speaker)) {
		my $device = &sound_amixer_control($bin, $control);
		next unless $device;
		$device->{'kind'} = 'sink';
		push @outputs, $device;
	}
	foreach my $control (qw(Capture Mic)) {
		my $device = &sound_amixer_control($bin, $control);
		next unless $device;
		$device->{'kind'} = 'source';
		$device->{'name'} = 'Capture' if $control eq 'Capture';
		push @inputs, $device;
	}
	return (\@outputs, \@inputs);
}

# ---- Android ----------------------------------------------------------------
sub sound_android_streams {
	my $answer = eval { &subs::device_call('audio.volume') };
	return undef unless ref $answer eq 'HASH' && ref $answer->{'streams'} eq 'ARRAY';
	return $answer->{'streams'};
}

# The first default device wins; the list keeps the default flag on that row.
sub sound_pick_default {
	my ($devices, $fallback) = @_;
	my $default;
	foreach my $device (@{ $devices || [] }) {
		$device->{'default'} = 0 unless exists $device->{'default'};
		$default = $device if !$default && $device->{'default'};
	}
	$default ||= $fallback;
	$default->{'default'} = 1 if $default;
	return $default;
}

# ---- validation -------------------------------------------------------------
sub sound_kind_normalize {
	my ($kind) = @_;
	return undef unless defined $kind && length $kind;
	$kind = lc $kind;
	return 'output' if $kind =~ /^(?:output|sink|speaker|out)$/;
	return 'input'  if $kind =~ /^(?:input|source|microphone|mic|in)$/;
	return undef;
}

sub sound_volume_valid {
	my ($volume) = @_;
	return 0 unless defined $volume && $volume =~ /^\d+$/;
	return 0 if $volume < 0 || $volume > 100;
	return 1;
}

sub sound_mute_value {
	my ($mute) = @_;
	return 1 if defined $mute && $mute =~ /^(?:1|on|true|yes|mute|muted)$/i;
	return 0 if defined $mute && $mute =~ /^(?:0|off|false|no|unmute|unmuted)$/i;
	return undef;
}

# A pactl name is a single bare word. Anchoring it to a word character also
# keeps a leading '-' from being read as an option by the command.
sub sound_pactl_id_ok {
	my ($id) = @_;
	return 0 unless defined $id && length $id && length $id <= 200;
	return $id =~ /^[A-Za-z0-9][A-Za-z0-9_.:@+\-]*$/ ? 1 : 0;
}

sub sound_wpctl_id_ok {
	my ($id) = @_;
	return 0 unless defined $id;
	return $id =~ /^\d{1,6}$/ ? 1 : 0;
}

sub sound_amixer_id_ok {
	my ($id) = @_;
	return 0 unless defined $id;
	return $id =~ /^(?:Master|PCM|Speaker|Capture|Mic)$/ ? 1 : 0;
}

# ---- the reading ------------------------------------------------------------
sub sound_devices {
	my $backend = &sound_backend();
	my $type = $backend->{'kind'} || 'none';
	my (@outputs, @inputs, $output, $input);
	my $output_mute = 1;
	my $input_mute = 1;
	my $input_supported = 1;

	if ($type eq 'pactl') {
		@outputs = @{ &sound_pactl_devices($backend->{'bin'}, 'output') };
		@inputs  = @{ &sound_pactl_devices($backend->{'bin'}, 'input') };
	}
	elsif ($type eq 'wpctl') {
		my ($out, $in) = &sound_parse_wpctl(&sound_run($backend->{'bin'}, 'status'));
		@outputs = @{$out};
		@inputs  = @{$in};
	}
	elsif ($type eq 'amixer') {
		my ($out, $in) = &sound_amixer_devices($backend->{'bin'});
		@outputs = @{$out};
		@inputs  = @{$in};
	}
	elsif ($type eq 'android') {
		my $streams = &sound_android_streams();
		return {
			ok => 0,
			backend => 'android',
			error => 'the sound bridge did not answer',
			outputs => [],
			inputs => [],
			input_supported => 0,
			output_mute => 0,
			input_mute => 0,
		} unless $streams;
		foreach my $stream (@{$streams}) {
			my $id = $stream->{'stream'};
			next unless defined $id && length $id && $id =~ /^[A-Za-z0-9_]+$/;
			my $max = ($stream->{'max_volume'} || 0) + 0;
			my $level = ($max > 0) ? int(($stream->{'volume'} * 100 / $max) + 0.5) : 0;
			my $device = {
				id => $id,
				name => &subs::format_name($id),
				volume => ($level < 0 ? 0 : ($level > 100 ? 100 : $level)),
				muted => $stream->{'muted'} ? 1 : 0,
				kind => 'sink',
				index => scalar(@outputs),
				default => ($id eq 'music') ? 1 : 0,
				max_volume => $max,
			};
			push @outputs, $device;
		}
		$input_supported = 0;
		$input_mute = 0;
		# The bridge reads the mute state but offers no setter for it.
		$output_mute = 0;
	}

	$output = &sound_pick_default(\@outputs, $outputs[0]);
	$input  = &sound_pick_default(\@inputs, $inputs[0]);

	return {
		ok => 1,
		backend => $type,
		outputs => \@outputs,
		inputs => \@inputs,
		output => $output,
		input => $input,
		output_mute => $output_mute,
		input_mute => $input && $input_supported ? $input_mute : 0,
		input_supported => $input_supported,
	};
}

sub sound_status {
	my $status = &sound_devices();
	my $output = $status->{'output'};
	$status->{'volume'} = $output ? $output->{'volume'} : undef;
	$status->{'muted'} = ($output && $output->{'muted'}) ? 1 : 0;
	$status->{'name'} = $output ? ($output->{'name'} || '') : '';
	return $status;
}

# ---- the writes -------------------------------------------------------------
sub sound_set {
	my ($kind, $id, $volume) = @_;
	$kind = &sound_kind_normalize($kind);
	return { ok => 0, error => 'unknown device kind' } unless $kind;
	return { ok => 0, error => 'volume must be between 0 and 100' }
		unless &sound_volume_valid($volume);
	$volume = int($volume);

	my $backend = &sound_backend();
	my $type = $backend->{'kind'} || 'none';
	return { ok => 0, supported => 0, error => 'no sound backend' } if $type eq 'none';

	my $rc;
	if ($type eq 'pactl') {
		return { ok => 0, error => 'unknown device' } unless &sound_pactl_id_ok($id);
		my $verb = $kind eq 'input' ? 'set-source-volume' : 'set-sink-volume';
		$rc = system($backend->{'bin'}, $verb, $id, $volume . '%');
	}
	elsif ($type eq 'wpctl') {
		return { ok => 0, error => 'unknown device' } unless &sound_wpctl_id_ok($id);
		$rc = system($backend->{'bin'}, 'set-volume', $id, $volume . '%');
	}
	elsif ($type eq 'amixer') {
		return { ok => 0, error => 'unknown device' } unless &sound_amixer_id_ok($id);
		$rc = system($backend->{'bin'}, 'sset', $id, $volume . '%');
	}
	elsif ($type eq 'android') {
		my $streams = &sound_android_streams();
		my ($match) = grep { defined $_->{'stream'} && $_->{'stream'} eq $id } @{ $streams || [] };
		return { ok => 0, error => 'unknown device' } unless $match;
		my $max = ($match->{'max_volume'} || 0) + 0;
		$max = 100 if $max <= 0;
		my $level = int(($volume * $max / 100) + 0.5);
		my $answer = eval { &subs::device_call('audio.volume', { stream => $id, volume => $level }) };
		return { ok => 0, supported => 0, error => 'the sound bridge did not answer' }
			unless ref $answer eq 'HASH';
		$rc = 0;
	}
	else {
		return { ok => 0, supported => 0, error => 'no sound backend' };
	}

	return { ok => 0, error => 'the volume could not be set' } if $rc != 0;
	return { %{ &sound_status() }, ok => 1, changed => { kind => $kind, id => $id, volume => $volume } };
}

sub sound_mute {
	my ($kind, $id, $mute) = @_;
	$kind = &sound_kind_normalize($kind);
	return { ok => 0, error => 'unknown device kind' } unless $kind;
	my $want = &sound_mute_value($mute);
	return { ok => 0, error => 'mute must be on or off' } unless defined $want;

	my $backend = &sound_backend();
	my $type = $backend->{'kind'} || 'none';
	return { ok => 0, supported => 0, error => 'no sound backend' } if $type eq 'none';

	my $rc;
	if ($type eq 'pactl') {
		return { ok => 0, error => 'unknown device' } unless &sound_pactl_id_ok($id);
		my $verb = $kind eq 'input' ? 'set-source-mute' : 'set-sink-mute';
		$rc = system($backend->{'bin'}, $verb, $id, $want ? '1' : '0');
	}
	elsif ($type eq 'wpctl') {
		return { ok => 0, error => 'unknown device' } unless &sound_wpctl_id_ok($id);
		$rc = system($backend->{'bin'}, 'set-mute', $id, $want ? '1' : '0');
	}
	elsif ($type eq 'amixer') {
		return { ok => 0, error => 'unknown device' } unless &sound_amixer_id_ok($id);
		$rc = system($backend->{'bin'}, 'sset', $id, $want ? 'mute' : 'unmute');
	}
	elsif ($type eq 'android') {
		return { ok => 0, supported => 0, error => 'mute is not available on this machine' };
	}
	else {
		return { ok => 0, supported => 0, error => 'no sound backend' };
	}

	return { ok => 0, error => 'the mute state could not be set' } if $rc != 0;
	return { %{ &sound_status() }, ok => 1, changed => { kind => $kind, id => $id, muted => $want } };
}

sub sound_default {
	my ($kind, $id) = @_;
	$kind = &sound_kind_normalize($kind);
	return { ok => 0, error => 'unknown device kind' } unless $kind;

	my $backend = &sound_backend();
	my $type = $backend->{'kind'} || 'none';
	return { ok => 0, supported => 0, error => 'no sound backend' } if $type eq 'none';

	# A default is chosen from the devices the machine just reported, so an id
	# that is not one of them cannot reach the command at all.
	my $status = &sound_devices();
	my $list = $kind eq 'input' ? ($status->{'inputs'} || []) : ($status->{'outputs'} || []);
	my ($match) = grep { defined $_->{'id'} && $_->{'id'} eq $id } @{$list};
	return { ok => 0, error => 'unknown device' } unless $match;

	my $rc;
	if ($type eq 'pactl') {
		return { ok => 0, error => 'unknown device' } unless &sound_pactl_id_ok($id);
		my $verb = $kind eq 'input' ? 'set-default-source' : 'set-default-sink';
		$rc = system($backend->{'bin'}, $verb, $id);
	}
	elsif ($type eq 'wpctl') {
		return { ok => 0, error => 'unknown device' } unless &sound_wpctl_id_ok($id);
		$rc = system($backend->{'bin'}, 'set-default', $id);
	}
	elsif ($type eq 'amixer' || $type eq 'android') {
		return { ok => 0, supported => 0, error => 'choosing a default device is not available on this machine' };
	}
	else {
		return { ok => 0, supported => 0, error => 'no sound backend' };
	}

	return { ok => 0, error => 'the default device could not be set' } if $rc != 0;
	return { %{ &sound_status() }, ok => 1, changed => { kind => $kind, id => $id } };
}

1;
