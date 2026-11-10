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

use JawnOS::Platform::Audio ();

# The channel map is one JSON setting; this file loads no other JSON module.
require JSON::PP;

# The backend is discovered once per worker, like the Clock's mixer probe. A
# machine with no mixer is 'none' rather than an error: the app says so.
our $sound_backend_memo;

# The command and parser seam lives in JawnOS::Platform::Audio; these keep the
# domain names the Loader maps so an existing call site changes nothing.
sub sound_which {
	return JawnOS::Platform::Audio::which(@_);
}

sub sound_run {
	return JawnOS::Platform::Audio::run(@_);
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
		# the memo above is the domain's reset point for a test; keep the
		# platform probe in step with it
		JawnOS::Platform::Audio::reset_backend();
		$found = JawnOS::Platform::Audio::backend();
	}

	$sound_backend_memo = $found || { kind => 'none', bin => '' };
	return $sound_backend_memo;
}

# ---- the backend's own parsers ---------------------------------------------
# They live in JawnOS::Platform::Audio; these wrappers keep the domain names
# the Loader indexes (and the fixtures pin) working.
sub sound_parse_pactl_devices {
	return JawnOS::Platform::Audio::parse_pactl_devices(@_);
}

sub sound_parse_pactl_short {
	return JawnOS::Platform::Audio::parse_pactl_short(@_);
}

sub sound_pactl_devices {
	return JawnOS::Platform::Audio::pactl_devices(@_);
}

sub sound_parse_wpctl {
	return JawnOS::Platform::Audio::parse_wpctl(@_);
}

sub sound_amixer_control {
	return JawnOS::Platform::Audio::amixer_control(@_);
}

sub sound_amixer_devices {
	return JawnOS::Platform::Audio::amixer_devices(@_);
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
	return $id =~ /^(?:Master Playback Volume|Master|PCM|Speaker|Capture|Mic)$/ ? 1 : 0;
}

