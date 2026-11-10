package JawnOS::Platform::Audio;

# The machine's sound behind one interface: which backend is present, the
# device lists and their volume/mute, the default device, the sink-input
# report, and the exact argv a player, a recorder or a local file player runs.
#
# Linux keeps the order the domain code had: pactl (PulseAudio, or PipeWire's
# pulse shim), then wpctl, then amixer. Every command is an argument list
# resolved through JawnOS::Platform::tool_path, never a string handed to a
# shell. A machine with no mixer answers ''/undef/[] and a write answers 0, so
# a caller's own fallback runs unchanged.
#
# macOS (CoreAudio) and Windows (WASAPI) backends are the P2/P3 landings
# (docs/platform-roadmap.md). Until they exist, those systems get the same
# empty answers this file gives a Linux box with no mixer.
#
# The parsers are exported so fixtures can pin the formats: `pactl list sinks`
# blocks, `pactl list short`, `pactl -f json list sink-inputs`, `wpctl status`
# (the starred default and MUTED), and `amixer sget`.

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(
	which run info start_pulse
	backend reset_backend devices
	pactl_devices parse_pactl_devices parse_pactl_short
	parse_wpctl amixer_control amixer_devices
	get_volume set_volume get_mute set_mute
	default set_default
	stream_inputs set_stream_input_volume set_stream_input_mute
	play_argv record_argv player_argv speak_argv
);

BEGIN {
	require File::Basename;
	require Cwd;
	my $dir = Cwd::abs_path(File::Basename::dirname(__FILE__));
	unshift @INC, "$dir/../.." if $dir && -d "$dir/../..";
}
use JawnOS::Platform ();
use File::Spec ();

# Discovered once per worker: a machine's mixer does not appear or disappear
# while the process lives. reset_backend() is for a test that changes PATH.
our $backend_memo;

sub reset_backend {
	$backend_memo = undef;
	return;
}

# The resolved path of a tool, or undef. JawnOS::Platform::tool_path reads
# File::Spec->path, which is the same PATH a `command -v` would search.
sub which {
	my ($name) = @_;
	return undef unless defined $name && length $name;
	return JawnOS::Platform::tool_path($name);
}

sub _exec {
	my ($bin, @args) = @_;
	return '' unless defined $bin && length $bin;
	open(my $fh, '-|', $bin, @args) or return '';
	local $/;
	my $out = <$fh>;
	close $fh;
	return defined $out ? $out : '';
}

# Run a tool by name and return its stdout. A missing tool answers '' (what the
# old backticks did), and no argument ever passes through a shell.
sub run {
	my ($tool, @args) = @_;
	return '' unless defined $tool && length $tool;
	my $bin = which($tool) or return '';
	return _exec($bin, @args);
}

# `pactl info`, read for a running server. Stdout is enough for every check the
# callers made; a server that is down prints to stderr and answers ''.
sub info {
	return run('pactl', 'info');
}

# Start a Termux PulseAudio daemon left down by a reboot, with both streams on
# /dev/null the way the old shell redirection did. Returns 1 when the tool
# exists and was waited for, 0 when there is nothing to start.
sub start_pulse {
	return 0 if $^O eq 'MSWin32';
	my $bin = which('pulseaudio') or return 0;
	my $pid = fork();
	return 0 unless defined $pid;
	if (!$pid) {
		open(STDOUT, '>', File::Spec->devnull());
		open(STDERR, '>&', \*STDOUT);
		exec $bin, '--start', '--exit-idle-time=-1';
		exit 127;
	}
	waitpid($pid, 0);
	return 1;
}

# ---- the backend ------------------------------------------------------------
# pactl first, then wpctl, then amixer. The probe text is what the domain code
# matched before: `Server Name:` from pactl info, PipeWire/Audio from wpctl
# status, and a `[NN%]` from one of amixer's playback controls.
sub backend {
	return $backend_memo if ref $backend_memo eq 'HASH';
	my $found;

	my $pactl = which('pactl');
	if ($pactl) {
		my $out = _exec($pactl, 'info');
		$found = { kind => 'pactl', bin => $pactl } if $out =~ /Server Name:/;
	}

	if (!$found) {
		my $wpctl = which('wpctl');
		if ($wpctl) {
			my $out = _exec($wpctl, 'status');
			$found = { kind => 'wpctl', bin => $wpctl } if $out =~ /(?:PipeWire|Audio)/;
		}
	}

	if (!$found) {
		my $amixer = which('amixer');
		if ($amixer) {
			foreach my $control ('Master', 'PCM', 'Speaker', 'Master Playback Volume') {
				my $out = _exec($amixer, 'sget', $control);
				next unless defined $out && $out =~ /\[(\d+)%\]/;
				$found = { kind => 'amixer', bin => $amixer, control => $control };
				last;
			}
		}
	}

	$backend_memo = $found || { kind => 'none', bin => '' };
	return $backend_memo;
}

