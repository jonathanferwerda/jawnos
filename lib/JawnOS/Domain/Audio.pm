package subs;

# Audio: the saved house plan and the mixer's master switch.
#
# The plan is one JSON setting on the house row, not a table: it is the
# document `JawnOS::Audio::Plan` normalises and the engine compiles
# (docs/studio-audio-roadmap.md §8). This module is the seam between that data
# and the two things that act on it - the Sound page, which reads and writes it,
# and the engine's control socket, which applies it.
#
# Why a setting and not a table: Power's plan and the house's other policies
# already live this way, and a plan has no rows to query. The value is one
# document, saved whole; a partial merge would be a second model to test.
#
# Two rules that keep it honest:
#
# * **A save never fails because the engine is down.** The plan is durable
#   before the engine is asked anything. A machine with no engine, or one whose
#   binary was not built, still saves the house's intent and reports the reason
#   it is not applied. That is D11's graceful fallback, applied to the write.
# * **The switch is the only way to take the mixer.** `audio_plan_write` applies
#   only while `audio_manage` is on. Turning it off hands the machine back to
#   PipeWire and leaves the plan on disk for the day it is turned on again.
#
# Loaded on demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;

use Mojo::JSON qw(decode_json encode_json);

# One key for the house's plan and one for the switch. `device => 'all'` is the
# house row: every machine reads the same plan, which is the point of a central
# mixer. The Sound page's per-device volume rows stay per-device.
our $audio_plan_setting = 'audio_plan';
our $audio_manage_setting = 'audio_manage';

sub audio_plan_read {
	require JawnOS::Audio::Plan;
	my $raw = &subs::setting_grabber({
		app    => 'sound',
		setting => $audio_plan_setting,
		device => 'all',
	});
	my $decoded = (defined $raw && length $raw) ? eval { decode_json($raw) } : undef;
	return JawnOS::Audio::Plan::audio_plan_normalize($decoded);
}

sub audio_manage_read {
	my $raw = &subs::setting_grabber({
		app    => 'sound',
		setting => $audio_manage_setting,
		device => 'all',
	});
	return (defined $raw && $raw =~ /^(?:1|on|true|yes)$/i) ? 1 : 0;
}

# The backends the engine can open, and the default device for each. The
# picker stores the pair in the supervisor's startup file, not in a house
# setting: the interface is a fact about this machine, and the file is local
# to it.
our %audio_backend_ok = map { $_ => 1 } qw(alsa pipewire null);
our %audio_backend_device = (
	alsa     => 'hw:1,0',
	pipewire => 'default',
	null     => 'null',
);

sub _audio_engine_boot_read {
	require JawnOS::Audio::Engine;
	my $path = JawnOS::Audio::Engine::audio_engine_plan_path();
	return { path => $path, doc => undef }
		unless defined $path && length $path && -s $path;
	open my $fh, '<', $path or return { path => $path, doc => undef };
	local $/;
	my $raw = <$fh>;
	close $fh;
	my $doc = eval { decode_json($raw) };
	return { path => $path, doc => ref $doc eq 'HASH' ? $doc : undef };
}

# The engine device the supervisor will use on its next start. The startup
# file is the source of truth once the picker has written one; a machine that
# has never chosen falls back to the same ALSA default the supervisor uses.
sub audio_engine_device_read {
	my $boot = &_audio_engine_boot_read();
	my $doc = $boot->{doc} || {};
	my $backend = $doc->{backend};
	$backend = 'alsa' unless defined $backend && $audio_backend_ok{$backend};
	my $device = $doc->{device};
	$device = $audio_backend_device{$backend}
		unless defined $device && length $device;
	return { backend => $backend, device => $device };
}

# The ALSA cards this machine has, plus the PipeWire and null choices. A card's
# first PCM is `hw:N,0`; the name is the /proc/asound/cards description. A test
# can point JAWNOS_ASOUND_CARDS at a fixture; a machine with no card file still
# gets the PipeWire and null choices.
sub audio_engine_devices {
	my @devices = &_audio_alsa_devices();
	push @devices, {
		id => 'pipewire|default', backend => 'pipewire', device => 'default',
		name => 'PipeWire default',
	};
	push @devices, {
		id => 'null|null', backend => 'null', device => 'null',
		name => 'No device (null)',
	};
	return \@devices;
}

sub _audio_alsa_devices {
	my $path = $ENV{JAWNOS_ASOUND_CARDS} || '/proc/asound/cards';
	my @devices;
	open my $fh, '<', $path or return @devices;
	while (my $line = <$fh>) {
		next unless $line =~ /^\s*(\d+)\s+\[([^\]]*)\]:\s*(\S+)\s*-\s*(.*)$/;
		my ($index, $short, $driver, $long) = ($1, $2, $3, $4);
		$short =~ s/\s+\z//;
		$long =~ s/\s+\z//;
		my $name = length $long ? $long : (length $short ? $short : "Card $index");
		push @devices, {
			id => "alsa|hw:$index,0",
			backend => 'alsa',
			device => "hw:$index,0",
			name => "$name (hw:$index,0)",
		};
	}
	close $fh;
	return @devices;
}