# ---- the reading ------------------------------------------------------------
sub sound_devices {
	my $backend = &sound_backend();
	my $type = $backend->{'kind'} || 'none';
	my (@outputs, @inputs, $output, $input);
	my $output_mute = 1;
	my $input_mute = 1;
	my $input_supported = 1;

	if ($type eq 'pactl' || $type eq 'wpctl' || $type eq 'amixer') {
		@outputs = @{ JawnOS::Platform::Audio::devices('output') };
		@inputs  = @{ JawnOS::Platform::Audio::devices('input') };
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
	$status->{'channels'} = &sound_channels();
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

	my $ok;
	if ($type eq 'pactl') {
		return { ok => 0, error => 'unknown device' } unless &sound_pactl_id_ok($id);
		$ok = JawnOS::Platform::Audio::set_volume($kind, $id, $volume);
	}
	elsif ($type eq 'wpctl') {
		return { ok => 0, error => 'unknown device' } unless &sound_wpctl_id_ok($id);
		$ok = JawnOS::Platform::Audio::set_volume($kind, $id, $volume);
	}
	elsif ($type eq 'amixer') {
		return { ok => 0, error => 'unknown device' } unless &sound_amixer_id_ok($id);
		$ok = JawnOS::Platform::Audio::set_volume($kind, $id, $volume);
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
		$ok = 1;
	}
	else {
		return { ok => 0, supported => 0, error => 'no sound backend' };
	}

	return { ok => 0, error => 'the volume could not be set' } unless $ok;
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

	my $ok;
	if ($type eq 'pactl') {
		return { ok => 0, error => 'unknown device' } unless &sound_pactl_id_ok($id);
		$ok = JawnOS::Platform::Audio::set_mute($kind, $id, $want);
	}
	elsif ($type eq 'wpctl') {
		return { ok => 0, error => 'unknown device' } unless &sound_wpctl_id_ok($id);
		$ok = JawnOS::Platform::Audio::set_mute($kind, $id, $want);
	}
	elsif ($type eq 'amixer') {
		return { ok => 0, error => 'unknown device' } unless &sound_amixer_id_ok($id);
		$ok = JawnOS::Platform::Audio::set_mute($kind, $id, $want);
	}
	elsif ($type eq 'android') {
		return { ok => 0, supported => 0, error => 'mute is not available on this machine' };
	}
	else {
		return { ok => 0, supported => 0, error => 'no sound backend' };
	}

	return { ok => 0, error => 'the mute state could not be set' } unless $ok;
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

	my $ok;
	if ($type eq 'pactl') {
		return { ok => 0, error => 'unknown device' } unless &sound_pactl_id_ok($id);
		$ok = JawnOS::Platform::Audio::set_default($kind, $id);
	}
	elsif ($type eq 'wpctl') {
		return { ok => 0, error => 'unknown device' } unless &sound_wpctl_id_ok($id);
		$ok = JawnOS::Platform::Audio::set_default($kind, $id);
	}
	elsif ($type eq 'amixer' || $type eq 'android') {
		return { ok => 0, supported => 0, error => 'choosing a default device is not available on this machine' };
	}
	else {
		return { ok => 0, supported => 0, error => 'no sound backend' };
	}

	return { ok => 0, error => 'the default device could not be set' } unless $ok;
	return { %{ &sound_status() }, ok => 1, changed => { kind => $kind, id => $id } };
}

# ---- the channels -----------------------------------------------------------
# The launcher's own mix: a master output and the three named sources a Gou
# carries. One setting holds the whole map, so a write never loses a channel it
# did not name. A worker with no database keeps the defaults instead of refusing
# to play: the widget must still draw on a fresh machine.
our %sound_channel_default = ( music => 70, phone => 100, alarm => 100 );

sub sound_channels {
	my %channel = map {
		$_ => { volume => $sound_channel_default{$_}, muted => 0 }
	} sort keys %sound_channel_default;
	my $raw = eval { &subs::setting_grabber({ app => 'controller', setting => 'channels' }) };
	my $stored = (defined $raw && length $raw) ? eval { JSON::PP::decode_json($raw) } : undef;
	if (ref $stored eq 'HASH') {
		foreach my $name (keys %channel) {
			my $row = $stored->{$name};
			next unless ref $row eq 'HASH';
			my $volume = $row->{'volume'};
			$channel{$name}{'volume'} = int($volume)
				if defined $volume && $volume =~ /^\d+$/ && $volume <= 100;
			$channel{$name}{'muted'} = $row->{'muted'} ? 1 : 0
				if defined $row->{'muted'};
		}
	}
	return \%channel;
}

sub sound_channel_set {
	my ($channel, $volume, $muted) = @_;
	return { ok => 0, error => 'unknown channel' }
		unless defined $channel && exists $sound_channel_default{$channel};
	return { ok => 0, error => 'volume must be between 0 and 100' }
		if defined $volume && !&sound_volume_valid($volume);
	my $want;
	if (defined $muted) {
		$want = &sound_mute_value($muted);
		return { ok => 0, error => 'mute must be on or off' } unless defined $want;
	}

	my $channels = &sound_channels();
	$channels->{$channel}{'volume'} = int($volume) if defined $volume;
	$channels->{$channel}{'muted'} = $want if defined $want;
	my $saved = eval {
		&subs::setting_setter({ app => 'controller', setting => 'channels', value => JSON::PP::encode_json($channels) });
		1;
	};
	return { ok => 0, error => 'the channels could not be saved' } unless $saved;
	return { ok => 1, channels => $channels };
}

# A player multiplies its own level by this, so a muted channel is silence and
# an unknown channel cannot make a stream loud by accident.
sub sound_channel_gain {
	my ($channel) = @_;
	my $channels = &sound_channels();
	my $row = $channels->{$channel};
	return 0 unless ref $row eq 'HASH';
	return 0 if $row->{'muted'};
	return $row->{'volume'} / 100;
}

1;
