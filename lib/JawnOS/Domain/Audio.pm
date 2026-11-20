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
# picker's pair is a fact about this machine: it is kept on this device's
# settings row (the same way the other local facts are), with the supervisor's
# startup file as a fast cache. Losing that file therefore costs nothing.
our %audio_backend_ok = map { $_ => 1 } qw(alsa pipewire null);
our %audio_backend_device = (
	alsa     => 'hw:1,0',
	pipewire => 'default',
	null     => 'null',
);
our $audio_engine_device_setting = 'audio_engine_device';

# The picker pair from this device's row, or undef. Stored as
# `backend|device`, the same spelling the Sound page posts.
sub _audio_engine_device_setting_read {
	my $raw = &subs::setting_grabber({
		app     => 'sound',
		setting => $audio_engine_device_setting,
		device  => &subs::device_setter(),
	});
	return undef unless defined $raw && length $raw;
	my ($backend, $device) = split /\|/, $raw, 2;
	return undef unless defined $backend && $audio_backend_ok{$backend}
		&& defined $device && $device =~ /\A[A-Za-z0-9_.:,-]+\z/;
	return { backend => $backend, device => $device };
}

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

# The engine device the supervisor will use on its next start. The settings
# row is the source of truth; the startup file is the fast cache a supervisor
# and the compiled default follow. A machine that has never chosen falls back
# to the same ALSA default the supervisor uses.
sub audio_engine_device_read {
	my $stored = &_audio_engine_device_setting_read();
	return $stored if $stored;

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

# ---- naming the source an input captures -----------------------------------
# A local `input` may name the PipeWire/Pulse source it listens to; without one
# it captures the machine's default. The Studio input picker asks for the list
# and saves one choice, so both halves live here beside the plan they touch.

# `pactl list short sources` is the authority for what is present. A `.monitor`
# source is a sink's own playback tap, so no person can point a microphone at
# it and it is left out. A row's human name is the long listing's Description;
# without one the node is prettified so the picker never shows an empty row.
sub audio_capture_sources {
	my ($short, $long) = @_;
	require JawnOS::Audio::Plan;
	if (!defined $short) {
		require JawnOS::Platform::Audio;
		$short = JawnOS::Platform::Audio::run('pactl', 'list', 'short', 'sources');
		$long  = JawnOS::Platform::Audio::run('pactl', 'list', 'sources');
	}

	my %description;
	foreach my $block (split /^Source\s+#\d+\b.*$/m, ($long || '')) {
		my ($node)  = $block =~ /^\s*Name:\s*(\S+)\s*$/m;
		my ($label) = $block =~ /^\s*Description:\s*(.+?)\s*$/m;
		next unless defined $node && defined $label && length $label;
		$description{$node} = $label;
	}

	my (@sources, %seen);
	foreach my $line (split /\n/, ($short || '')) {
		my @field = split /\t/, $line;
		next unless @field >= 2;
		my $node = $field[1];
		next unless defined $node && length $node;
		next if $node =~ /\.monitor\z/;
		next if $seen{$node}++;
		# The engine would take a malformed name as a command option, so it
		# is not offered as a choice either.
		next unless JawnOS::Audio::Plan::audio_plan_node_valid($node);
		my $name = $description{$node};
		$name = &_audio_capture_source_name($node) unless defined $name && length $name;
		push @sources, { node => $node, name => $name };
	}
	return \@sources;
}

sub _audio_capture_source_name {
	my ($node) = @_;
	my $name = $node;
	$name =~ s/\A(?:alsa_input|alsa_output)\.//;
	$name =~ s/[._]+/ /g;
	$name =~ s/\A\s+|\s+\z//g;
	return length $name ? $name : $node;
}

# Point the plan's input source on one device channel at a capture node, or
# clear it back to the machine's default with an empty name. The plan is saved
# whole through its own write path, so the engine arms the same plan it already
# had with one fact changed.
sub audio_plan_source_node_write {
	my ($channel, $node) = @_;
	require JawnOS::Audio::Plan;
	$channel = '' if !defined $channel || ref $channel;
	return { ok => 0, error => 'an input channel is a whole number from 0 to 31' }
		unless $channel =~ /\A\s*\d{1,2}\s*\z/ && $channel <= 31;
	$channel += 0;

	$node = '' if !defined $node || ref $node;
	$node =~ s/\A\s+|\s+\z//g;
	return { ok => 0, error => 'a node is a capture source name: letters, digits and . _ : @ + -' }
		if length $node && !JawnOS::Audio::Plan::audio_plan_node_valid($node);

	my $plan = &audio_plan_read();
	my ($source) = grep {
		($_->{kind} || '') eq 'input'
			&& !($_->{machine} || '')
			&& ($_->{channel} || 0) == $channel
	} @{ $plan->{sources} };
	return {
		ok => 0,
		error => "no input source on channel $channel for this machine; declare one in Sound's patchbay first",
	} unless $source;

	$source->{node} = $node;
	my $saved = eval { &audio_plan_write($plan) };
	return { ok => 0, error => ($@ ? "$@" : 'the plan could not be saved') }
		unless ref $saved eq 'HASH' && $saved->{ok};
	return {
		ok    => 1,
		plan  => $saved->{plan},
		source => { id => $source->{id}, channel => $channel, node => $node },
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

# `alsa|hw:0,0` and `hw:0,0` are the same choice; the engine may report the
# prefixed form while the picker stores the bare one.
sub _audio_device_same {
	my ($a, $b) = @_;
	$a = '' unless defined $a;
	$b = '' unless defined $b;
	$a =~ s/\Aalsa\|//;
	$b =~ s/\Aalsa\|//;
	return $a eq $b ? 1 : 0;
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

	my $available = eval { JawnOS::Audio::Engine::audio_engine_available() } ? 1 : 0;
	my $choice = &audio_engine_device_read();
	my $status;
	$status = eval { JawnOS::Audio::Engine::audio_engine_status() } if $available;

	my $engine_backend = $choice->{backend} || '';
	my $engine_device  = $choice->{device} || '';
	if (ref $status eq 'HASH') {
		$engine_backend = $status->{backend}
			if defined $status->{backend} && length $status->{backend};
		$engine_device = $status->{device}
			if defined $status->{device} && length $status->{device};

		# The saved choice is what the supervisor will use on its next spawn. An
		# engine still patching the old backend/device would otherwise keep the
		# card and the boot file would describe a different machine. Quit so the
		# supervisor respawns with the choice and installs the sink/rule before
		# the child opens the card.
		my $differs = 0;
		$differs = 1 if defined $status->{backend} && length $status->{backend}
			&& $status->{backend} ne ( $choice->{backend} || '' );
		$differs = 1 if defined $status->{device} && length $status->{device}
			&& defined $choice->{device} && length $choice->{device}
			&& !_audio_device_same( $status->{device}, $choice->{device} );
		if ($differs) {
			my $quit = eval { JawnOS::Audio::Engine::audio_engine_quit() };
			return {
				ok        => 1,
				skipped   => 1,
				restarted => 1,
				note      => 'the running engine is on a different backend or device;'
					. ' asked it to restart on the saved choice',
				engine    => $quit,
			};
		}
	}

	# The running engine's mode can lag the plan by one patch. The union keeps
	# capture provisioned whenever either says duplex: over-provisioning is
	# harmless, but a sink-only rule would make the new patch fail to open the
	# microphone.
	require Sys::Hostname;
	my $machine = eval { Sys::Hostname::hostname() } || '';
	my $plan_mode = JawnOS::Audio::SystemMix::plan_mode($clean, $machine);
	my $status_mode = ref $status eq 'HASH' ? $status->{mode} : undef;
	my $mode = JawnOS::Audio::SystemMix::mode_union($status_mode, $plan_mode);

	# The engine plays the machine's own output, so the virtual sink is needed
	# before the patch arms: on ALSA the card is held exclusively, and on the
	# shared PipeWire backend both playback and duplex plans mix the sink and
	# play it out the output they replaced. A duplex plan captures its routed
	# inputs through their own streams, so it no longer has to keep the ordinary
	# path. A machine with no engine, no pactl, or a device that names no output
	# keeps its ordinary sound: `ensure` says `skipped` rather than muting the
	# house.
	my $mix;
	my $mix_backend = $engine_backend eq 'alsa'
		|| $engine_backend eq 'pipewire';
	if ($available && $mix_backend) {
		$mix = JawnOS::Audio::SystemMix::ensure(
			JawnOS::Audio::Engine::audio_engine_state_dir(),
			$engine_device,
			$mode,
		);
		# A PipeWire engine plays out the sink the mix replaced. One that
		# started before the sink existed is still on `default`, which the mix
		# has just made our own sink: restart it so the supervisor spawns it on
		# the mix's playback device and capture.
		if ($engine_backend eq 'pipewire' && ref $mix eq 'HASH' && $mix->{ok}
			&& $mix->{created} && ref $status eq 'HASH') {
			my $quit = eval { JawnOS::Audio::Engine::audio_engine_quit() };
			return {
				ok         => 1,
				skipped    => 1,
				restarted  => 1,
				note       => 'the pipewire engine started before the system mix;'
					. ' asked it to restart on the mix playback device',
				system_mix => $mix,
				engine     => $quit,
			};
		}
	}

	my $answer = JawnOS::Audio::Engine::audio_engine_patch(
		$clean,
		(ref $mix eq 'HASH' && $mix->{ok}) ? $mix->{source} : undef,
	);
	$answer->{system_mix} = $mix if ref $answer eq 'HASH' && defined $mix;
	return $answer;
}

# The engine's startup copy: `{"manage":0|1,"plan":{...},"backend":"alsa",
# "device":"hw:1,0"}`. The setting on the house row is the source of truth
# for the plan, and this device's row for the picker pair; the file exists so a
# fresh engine can arm the saved plan and open the chosen interface without a
# running manager to ask. It lives in the durable audio state dir, not beside
# the socket: `~/.president` is wiped at boot and this file must survive a
# restart. It is written atomically - a temp file renamed over the target - so
# a crash mid-write cannot leave a torn JSON object for the next boot, and the
# directory is made if the install has never run the engine.
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

# Rebuild the startup copy from the settings rows once, at app start, so a
# supervisor that comes up before anyone opens Sound still gets the right plan.
# The one-time migration first moves an older build's file out of `~/.president`
# (which the boot wipe would otherwise delete), then this device's picker pair
# is seeded from it when the settings row has none - after that a lost file
# costs nothing. A machine that has never chosen writes no pair, so the
# supervisor's own fallback (PipeWire when a server answers, else ALSA) still
# decides; the boot write must not silently pin hw:1,0 on it. Every input is
# durable; a failure is reported and that fallback covers the window.
sub audio_boot_file_write {
	require JawnOS::Audio::Engine;
	eval { JawnOS::Audio::Engine::audio_engine_plan_migrate() };

	my $plan = &audio_plan_read();
	my $choice = &_audio_engine_device_setting_read();
	unless ($choice) {
		# An upgrading machine kept its pair only in the old file; take it
		# before the next crash can lose it again.
		my $doc = (&_audio_engine_boot_read())->{doc} || {};
		my $backend = $doc->{backend};
		my $device  = $doc->{device};
		if (defined $backend && $audio_backend_ok{$backend}
			&& defined $device && $device =~ /\A[A-Za-z0-9_.:,-]+\z/) {
			$choice = { backend => $backend, device => $device };
			&subs::setting_setter({
				app     => 'sound',
				setting => $audio_engine_device_setting,
				device  => &subs::device_setter(),
				value   => "$backend|$device",
			});
		}
	}
	return &_audio_plan_boot_write(
		&audio_manage_read(), $plan,
		(defined $choice ? $choice->{backend} : undef),
		(defined $choice ? $choice->{device}  : undef),
	);
}

# Choose the interface the engine opens. The pair is kept on this device's
# settings row and written into the supervisor's startup file, so a restart
# uses it and a lost file is rebuilt from the row; while the engine is up,
# `quit` makes the supervisor restart it with the new choice (the supervisor
# reads the file at every spawn), whatever the manage switch says - an engine
# left running keeps its old backend and device, and on ALSA that means holding
# the wrong card. A machine with no engine still saves the choice for later.
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
	&subs::setting_setter({
		app     => 'sound',
		setting => $audio_engine_device_setting,
		device  => &subs::device_setter(),
		value   => $backend . '|' . $device,
	});
	my $written = &_audio_plan_boot_write($manage, $plan, $backend, $device);
	return { ok => 0, error => $written->{error} } unless $written->{ok};

	# Leaving ALSA for a shared PipeWire or the null device means the engine no
	# longer holds the card, so the virtual sink must not stay the default and
	# the card rule must go. This runs even with manage off, because a rule left
	# by a crash would otherwise keep the desktop's playback node hidden.
	if ($backend ne 'alsa') {
		require JawnOS::Audio::SystemMix;
		JawnOS::Audio::SystemMix::remove(
			JawnOS::Audio::Engine::audio_engine_state_dir()
		);
	}

	require JawnOS::Audio::Engine;
	my $available = eval { JawnOS::Audio::Engine::audio_engine_available() } ? 1 : 0;
	my $applied = $available
		? JawnOS::Audio::Engine::audio_engine_quit()
		: { ok => 1, skipped => 1, error => '' };
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