# The plan's shape, the switch, and what the engine on this machine says. The
# engine is optional: `engine_available` is false on a machine that has none,
# and the page says so rather than drawing a switch that does nothing.
sub audio_plan_status {
	require JawnOS::Audio::Engine;
	require JawnOS::Audio::Plan;
	require JawnOS::Audio::SystemMix;
	require Sys::Hostname;
	my $plan = &audio_plan_read();
	my %latency;
	foreach my $sink (@{ $plan->{sinks} || [] }) {
		$latency{ $sink->{id} } = JawnOS::Audio::Plan::audio_plan_latency($plan, $sink->{id});
	}
	my $available = eval { JawnOS::Audio::Engine::audio_engine_available() } ? 1 : 0;
	my $engine = $available
		? eval { JawnOS::Audio::Engine::audio_engine_status() }
		: undef;
	return {
		plan             => $plan,
		latency          => \%latency,
		manage           => &audio_manage_read(),
		engine_available => $available,
		engine           => $engine,
		devices          => &audio_engine_devices(),
		engine_device    => &audio_engine_device_read(),
		system_mix       => JawnOS::Audio::SystemMix::status(
			JawnOS::Audio::Engine::audio_engine_state_dir()
		),
		machine          => (eval { Sys::Hostname::hostname() } || ''),
	};
}

# Save one plan. The write path refuses a wrong shape instead of repairing it:
# a dangling route or a gain of 5 is a mistake, and the read path already
# repairs an older plan, so the two never disagree about what is stored.
sub audio_plan_write {
	my ($plan) = @_;
	require JawnOS::Audio::Plan;
	return { ok => 0, error => 'a plan is one object with sources, buses, sinks and routes' }
		unless ref $plan eq 'HASH';
	return { ok => 0, error => 'the plan is not valid: check every route names a declared node and every gain and pan is in range' }
		unless JawnOS::Audio::Plan::audio_plan_valid($plan);

	my $clean = JawnOS::Audio::Plan::audio_plan_normalize($plan);
	&subs::setting_setter({
		app     => 'sound',
		setting => $audio_plan_setting,
		device  => 'all',
		value   => encode_json($clean),
	});
	my $choice = &audio_engine_device_read();
	&_audio_plan_boot_write(&audio_manage_read(), $clean, $choice->{backend}, $choice->{device});

	# Saving is durable whether or not the engine is up; applying is the second
	# answer, and it is reported rather than allowed to undo the save.
	my $applied;
	$applied = &audio_plan_apply($clean) if &audio_manage_read();
	return { ok => 1, plan => $clean, applied => $applied };
}

# Ask this machine's engine to run the saved plan. A caller may pass the plan
# it just saved so the engine is not asked to re-read a setting in the same
# request; with no argument the stored plan is read.
sub audio_plan_apply {
	my ($plan) = @_;
	require JawnOS::Audio::Engine;
	require JawnOS::Audio::SystemMix;
	my $clean = ref $plan eq 'HASH' ? $plan : &audio_plan_read();
	return { ok => 0, skipped => 1, error => 'the house mixer is not managed on this machine' }
		unless &audio_manage_read();

	# The engine owns the card exclusively on ALSA, so the machine's own audio
	# needs the virtual sink before the patch arms. A machine with no engine, no
	# pactl, or a shared PipeWire backend keeps its ordinary output: `ensure`
	# says `skipped` rather than muting the house.
	my $mix;
	my $available = eval { JawnOS::Audio::Engine::audio_engine_available() } ? 1 : 0;
	my $choice = &audio_engine_device_read();
	# The running engine's own answer wins over the saved choice: a stale engine
	# on the shared PipeWire backend must not have a sink pointed at itself.
	my $engine_backend = $choice->{backend} || '';
	if ($available) {
		my $status = eval { JawnOS::Audio::Engine::audio_engine_status() };
		$engine_backend = $status->{backend}
			if ref $status eq 'HASH' && defined $status->{backend} && length $status->{backend};
	}
	if ($available && $engine_backend eq 'alsa') {
		$mix = JawnOS::Audio::SystemMix::ensure(
			JawnOS::Audio::Engine::audio_engine_state_dir()
		);
	}

	my $answer = JawnOS::Audio::Engine::audio_engine_patch(
		$clean,
		(ref $mix eq 'HASH' && $mix->{ok}) ? $mix->{source} : undef,
	);
	$answer->{system_mix} = $mix if ref $answer eq 'HASH' && defined $mix;
	return $answer;
}