sub _kind {
	my ($kind) = @_;
	return 'input' if defined $kind && $kind =~ /^(?:input|source|microphone|mic|in)$/i;
	return 'output';
}

# ---- pactl parsing ----------------------------------------------------------
# `pactl list sinks` gives a block per device: Name, Description, Mute and one
# or more Volume lines. A device's id is its Name, which is what the set- and
# default- verbs take.
sub parse_pactl_devices {
	my ($text, $kind) = @_;
	$kind = _kind($kind);
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
sub parse_pactl_short {
	my ($text, $kind) = @_;
	$kind = _kind($kind);
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
sub pactl_devices {
	my ($bin, $kind) = @_;
	$kind = _kind($kind);
	return [] unless defined $bin && length $bin;
	my $type = $kind eq 'input' ? 'sources' : 'sinks';
	my $default_verb = $kind eq 'input' ? 'get-default-source' : 'get-default-sink';
	my $default_id = '';
	my $default_out = _exec($bin, $default_verb);
	$default_id = $1 if defined $default_out && $default_out =~ /^\s*(\S+)/;

	my $devices = parse_pactl_devices(_exec($bin, 'list', $type), $kind);
	$devices = parse_pactl_short(_exec($bin, 'list', 'short', $type), $kind)
		unless @{$devices};

	foreach my $device (@{$devices}) {
		$device->{'default'} = ($default_id ne '' && $device->{'id'} eq $default_id) ? 1 : 0;
		next unless $device->{'default'};
		my $vol_verb = $kind eq 'input' ? 'get-source-volume' : 'get-sink-volume';
		my $mute_verb = $kind eq 'input' ? 'get-source-mute' : 'get-sink-mute';
		my $vol = _exec($bin, $vol_verb, $device->{'id'});
		$device->{'volume'} = $1 + 0 if defined $vol && $vol =~ /(\d+)%/;
		my $mute = _exec($bin, $mute_verb, $device->{'id'});
		$device->{'muted'} = lc($1) eq 'yes' ? 1 : 0
			if defined $mute && $mute =~ /Mute:\s*(yes|no)/i;
	}
	return $devices;
}

# ---- wpctl parsing ----------------------------------------------------------
# `wpctl status` draws a tree. A device line in the Sinks or Sources section is
# `  *   45. Built-in Audio Analog Stereo [vol: 0.70]`; the star is the default
# and MUTED inside the bracket is the mute state.
sub parse_wpctl {
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
sub amixer_control {
	my ($bin, $control) = @_;
	return undef unless defined $control && $control =~ /^(?:Master Playback Volume|Master|PCM|Speaker|Capture|Mic)$/;
	return undef unless defined $bin && length $bin;
	my $out = _exec($bin, 'sget', $control);
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

sub amixer_devices {
	my ($bin) = @_;
	my (@outputs, @inputs);
	foreach my $control ('Master', 'PCM', 'Speaker', 'Master Playback Volume') {
		my $device = amixer_control($bin, $control);
		next unless $device;
		$device->{'kind'} = 'sink';
		push @outputs, $device;
	}
	foreach my $control (qw(Capture Mic)) {
		my $device = amixer_control($bin, $control);
		next unless $device;
		$device->{'kind'} = 'source';
		$device->{'name'} = 'Capture' if $control eq 'Capture';
		push @inputs, $device;
	}
	return (\@outputs, \@inputs);
}

# The device list for one direction on the platform's backend. A phone's bridge
# and the Android-specific fields stay in Domain::Sound, which owns that shape.
sub devices {
	my ($kind) = @_;
	$kind = _kind($kind);
	my $backend = backend();
	my $type = $backend->{'kind'} || 'none';
	return [] unless $type eq 'pactl' || $type eq 'wpctl' || $type eq 'amixer';
	if ($type eq 'pactl') {
		return pactl_devices($backend->{'bin'}, $kind);
	}
	if ($type eq 'wpctl') {
		my ($outputs, $inputs) = parse_wpctl(_exec($backend->{'bin'}, 'status'));
		return $kind eq 'input' ? $inputs : $outputs;
	}
	my ($outputs, $inputs) = amixer_devices($backend->{'bin'});
	return $kind eq 'input' ? $inputs : $outputs;
}

# ---- validation -------------------------------------------------------------
sub _pactl_id_ok {
	my ($id) = @_;
	return 1 if defined $id && $id =~ /^\@DEFAULT_(?:AUDIO_)?(?:SINK|SOURCE)\@$/;
	return 0 unless defined $id && length $id && length $id <= 200;
	return $id =~ /^[A-Za-z0-9][A-Za-z0-9_.:@+\-]*$/ ? 1 : 0;
}

sub _wpctl_id_ok {
	my ($id) = @_;
	return 1 if defined $id && $id =~ /^\@DEFAULT_AUDIO_(?:SINK|SOURCE)\@$/;
	return 0 unless defined $id;
	return $id =~ /^\d{1,6}$/ ? 1 : 0;
}

sub _amixer_id_ok {
	my ($id) = @_;
	return 0 unless defined $id;
	return $id =~ /^(?:Master Playback Volume|Master|PCM|Speaker|Capture|Mic)$/ ? 1 : 0;
}

# The id a default-device read or write uses. PulseAudio and WirePlumber each
# spell their default sink/source as a sentinel; amixer's whole answer is one
# control per direction.
sub _default_id {
	my ($backend, $kind) = @_;
	my $type = $backend->{'kind'} || 'none';
	if ($type eq 'pactl') {
		return $kind eq 'input' ? '@DEFAULT_SOURCE@' : '@DEFAULT_SINK@';
	}
	if ($type eq 'wpctl') {
		return $kind eq 'input' ? '@DEFAULT_AUDIO_SOURCE@' : '@DEFAULT_AUDIO_SINK@';
	}
	if ($type eq 'amixer') {
		return $kind eq 'input' ? 'Capture' : ($backend->{'control'} || 'Master');
	}
	return '';
}

# ---- reads and writes -------------------------------------------------------
sub get_volume {
	my ($kind, $id) = @_;
	$kind = _kind($kind);
	my $backend = backend();
	my $type = $backend->{'kind'} || 'none';
	$id = _default_id($backend, $kind) unless defined $id && length $id;
	if ($type eq 'pactl') {
		return undef unless _pactl_id_ok($id);
		my $verb = $kind eq 'input' ? 'get-source-volume' : 'get-sink-volume';
		my $out = _exec($backend->{'bin'}, $verb, $id);
		return int($1) if defined $out && $out =~ /(\d+)%/;
		return undef;
	}
	if ($type eq 'wpctl') {
		return undef unless _wpctl_id_ok($id);
		my $out = _exec($backend->{'bin'}, 'get-volume', $id);
		return int(($1 * 100) + 0.5) if defined $out && $out =~ /Volume:\s*([0-9.]+)/;
		return undef;
	}
	if ($type eq 'amixer') {
		return undef unless _amixer_id_ok($id);
		my $out = _exec($backend->{'bin'}, 'sget', $id);
		return int($1) if defined $out && $out =~ /\[(\d+)%\]/;
		return undef;
	}
	return undef;
}

sub get_mute {
	my ($kind, $id) = @_;
	$kind = _kind($kind);
	my $backend = backend();
	my $type = $backend->{'kind'} || 'none';
	$id = _default_id($backend, $kind) unless defined $id && length $id;
	if ($type eq 'pactl') {
		return undef unless _pactl_id_ok($id);
		my $verb = $kind eq 'input' ? 'get-source-mute' : 'get-sink-mute';
		my $out = _exec($backend->{'bin'}, $verb, $id);
		return lc($1) eq 'yes' ? 1 : 0 if defined $out && $out =~ /Mute:\s*(yes|no)/i;
		return undef;
	}
	if ($type eq 'wpctl') {
		return undef unless _wpctl_id_ok($id);
		my $out = _exec($backend->{'bin'}, 'get-volume', $id);
		return undef unless defined $out && $out =~ /Volume:\s*[0-9.]+/;
		return $out =~ /MUTED/ ? 1 : 0;
	}
	if ($type eq 'amixer') {
		return undef unless _amixer_id_ok($id);
		my $out = _exec($backend->{'bin'}, 'sget', $id);
		return undef unless defined $out && $out =~ /\[(?:on|off)\]/i;
		return $out =~ /\[off\]/i ? 1 : 0;
	}
	return undef;
}

sub set_volume {
	my ($kind, $id, $pct) = @_;
	return undef unless defined $pct && $pct =~ /^\d+$/;
	$kind = _kind($kind);
	my $backend = backend();
	my $type = $backend->{'kind'} || 'none';
	$id = _default_id($backend, $kind) unless defined $id && length $id;
	my @cmd;
	if ($type eq 'pactl') {
		return 0 unless _pactl_id_ok($id);
		my $verb = $kind eq 'input' ? 'set-source-volume' : 'set-sink-volume';
		@cmd = ($backend->{'bin'}, $verb, $id, $pct . '%');
	}
	elsif ($type eq 'wpctl') {
		return 0 unless _wpctl_id_ok($id);
		@cmd = ($backend->{'bin'}, 'set-volume', $id, $pct . '%');
	}
	elsif ($type eq 'amixer') {
		return 0 unless _amixer_id_ok($id);
		@cmd = ($backend->{'bin'}, 'sset', $id, $pct . '%');
	}
	else {
		return undef;
	}
	my $rc = system(@cmd);
	return $rc == 0 ? 1 : 0;
}

sub set_mute {
	my ($kind, $id, $mute) = @_;
	my $want;
	if (defined $mute && $mute =~ /^(?:1|on|true|yes|mute|muted)$/i) { $want = 1; }
	elsif (defined $mute && $mute =~ /^(?:0|off|false|no|unmute|unmuted)$/i) { $want = 0; }
	else { return undef; }
	$kind = _kind($kind);
	my $backend = backend();
	my $type = $backend->{'kind'} || 'none';
	$id = _default_id($backend, $kind) unless defined $id && length $id;
	my @cmd;
	if ($type eq 'pactl') {
		return 0 unless _pactl_id_ok($id);
		my $verb = $kind eq 'input' ? 'set-source-mute' : 'set-sink-mute';
		@cmd = ($backend->{'bin'}, $verb, $id, $want ? '1' : '0');
	}
	elsif ($type eq 'wpctl') {
		return 0 unless _wpctl_id_ok($id);
		@cmd = ($backend->{'bin'}, 'set-mute', $id, $want ? '1' : '0');
	}
	elsif ($type eq 'amixer') {
		return 0 unless _amixer_id_ok($id);
		@cmd = ($backend->{'bin'}, 'sset', $id, $want ? 'mute' : 'unmute');
	}
	else {
		return undef;
	}
	my $rc = system(@cmd);
	return $rc == 0 ? 1 : 0;
}

# The default device's id, or '' when the backend cannot name one. amixer has
# no notion of a default beyond the one control it was probed with.
sub default {
	my ($kind) = @_;
	$kind = _kind($kind);
	my $backend = backend();
	my $type = $backend->{'kind'} || 'none';
	if ($type eq 'pactl') {
		my $verb = $kind eq 'input' ? 'get-default-source' : 'get-default-sink';
		my $out = _exec($backend->{'bin'}, $verb);
		my ($id) = defined $out ? $out =~ /^\s*(\S+)/ : ();
		return defined $id ? $id : '';
	}
	if ($type eq 'wpctl') {
		my ($outputs, $inputs) = parse_wpctl(_exec($backend->{'bin'}, 'status'));
		my $list = $kind eq 'input' ? $inputs : $outputs;
		foreach my $device (@{$list}) {
			return $device->{'id'} if $device->{'default'};
		}
		return '';
	}
	if ($type eq 'amixer') {
		return $kind eq 'input' ? 'Capture' : ($backend->{'control'} || '');
	}
	return '';
}

sub set_default {
	my ($kind, $id) = @_;
	$kind = _kind($kind);
	my $backend = backend();
	my $type = $backend->{'kind'} || 'none';
	my @cmd;
	if ($type eq 'pactl') {
		return 0 unless _pactl_id_ok($id);
		my $verb = $kind eq 'input' ? 'set-default-source' : 'set-default-sink';
		@cmd = ($backend->{'bin'}, $verb, $id);
	}
	elsif ($type eq 'wpctl') {
		return 0 unless _wpctl_id_ok($id);
		@cmd = ($backend->{'bin'}, 'set-default', $id);
	}
	else {
		return undef;
	}
	my $rc = system(@cmd);
	return $rc == 0 ? 1 : 0;
}

# ---- the sink-input report --------------------------------------------------
# `pactl -f json list sink-inputs` as decoded rows. The stock `pactl` (not the
# JSON build) prints an error instead; that is an empty list, not a caller's
# problem.
sub stream_inputs {
	my $json = run('pactl', '-f', 'json', 'list', 'sink-inputs');
	return [] unless defined $json && $json =~ /^\s*\[/;
	require JSON::PP;
	my $list = eval { JSON::PP::decode_json($json) };
	return ref $list eq 'ARRAY' ? $list : [];
}

sub set_stream_input_mute {
	my ($id, $mute) = @_;
	return 0 unless defined $id && $id =~ /^\d+$/;
	my $want;
	if (defined $mute && $mute =~ /^(?:1|on|true|yes|mute|muted)$/i) { $want = '1'; }
	elsif (defined $mute && $mute =~ /^(?:0|off|false|no|unmute|unmuted)$/i) { $want = '0'; }
	else { return 0; }
	my $backend = backend();
	return 0 unless ($backend->{'kind'} || '') eq 'pactl';
	my $rc = system($backend->{'bin'}, 'set-sink-input-mute', $id, $want);
	return $rc == 0 ? 1 : 0;
}

sub set_stream_input_volume {
	my ($id, $pct) = @_;
	return 0 unless defined $id && $id =~ /^\d+$/;
	return 0 unless defined $pct && $pct =~ /^\d+$/;
	my $backend = backend();
	return 0 unless ($backend->{'kind'} || '') eq 'pactl';
	my $rc = system($backend->{'bin'}, 'set-sink-input-volume', $id, $pct . '%');
	return $rc == 0 ? 1 : 0;
}

# ---- argv -------------------------------------------------------------------
# The player and recorder argv are the one place the flags live. `play_argv`
# keeps the order the receiver used (playback, raw, format, rate, channels,
# latency, volume, names, device); `record_argv` keeps the SCO order (names,
# raw, format, rate, channels, latency, device). A shell pipeline that must
# carry ffmpeg joins these words rather than restating them.
sub play_argv {
	my (%opt) = @_;
	my $bin = which('pacat') || 'pacat';
	my @argv = ($bin, '--playback', '--raw');
	push @argv, '--format=' . ($opt{'format'} || 's16le');
	push @argv, '--rate=' . $opt{'rate'} if defined $opt{'rate'} && length $opt{'rate'};
	push @argv, '--channels=' . $opt{'channels'} if defined $opt{'channels'} && length $opt{'channels'};
	push @argv, '--latency-msec=' . $opt{'latency'} if defined $opt{'latency'} && length $opt{'latency'};
	push @argv, '--volume=' . $opt{'volume'} if defined $opt{'volume'} && length $opt{'volume'};
	push @argv, '--client-name=' . $opt{'client'} if defined $opt{'client'} && length $opt{'client'};
	push @argv, '--stream-name=' . $opt{'stream'} if defined $opt{'stream'} && length $opt{'stream'};
	push @argv, '--device=' . $opt{'device'} if defined $opt{'device'} && length $opt{'device'};
	return @argv;
}

sub record_argv {
	my (%opt) = @_;
	my $bin = which('parec') || 'parec';
	my @argv = ($bin);
	push @argv, '--client-name=' . $opt{'client'} if defined $opt{'client'} && length $opt{'client'};
	push @argv, '--stream-name=' . $opt{'stream'} if defined $opt{'stream'} && length $opt{'stream'};
	push @argv, '--raw';
	push @argv, '--format=' . ($opt{'format'} || 's16le');
	push @argv, '--rate=' . $opt{'rate'} if defined $opt{'rate'} && length $opt{'rate'};
	push @argv, '--channels=' . $opt{'channels'} if defined $opt{'channels'} && length $opt{'channels'};
	push @argv, '--latency-msec=' . $opt{'latency'} if defined $opt{'latency'} && length $opt{'latency'};
	push @argv, '--device=' . $opt{'device'} if defined $opt{'device'} && length $opt{'device'};
	return @argv;
}

# A local file player (sox). The word `play` stays bare: the alarm and timer
# commands are handed to the shell as text, and their fixtures pin the opening
# word. No level means `play -q file`.
sub player_argv {
	my ($file, $level) = @_;
	my @argv = ('play', '-q');
	push @argv, '-v', $level if defined $level && length $level;
	push @argv, $file if defined $file && length $file;
	return @argv;
}

# espeak's fixed fallback voice invocation. Empty when the tool is missing, so
# a caller's own no-speech path runs.
sub speak_argv {
	my ($text, $voice) = @_;
	my $bin = which('espeak') or return ();
	return ($bin, '-a70', '-v', (defined $voice && length $voice ? $voice : 'en-us'), $text);
}

1;
