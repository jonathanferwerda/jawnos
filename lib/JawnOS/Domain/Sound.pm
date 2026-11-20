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

# ---- the live streams -------------------------------------------------------
# `pactl -f json list sink-inputs` / `source-outputs` rows, normalized for the
# window. A stock pactl answers no JSON, so the list is empty rather than an
# error. Every field is a scalar; a row with no usable index is skipped.
sub sound_stream_text {
	my ($value) = @_;
	return '' if !defined $value || ref $value;
	return "$value";
}

sub sound_stream_clamp {
	my ($value) = @_;
	return 0 unless defined $value && $value =~ /\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)\z/;
	my $level = int($value + ($value >= 0 ? 0.5 : -0.5));
	return 0 if $level < 0;
	return 100 if $level > 100;
	return $level;
}

# One channel of a pactl volume map. pactl reports `value` out of 65536 and
# usually a ready `value_percent`; either answers a whole percent.
sub sound_stream_percent {
	my ($channel) = @_;
	return undef unless ref $channel eq 'HASH';
	my $percent = $channel->{'value_percent'};
	if (defined $percent && $percent =~ /^\s*(\d+(?:\.\d+)?)\s*%/) {
		return &sound_stream_clamp($1);
	}
	my $value = $channel->{'value'};
	if (defined $value && $value =~ /\A\d+(?:\.\d+)?\z/) {
		return &sound_stream_clamp($value * 100 / 65536);
	}
	return undef;
}

# The first front-left or mono value, otherwise the mean of every channel.
sub sound_stream_volume {
	my ($volume) = @_;
	return 0 unless ref $volume eq 'HASH';
	foreach my $name (qw(front-left mono)) {
		next unless ref $volume->{$name} eq 'HASH';
		my $percent = &sound_stream_percent($volume->{$name});
		return $percent if defined $percent;
	}
	my @levels = grep { defined } map { &sound_stream_percent($volume->{$_}) }
		grep { ref $volume->{$_} eq 'HASH' } keys %{$volume};
	return 0 unless @levels;
	my $total = 0;
	$total += $_ for @levels;
	return &sound_stream_clamp($total / scalar(@levels));
}

# One pactl row as the window's shape. `sink` and `source` are the engine's
# numeric ids, shown beside the stream so the row is not anonymous.
sub sound_stream_row {
	my ($row, $kind) = @_;
	return undef unless ref $row eq 'HASH';
	my $id = defined $row->{'index'} ? $row->{'index'} : $row->{'id'};
	return undef unless defined $id && !ref $id && $id =~ /^\d+$/;
	my $props = ref $row->{'properties'} eq 'HASH' ? $row->{'properties'} : {};
	my $app = &sound_stream_text($props->{'application.name'});
	my $binary = &sound_stream_text($props->{'application.process.binary'});
	$app = $binary unless length $app;
	my $stream = {
		id => $id + 0,
		app => $app,
		media => &sound_stream_text($props->{'media.name'}),
		binary => $binary,
		volume => &sound_stream_volume($row->{'volume'}),
		mute => $row->{'mute'} ? 1 : 0,
		corked => $row->{'corked'} ? 1 : 0,
		state => &sound_stream_text($row->{'state'}),
	};
	if (defined $kind && $kind eq 'recording') {
		$stream->{'source'} = &sound_stream_text($row->{'source'});
	}
	else {
		$stream->{'sink'} = &sound_stream_text($row->{'sink'});
	}
	return $stream;
}

sub sound_streams {
	my ($kind) = @_;
	my $rows = (defined $kind && $kind eq 'recording')
		? JawnOS::Platform::Audio::stream_outputs()
		: JawnOS::Platform::Audio::stream_inputs();
	my @streams;
	foreach my $row ( @{ $rows || [] } ) {
		my $stream = &sound_stream_row($row, $kind);
		push @streams, $stream if $stream;
	}
	return \@streams;
}

# ---- the JawnOS apps --------------------------------------------------------
# A desktop tab writes its latest layout snapshot onto its websockets row: a JSON
# map keyed by app (and by its own bookkeeping keys, window_stacks and
# musicData), where each open window is a value with type 'window'. A row is
# live while it is a stayingAlive heartbeat inside the manager's liveness window
# (Manager.pm $ws_live_window, 60s); a row that died is retired to type 'closed',
# and one that merely went quiet ages out here. websockets is a local table (it
# is in $gb::forbidden and not on the sync rail), and the hostname clause keeps
# the answer to this machine even if a row ever arrives another way.
our $sound_window_live_ms = 60000;

sub sound_open_window_apps {
	my $hostname = eval { &subs::machine_hostname() } || '';
	my $sql = "select windows from websockets "
		. "where type = 'stayingAlive' and cast(server_time as integer) >= ? "
		. "and windows is not null and windows != ''";
	my @bind = (&subs::rightNow() - $sound_window_live_ms);
	if (defined $hostname && length $hostname) {
		$sql .= ' and hostname = ?';
		push @bind, $hostname;
	}
	my $rows = eval { &subs::db_query($sql, @bind)->hashes } || [];
	my (%seen, @apps);
	foreach my $row ( @{$rows} ) {
		my $windows = eval { JSON::PP::decode_json($row->{'windows'}) };
		next unless ref $windows eq 'HASH';
		foreach my $app ( keys %{$windows} ) {
			my $window = $windows->{$app};
			next unless ref $window eq 'HASH';
			next unless ($window->{'type'} || '') eq 'window';
			next unless defined $app && !ref $app && length $app;
			next if $app =~ /^__/;
			next if $seen{$app}++;
			push @apps, $app;
		}
	}
	return [ sort { lc($a) cmp lc($b) } @apps ];
}