# The engine's startup copy, written beside the socket the supervisor reads:
# `{"manage":0|1,"plan":{...},"backend":"alsa","device":"hw:1,0"}`. The
# setting on the house row is the source of truth for the plan; this file exists
# so a fresh engine can arm the saved plan and open the chosen interface without
# a running manager to ask. It is written atomically - a temp file renamed over
# the target - so a crash mid-write cannot leave a torn JSON object for the next
# boot, and the directory is made if the install has never run the engine.
sub _audio_plan_boot_write {
	my ($manage, $plan, $backend, $device) = @_;
	require JawnOS::Audio::Engine;
	require File::Basename;
	require File::Path;

	my $path = JawnOS::Audio::Engine::audio_engine_plan_path();
	return { ok => 0, error => 'the plan boot file has no path' }
		unless defined $path && length $path;

	my $dir = File::Basename::dirname($path);
	eval { File::Path::make_path($dir) };

	my $doc = { manage => $manage ? 1 : 0, plan => $plan };
	if (defined $backend && $audio_backend_ok{$backend}
		&& defined $device && length $device) {
		$doc->{backend} = $backend;
		$doc->{device} = $device;
	}
	my $json = encode_json($doc);
	my $tmp  = "$path.tmp.$$";
	my $wrote = eval {
		open my $fh, '>', $tmp or die "open: $!";
		print {$fh} $json or die "write: $!";
		close $fh or die "close: $!";
		rename $tmp, $path or die "rename: $!";
		1;
	};
	unless ($wrote) {
		my $error = $@ || 'unknown error';
		unlink $tmp;
		return { ok => 0, error => "the plan boot file could not be written: $error" };
	}
	return { ok => 1, path => $path };
}

# Choose the interface the engine opens. The pair goes into the supervisor's
# startup file, so a restart uses it; while the engine is up, `quit` makes the
# supervisor restart it with the new choice (the supervisor reads the file at
# every spawn). A machine with no engine still saves the choice for later.
sub audio_engine_device_write {
	my ($backend, $device) = @_;
	$backend = '' if !defined $backend || ref $backend;
	$device  = '' if !defined $device || ref $device;
	return { ok => 0, error => 'choose an audio backend: alsa, pipewire or null' }
		unless $audio_backend_ok{$backend};
	return { ok => 0, error => 'choose a device for the backend' }
		unless length $device && $device =~ /\A[A-Za-z0-9_.:,-]+\z/;

	my $plan   = &audio_plan_read();
	my $manage = &audio_manage_read();
	my $written = &_audio_plan_boot_write($manage, $plan, $backend, $device);
	return { ok => 0, error => $written->{error} } unless $written->{ok};

	# Leaving ALSA for a shared PipeWire or the null device means the engine no
	# longer holds the card, so the virtual sink must not stay the default.
	if ($backend ne 'alsa' && $manage) {
		require JawnOS::Audio::SystemMix;
		JawnOS::Audio::SystemMix::remove(
			JawnOS::Audio::Engine::audio_engine_state_dir()
		);
	}

	require JawnOS::Audio::Engine;
	my $applied;
	if ($manage) {
		my $available = eval { JawnOS::Audio::Engine::audio_engine_available() } ? 1 : 0;
		$applied = $available
			? JawnOS::Audio::Engine::audio_engine_quit()
			: { ok => 1, skipped => 1, error => '' };
	}
	return { ok => 1, backend => $backend, device => $device, applied => $applied };
}

# The master switch. On applies the saved plan now; off stops the engine's
# patch and hands the outputs back. The plan itself is never removed.
sub audio_manage_set {
	my ($on) = @_;
	my $want = $on ? 1 : 0;
	&subs::setting_setter({
		app     => 'sound',
		setting => $audio_manage_setting,
		device  => 'all',
		value   => $want ? '1' : '0',
	});
	my $choice = &audio_engine_device_read();
	&_audio_plan_boot_write($want, &audio_plan_read(), $choice->{backend}, $choice->{device});

	require JawnOS::Audio::Engine;
	my $answer;
	if ($want) {
		$answer = &audio_plan_apply();
	}
	else {
		my $available = eval { JawnOS::Audio::Engine::audio_engine_available() } ? 1 : 0;
		$answer = $available
			? JawnOS::Audio::Engine::audio_engine_unpatch()
			: { ok => 1, skipped => 1, error => '' };
		# Off hands the machine back: restore the output that was the default
		# before the sink, and unload it. This runs even with no engine, so a
		# sink left by a crash is not stranded.
		require JawnOS::Audio::SystemMix;
		my $mix = JawnOS::Audio::SystemMix::remove(
			JawnOS::Audio::Engine::audio_engine_state_dir()
		);
		$answer->{system_mix} = $mix if ref $answer eq 'HASH';
	}
	return { ok => 1, manage => $want, applied => $answer };
}

1;