# The apps with a window open on this machine, each with the profile level it
# carries. The rows are read once so a long app list does not cost one query per
# app. An app with a window but no profile reads as passive, so the level is
# still written for every row the list shows.
sub sound_apps_list {
	my $choices = eval { &sound_open_window_apps() } || [];
	my $rows = eval { &subs::sound_profile_rows() } || {};
	my (@apps, %seen);
	foreach my $app ( @{ ref $choices eq 'ARRAY' ? $choices : [] } ) {
		next unless defined $app && !ref $app && length $app;
		next if $seen{$app}++;
		my $level = eval { &subs::sound_profile_rows_level($rows, $app) };
		$level = 'passive' unless defined $level && length $level;
		push @apps, { name => "$app", level => $level };
	}
	return \@apps;
}

# One answer for the Apps pill: the house channels, the JawnOS app levels and
# every stream the sound system is carrying now.
sub sound_apps_reading {
	return {
		ok => 1,
		channels => &sound_channels(),
		apps => &sound_apps_list(),
		playback => &sound_streams('playback'),
		recording => &sound_streams('recording'),
	};
}

# The app-level slider has five stops; the route carries a 0..100 volume, so
# the nearest stop is what the profile store receives.
our @sound_app_level_stops = (
	[0, 'passive'], [25, 'sound'], [50, 'quiet'], [75, 'mute'], [100, 'silence'],
);
our @sound_app_levels = map { $_->[1] } @sound_app_level_stops;

sub sound_app_level_from_volume {
	my ($volume) = @_;
	return undef unless &sound_volume_valid($volume);
	my $want = int($volume);
	my $best = $sound_app_level_stops[0];
	foreach my $stop ( @sound_app_level_stops ) {
		$best = $stop if abs($stop->[0] - $want) < abs($best->[0] - $want);
	}
	return $best->[1];
}

# A name is written to a settings row, so it may carry any printable character.
# Length is bounded and control characters are refused.
sub sound_target_name_ok {
	my ($name) = @_;
	return 0 unless defined $name && !ref $name && length $name && length $name <= 200;
	return 0 if $name =~ /[\x00-\x1f\x7f]/;
	return 1;
}

sub sound_option {
	my ($value) = @_;
	return undef unless defined $value && !ref $value && length $value;
	return $value;
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

# ---- one dispatcher for the Apps pill --------------------------------------
# kind is channel, app, playback or recording. Channel and app carry a name;
# the two stream kinds carry the pactl numeric id. Exactly one of volume or
# muted is expected, so a mute press never rewrites a level.
sub sound_apps_set {
	my ($kind, $name, $id, $volume, $muted, $level) = @_;
	$kind = lc(&sound_option($kind) || '');
	$name = &sound_option($name);
	$id = &sound_option($id);
	$volume = &sound_option($volume);
	$muted = &sound_option($muted);
	$level = &sound_option($level);

	if ($kind eq 'channel') {
		return { ok => 0, error => 'unknown channel' }
			unless defined $name && exists $sound_channel_default{$name};
		return &sound_channel_set($name, $volume, $muted);
	}

	if ($kind eq 'app') {
		return { ok => 0, error => 'unknown app' } unless &sound_target_name_ok($name);
		my $want;
		if (defined $level) {
			my $clean = lc $level;
			$clean =~ s/^\s+|\s+$//g;
			return { ok => 0, error => 'unknown app level' }
				unless grep { $_ eq $clean } @sound_app_levels;
			$want = $clean;
		}
		else {
			$want = &sound_app_level_from_volume($volume);
			return { ok => 0, error => 'volume must be between 0 and 100' }
				unless defined $want;
		}
		my $saved = eval { &subs::sound_app_level_write($name, $want) };
		return { ok => 0, error => 'the app level could not be set' } unless $saved;
		return { ok => 1, changed => { kind => 'app', name => $name, level => $want } };
	}

	if ($kind eq 'playback' || $kind eq 'recording') {
		return { ok => 0, error => 'stream id is a whole number' }
			unless defined $id && $id =~ /^\d+$/;
		my $backend = &sound_backend();
		return { ok => 0, supported => 0, error => 'streams are only listed by pactl' }
			unless ($backend->{'kind'} || '') eq 'pactl';

		if (defined $volume) {
			return { ok => 0, error => 'volume must be between 0 and 100' }
				unless &sound_volume_valid($volume);
			my $pct = int($volume);
			my $done = $kind eq 'recording'
				? JawnOS::Platform::Audio::set_stream_output_volume($id, $pct)
				: JawnOS::Platform::Audio::set_stream_input_volume($id, $pct);
			return { ok => 0, error => 'the stream volume could not be set' } unless $done;
			return { ok => 1, changed => { kind => $kind, id => $id + 0, volume => $pct } };
		}

		if (defined $muted) {
			my $want = &sound_mute_value($muted);
			return { ok => 0, error => 'mute must be on or off' } unless defined $want;
			my $done = $kind eq 'recording'
				? JawnOS::Platform::Audio::set_stream_output_mute($id, $want)
				: JawnOS::Platform::Audio::set_stream_input_mute($id, $want);
			return { ok => 0, error => 'the stream mute state could not be set' } unless $done;
			return { ok => 1, changed => { kind => $kind, id => $id + 0, muted => $want } };
		}

		return { ok => 0, error => 'nothing to change' };
	}

	return { ok => 0, error => 'unknown sound target' };
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
