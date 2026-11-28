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
# A normal Studio take needs the capture and the outputs, which the running
# house patch owns. The take suspends that patch and re-arms the saved plan
# afterwards; this setting, not a process global, is how it remembers the debt.
# A worker that dies after the unpatch has still left the next request a marker
# to pay, and the plan itself stays on disk the whole time.
our $audio_take_patch_setting = 'audio_take_patch';

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

# The house's uplink is one address, not a per-device choice: the machine that
# mixes a peer's input listens there, and every machine reads the same value.
# Empty means the uplink is off. Its session key is generated the first time an
# uplink is written and then kept, because the engine signs every datagram with
# it and changing it would strand the peers. The key is never shown in a page or
# a log; it is read only to write the boot file and the child's environment.
our $audio_uplink_setting      = 'audio_uplink';
our $audio_session_key_setting = 'audio_session_key';

# host:port, where host is an IPv4 literal, a bracketed IPv6 literal or a DNS
# name, and the port is 1..65535. The value is never joined into a path or a
# shell command; the engine binds it, and a name it cannot resolve stays its own
# reported error rather than a manager crash.
sub _audio_uplink_valid {
	my ($address) = @_;
	return 0 unless defined $address && !ref $address;
	$address = "$address";
	return 0 unless length $address && length $address <= 255;
	return 0 unless $address =~ /\A(?:\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?):(\d{1,5})\z/;
	my $port = $1 + 0;
	return $port >= 1 && $port <= 65_535 ? 1 : 0;
}

# The saved address, or '' when the uplink is off. A stored value that does not
# fit the shape reads as off rather than reaching the supervisor as a bad flag.
sub audio_uplink_read {
	my $raw = &subs::setting_grabber({
		app     => 'sound',
		setting => $audio_uplink_setting,
		device  => 'all',
	});
	return '' unless defined $raw && !ref $raw;
	$raw =~ s/\A\s+|\s+\z//g;
	return _audio_uplink_valid($raw) ? $raw : '';
}

# Save the address; an empty one clears it. The boot file is rewritten at once,
# because it is what the supervisor reads at every spawn, and a running engine
# is asked to quit so it comes back with the new flag. A machine with no engine
# still saves the address for later.
sub audio_uplink_write {
	my ($address) = @_;
	$address = '' if !defined $address || ref $address;
	$address =~ s/\A\s+|\s+\z//g;
	return { ok => 0, error => 'an uplink is host:port, for example 0.0.0.0:7060' }
		if length $address && !_audio_uplink_valid($address);

	&subs::setting_setter({
		app     => 'sound',
		setting => $audio_uplink_setting,
		device  => 'all',
		value   => $address,
	});
	# Generate the key with the first address, so a peer source added later never
	# has to create one while a spawn is deciding whether to pass the flag.
	&audio_session_key_read() if length $address;
	my $choice = &audio_engine_device_read();
	&_audio_plan_boot_write(
		&audio_manage_read(), &audio_plan_read(),
		$choice->{backend}, $choice->{device},
	);

	require JawnOS::Audio::Engine;
	my $available = eval { JawnOS::Audio::Engine::audio_engine_available() } ? 1 : 0;
	my $applied = $available
		? JawnOS::Audio::Engine::audio_engine_quit()
		: { ok => 1, skipped => 1, error => '' };
	return { ok => 1, uplink => $address, applied => $applied };
}

# 32 random bytes as 64 hex characters, generated once and then kept. A stored
# value that is not exactly that shape is replaced rather than trusted, so a
# hand-edited setting can never leave the engine with a key it cannot parse.
sub audio_session_key_read {
	my $raw = &subs::setting_grabber({
		app     => 'sound',
		setting => $audio_session_key_setting,
		device  => 'all',
	});
	if (defined $raw && !ref $raw) {
		$raw = lc "$raw";
		return $raw if $raw =~ /\A[0-9a-f]{64}\z/;
	}
	require Crypt::PRNG;
	my $key = lc Crypt::PRNG::random_bytes_hex(32);
	&subs::setting_setter({
		app     => 'sound',
		setting => $audio_session_key_setting,
		device  => 'all',
		value   => $key,
	});
	return $key;
}

# Does this plan declare a peer source on this machine? The boot file names an
# uplink only then: a peer on another machine is silent here, and an uplink with
# nothing to feed is a socket the engine would hold open for no reason.
sub _audio_plan_has_local_peer {
	my ($plan) = @_;
	return 0 unless ref $plan eq 'HASH' && ref $plan->{sources} eq 'ARRAY';
	require JawnOS::Audio::Plan;
	foreach my $source (@{ $plan->{sources} }) {
		next unless ref $source eq 'HASH';
		next unless (($source->{kind} // '') eq 'peer');
		return 1 if JawnOS::Audio::Plan::audio_plan_on_this_machine($source->{machine});
	}
	return 0;
}

# Any peer source in the plan, on any machine. A deck's handoff is written by
# whichever machine Now Me runs on, while the source may be mixed on another;
# the source's `machine` is resolved to that machine's address for the deck.
sub _audio_plan_has_peer {
	my ($plan) = @_;
	return 0 unless ref $plan eq 'HASH' && ref $plan->{sources} eq 'ARRAY';
	foreach my $source (@{ $plan->{sources} }) {
		next unless ref $source eq 'HASH';
		return 1 if (($source->{kind} // '') eq 'peer');
	}
	return 0;
}

# One peer source for this deck, and its index in the plan (the engine's
# stream is AUDIO_STREAM_BASE + index). A source's id or label naming the deck
# selects it; with exactly one peer source, that is the deck's even unnamed.
# The source may run on another machine: its `machine` names the mixer and the
# caller resolves the address from there. More than one unnamed peer is
# ambiguous and delivers nothing rather than guessing a stream.
sub _audio_deck_peer_source {
	my ($plan, $chip_id, $name) = @_;
	return undef unless ref $plan eq 'HASH' && ref $plan->{sources} eq 'ARRAY';
	my %routed = map { ($_->{from} // '') => 1 }
		grep { ref $_ eq 'HASH' } @{ ref $plan->{routes} eq 'ARRAY' ? $plan->{routes} : [] };
	my @peers;
	foreach my $index (0 .. $#{ $plan->{sources} }) {
		my $source = $plan->{sources}[$index];
		next unless ref $source eq 'HASH';
		next unless (($source->{kind} // '') eq 'peer');
		# An unrouted peer has no ring in the engine, so there is nothing
		# for the deck's stream to feed.
		next unless $routed{$source->{id} // ''};
		push @peers, { index => $index, source => $source };
	}
	return undef unless @peers;
	my @wanted = grep { defined && !ref && length } ($chip_id, $name);
	foreach my $peer (@peers) {
		my $haystack = lc(($peer->{source}{id} // '') . ' ' . ($peer->{source}{label} // ''));
		foreach my $want (@wanted) {
			return $peer if index($haystack, lc($want)) >= 0;
		}
	}
	return $peers[0] if @peers == 1;
	return undef;
}

# Split a saved uplink into (host, port). The address has already passed
# _audio_uplink_valid, so a bracket is the only IPv6 shape.
sub _audio_uplink_split {
	my ($address) = @_;
	return () unless defined $address && !ref $address;
	return ($1, $2 + 0) if $address =~ /\A(\[[0-9A-Fa-f:.]+\]):(\d{1,5})\z/;
	return ($1, $2 + 0) if $address =~ /\A([^:]+):(\d{1,5})\z/;
	return ();
}

# The LAN address of the machine a peer source runs on, when the House list
# names it. The source's `machine` is empty for this machine (the caller's
# fallback covers that), or a host/computer name the neighbour list carries.
sub _audio_uplink_machine_ip {
	my ($machine, $machines) = @_;
	return undef unless defined $machine && !ref $machine && length $machine;
	return undef unless ref $machines eq 'ARRAY';
	my $want = lc $machine;
	foreach my $node (@$machines) {
		next unless ref $node eq 'HASH';
		my $name = lc($node->{name} // '');
		my $computer = lc($node->{computer} // '');
		next unless $node->{ip};
		return $node->{ip} if ($name && $name eq $want) || ($computer && $computer eq $want);
	}
	return undef;
}

# The pure selection: what a deck should dial, which stream to claim and the
# key to sign with. Empty when the uplink is off, no peer source is on this
# machine, or the peer is ambiguous. A bind-all saved address is replaced by
# the address the deck already reaches this machine on.
sub _audio_uplink_choose {
	my ($plan, $uplink, $key, $host, $chip_id, $name, $machines) = @_;
	return {} unless defined $uplink && !ref $uplink && length $uplink;
	return {} unless _audio_plan_has_peer($plan);
	my $peer = _audio_deck_peer_source($plan, $chip_id, $name);
	return {} unless $peer;
	my ($saved_host, $port) = _audio_uplink_split($uplink);
	return {} unless defined $port;
	my $dial = $saved_host;
	if (!defined $dial || $dial eq '0.0.0.0' || $dial eq '[::]' || $dial eq '::') {
		# A bind-all uplink is not dialable. The peer's own machine is the
		# one mixing it; when the source names no machine, the machine the
		# deck already reaches (the caller's host) is the mixer.
		$dial = _audio_uplink_machine_ip($peer->{source}{machine}, $machines) // $host;
	}
	return {} unless defined $dial && !ref $dial && length $dial;
	return {
		address    => "$dial:$port",
		stream     => $peer->{index},
		latency_ms => $peer->{source}{latency_ms} // 0,
		key        => $key // '',
	};
}

# The push a deck gets in Now Me. The key is only read when the uplink is on
# and a peer source on this machine can carry the deck; it is never logged or
# shown. A device with no uplink gets empty fields, so the deck clears a stale
# address instead of keeping one that no longer exists.
sub audio_uplink_for_device {
	my ($opts) = @_;
	$opts = {} unless ref $opts eq 'HASH';
	my $uplink = &audio_uplink_read();
	my $plan = &audio_plan_read();
	my $key = '';
	if (length $uplink && _audio_plan_has_peer($plan)) {
		$key = &audio_session_key_read();
	}
	return _audio_uplink_choose($plan, $uplink, $key, $opts->{host}, $opts->{chip_id}, $opts->{name}, $opts->{machines});
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
# The device a machine that has never chosen one would open. ALSA names the
# first card that can play, so the answer is an interface that exists on this
# machine rather than a number that was right on another one; every other
# backend keeps its compiled default.
sub _audio_default_device {
	my ($backend) = @_;
	$backend = '' unless defined $backend && !ref $backend;
	if ( $backend eq 'alsa' ) {
		require JawnOS::Platform::Audio;
		my $first = JawnOS::Platform::Audio::first_playback_pcm();
		return $first if defined $first && length $first;
	}
	return $audio_backend_device{$backend};
}

our $audio_engine_device_setting = 'audio_engine_device';
our $audio_engine_profile_setting = 'audio_engine_profile';

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
	my $profile = &_audio_engine_profile_read();
	my $stored = &_audio_engine_device_setting_read();
	if ($stored) {
		return $stored unless $stored->{backend} eq 'pipewire' && $profile;
		return {
			%$stored,
			profile => $profile->{profile},
			card    => $profile->{card},
		};
	}

	my $boot = &_audio_engine_boot_read();
	my $doc = $boot->{doc} || {};
	my $backend = $doc->{backend};
	$backend = 'alsa' unless defined $backend && $audio_backend_ok{$backend};
	my $device = $doc->{device};
	$device = &_audio_default_device($backend)
		unless defined $device && length $device;
	return { backend => $backend, device => $device }
		unless $backend eq 'pipewire' && $profile;
	return {
		backend => $backend, device => $device,
		profile => $profile->{profile},
		card    => $profile->{card},
	};
}


# The saved PipeWire profile, as `card|profile`. It is separate from the
# engine pair because the engine's device stays `default`; the profile is a
# property of the card the engine plays out.
sub _audio_engine_profile_read {
	my $raw = &subs::setting_grabber({
		app     => 'sound',
		setting => $audio_engine_profile_setting,
		device  => &subs::device_setter(),
	});
	return undef unless defined $raw && !ref $raw && length $raw;
	my ($card, $profile) = split /\|/, $raw, 2;
	return undef unless defined $card && defined $profile
		&& length $card && length $profile;
	return undef unless $card =~ /\A[A-Za-z0-9][A-Za-z0-9_.:@+\-]*\z/
		&& $profile =~ /\A[A-Za-z0-9][A-Za-z0-9_.:@+\-]*\z/;
	return { card => $card, profile => $profile };
}

sub _audio_engine_profile_write {
	my ($card, $profile) = @_;
	return unless defined $card && length $card && defined $profile && length $profile;
	&subs::setting_setter({
		app     => 'sound',
		setting => $audio_engine_profile_setting,
		device  => &subs::device_setter(),
		value   => "$card|$profile",
	});
}

sub _audio_engine_profile_clear {
	&subs::setting_setter({
		app     => 'sound',
		setting => $audio_engine_profile_setting,
		device  => &subs::device_setter(),
		value   => '',
	});
}

# The picker's choices: each ALSA card, then the PipeWire profiles that card
# offers, then the plain PipeWire choice and null. A card is named by its ALSA
# id (`hw:CODEC,0`), not by the kernel's number: the number follows USB
# enumeration, so the same interface came back as card 1 after one reboot when
# it had been card 2, and a saved `hw:2,0` then opened the built-in card. The
# description is the /proc/asound/cards name and the profiles come from one
# `pactl list cards`, whose `alsa.card` property ties a PipeWire card to the
# index. A test can point JAWNOS_ASOUND_CARDS at a fixture; a machine with no
# card file still gets the PipeWire and null choices, and a machine with no
# pactl gets no profile rows — never an invented one. Choosing a profile is how
# Pro Audio is set from this picker rather than pavucontrol.
sub audio_engine_devices {
	require JawnOS::Platform::Audio;
	my @cards = @{ JawnOS::Platform::Audio::parse_pactl_cards(
		JawnOS::Platform::Audio::run('pactl', 'list', 'cards')) || [] };
	my %card_at;
	foreach my $card (@cards) {
		next unless defined $card->{'alsa_card'} && length $card->{'alsa_card'};
		$card_at{ $card->{'alsa_card'} } = $card;
	}

	my @devices;
	foreach my $alsa (&_audio_alsa_devices()) {
		# A capture-only card — a webcam's microphone, say — is listed by the
		# kernel but cannot play, so choosing it as the engine's device leaves the
		# person with silence and nothing to read. It is not this picker's to
		# offer; a capture list is a different question.
		next unless _audio_card_plays( $alsa->{'card_index'} );
		my $index = $alsa->{'card_index'};
		my $card = defined $index ? $card_at{$index} : undef;
		$alsa->{'card'} = $card->{'name'} if $card;
		push @devices, $alsa;
		next unless $card;
		foreach my $profile (@{ $card->{'profiles'} || [] }) {
			next if $profile->{'id'} eq 'off';
			push @devices, {
				id      => 'pipewire|default|' . $card->{'name'} . '|' . $profile->{'id'},
				backend => 'pipewire',
				device  => 'default',
				card    => $card->{'name'},
				profile => $profile->{'id'},
				active  => ( defined $card->{'active'} && $card->{'active'} eq $profile->{'id'} ) ? 1 : 0,
				name    => 'PipeWire — ' . $profile->{'name'}
					. ( length $alsa->{'card_name'} ? ' (' . $alsa->{'card_name'} . ')' : '' ),
			};
		}
	}
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
		# The id is stable across boots; the number is not. A card with no id
		# (an ancient driver) keeps its number so the entry is still usable.
		my $pcm = length $short ? "hw:$short,0" : "hw:$index,0";
		push @devices, {
			id => "alsa|$pcm",
			backend => 'alsa',
			device => $pcm,
			name => "ALSA — $name",
			card_name => $name,
			card_index => $index + 0,
		};
	}
	close $fh;
	return @devices;
}

# Whether a card has a playback PCM at all. The kernel's card list names every
# card, including a capture-only one (a webcam's microphone), and the engine's
# device must be able to play. A card directory the box cannot read — a
# non-Linux machine, or a fixture that names the cards without the tree — keeps
# its row rather than vanishing: the probe never invents a limit.
sub _audio_card_plays {
	my ($index) = @_;
	return 1 unless defined $index && $index =~ /\A[0-9]+\z/;
	my $dir = ( $ENV{'JAWNOS_ASOUND_DIR'} || '/proc/asound' ) . "/card$index";
	opendir(my $dh, $dir) or return 1;
	my @playback = grep { /\Apcm[0-9]+p\z/ } readdir $dh;
	closedir $dh;
	return @playback ? 1 : 0;
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
		uplink           => &audio_uplink_read(),
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

# ---- a Studio take borrowing the capture from the house patch --------------

# The saved plan is a normal take's to borrow, not to lose. The engine gives its
# capture and outputs to one owner, so a take refuses while the patch runs
# (engine/src/socket.rs record()). The take route asks these two helpers to put
# the patch down and to pick it up again; the marker in `$audio_take_patch_setting`
# makes that a durable promise rather than a process-local flag.

sub _audio_take_patch_marker {
	# This machine's take owed this machine's engine a restore; another
	# machine's running patch must not clear it.
	my $raw = &subs::setting_grabber({
		app     => 'sound',
		setting => $audio_take_patch_setting,
		device  => &subs::device_setter(),
	});
	return (defined $raw && !ref $raw && $raw eq 'suspended') ? 1 : 0;
}

sub _audio_take_patch_marker_write {
	my ($suspended) = @_;
	&subs::setting_setter({
		app     => 'sound',
		setting => $audio_take_patch_setting,
		device  => &subs::device_setter(),
		value   => $suspended ? 'suspended' : '',
	});
	return;
}

# Called just before a normal take asks the engine to record. Only the managed
# house patch is suspended: with the switch off the patch is not ours to stop.
# The marker is written before the command, so a request that dies in between
# still leaves the house knowing a restore is owed.
sub audio_take_patch_suspend {
	return { ok => 1, suspended => 0 } unless &audio_manage_read();

	require JawnOS::Audio::Engine;
	my $status = eval { JawnOS::Audio::Engine::audio_engine_status() };
	return { ok => 1, suspended => 0 }
		unless ref $status eq 'HASH' && ($status->{'state'} // '') eq 'patching';

	_audio_take_patch_marker_write(1);
	my $answer = eval { JawnOS::Audio::Engine::audio_engine_unpatch() };
	return { ok => 1, suspended => 1, engine => $answer };
}

# Re-arm the saved plan after the take. Stop and a refused start restore
# unconditionally; the status poll passes `only_if_idle` so a take that ends on
# its own is restored without touching one that is still recording. The marker
# is cleared only once the plan is applied (or the switch is off, or a patch is
# already running): a failed re-arm stays owed for the next call.
sub audio_take_patch_restore {
	my ($opts) = @_;
	$opts = {} unless ref $opts eq 'HASH';
	return { ok => 1, restored => 0 } unless _audio_take_patch_marker();

	unless (&audio_manage_read()) {
		_audio_take_patch_marker_write(0);
		return {
			ok => 1, restored => 0, skipped => 1,
			error => 'the house mixer is not managed on this machine',
		};
	}

	if ($opts->{'only_if_idle'}) {
		require JawnOS::Audio::Engine;
		my $status = exists $opts->{'status'}
			? $opts->{'status'}
			: eval { JawnOS::Audio::Engine::audio_engine_status() };
		my $state = ref $status eq 'HASH' ? ($status->{'state'} // '') : '';
		# The take still owns the capture: leave the plan owed.
		return { ok => 1, restored => 0, pending => 1 }
			if $state eq 'recording';
		# The house patch is already running, so nothing is owed.
		if ($state eq 'patching') {
			_audio_take_patch_marker_write(0);
			return { ok => 1, restored => 0, already => 1 };
		}
		# No live engine answer: the boot file arms the saved plan when the
		# engine returns, so the marker waits for that engine and the next poll.
		return { ok => 1, restored => 0, pending => 1 }
			unless ref $status eq 'HASH' && $status->{'ok'};
	}

	my $applied = eval { &audio_plan_apply() };
	$applied = { ok => 0, error => "$@" } unless ref $applied eq 'HASH';
	if ($applied->{'ok'}) {
		_audio_take_patch_marker_write(0);
		return { ok => 1, restored => 1, applied => $applied };
	}
	return {
		ok => 0, restored => 0, applied => $applied,
		error => ($applied->{'error'} // 'the house patch could not be restored'),
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
			&& JawnOS::Audio::Plan::audio_plan_on_this_machine($_->{machine})
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
# "device":"hw:1,0"}`, plus `"uplink":"host:port"` and `"session_key":"<hex>"`
# while a peer source on this machine has a saved uplink. The setting on the
# house row is the source of truth
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

	# An uplink is a pair: the address the supervisor listens on and the key the
	# engine signs every datagram with. The key is the audio session key, not the
	# house key; this file is the durable audio state dir's private copy (0600) and
	# the only place besides the child's environment that it is written.
	my $uplink = &audio_uplink_read();
	if (length $uplink && &_audio_plan_has_local_peer($plan)) {
		$doc->{uplink} = $uplink;
		$doc->{session_key} = &audio_session_key_read();
	}
	my $json = encode_json($doc);
	my $tmp  = "$path.tmp.$$";
	my $wrote = eval {
		open my $fh, '>', $tmp or die "open: $!";
		print {$fh} $json or die "write: $!";
		close $fh or die "close: $!";
		chmod 0600, $tmp;
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
#
# A PipeWire choice may name a card profile (Pro Audio is the one that made the
# gate pass). The profile belongs to the card, not to the pair, so it is saved
# separately and the pair stays `pipewire|default`. The card has to be free
# before it will change profile - an ALSA engine holds `hw:N,0` outright - so
# the startup copy is written first (the respawn is then the PipeWire one),
# the running engine is quit, and the profile is retried for a moment while
# the old child closes. The default output moves to the sink the new profile
# names, and a plan input whose node the profile renamed is cleared to the
# machine's default source rather than left silent.
sub audio_engine_device_write {
	my ($backend, $device, $profile, $card) = @_;
	$backend = '' if !defined $backend || ref $backend;
	$device  = '' if !defined $device || ref $device;
	return { ok => 0, error => 'choose an audio backend: alsa, pipewire or null' }
		unless $audio_backend_ok{$backend};
	return { ok => 0, error => 'choose a device for the backend' }
		unless length $device && $device =~ /\A[A-Za-z0-9_.:,-]+\z/;

	$profile = '' if !defined $profile || ref $profile;
	$card    = '' if !defined $card || ref $card;
	my $chosen;
	if ($backend eq 'pipewire' && length $profile) {
		require JawnOS::Platform::Audio;
		return { ok => 0, error => 'a PipeWire profile needs the card it belongs to' }
			unless length $card && $card =~ /\A[A-Za-z0-9][A-Za-z0-9_.:@+\-]*\z/;
		my $offered = JawnOS::Platform::Audio::card_profiles($card);
		return { ok => 0, error => "$profile is not a profile this card offers" }
			unless grep { $_->{id} eq $profile } @{ $offered || [] };
		$chosen = { card => $card, profile => $profile };
	}

	my $plan   = &audio_plan_read();
	my $manage = &audio_manage_read();
	&subs::setting_setter({
		app     => 'sound',
		setting => $audio_engine_device_setting,
		device  => &subs::device_setter(),
		value   => $backend . '|' . $device,
	});
	if ($chosen) {
		&_audio_engine_profile_write($chosen->{card}, $chosen->{profile});
	}
	else {
		&_audio_engine_profile_clear();
	}

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
	my $applied;
	if ($chosen) {
		my $first = $available
			? JawnOS::Audio::Engine::audio_engine_quit()
			: { ok => 1, skipped => 1, error => '' };
		my $set = &_audio_set_card_profile_wait($chosen->{card}, $chosen->{profile});
		return { ok => 0, error => "the card did not accept the $chosen->{profile} profile" }
			unless $set;
		&_audio_profile_repoint($chosen->{card});
		$applied = $first;
		if ($available && !$first->{'skipped'}) {
			# The respawn may have opened the sink the old profile named;
			# quit once more now that the default has moved.
			my $again = eval { JawnOS::Audio::Engine::audio_engine_quit() };
			$applied = $again if ref $again eq 'HASH' && $again->{'ok'};
		}
	}
	else {
		$applied = $available
			? JawnOS::Audio::Engine::audio_engine_quit()
			: { ok => 1, skipped => 1, error => '' };
	}
	return {
		ok => 1, backend => $backend, device => $device,
		($chosen ? ( profile => $chosen->{profile}, card => $chosen->{card} ) : ()),
		applied => $applied,
	};
}

# A card the engine has just let go may take a moment to close; a profile
# change is refused while it is held. One retry loop of a second is enough for
# the supervisor's quit, and a card that never answers is a real refusal.
sub _audio_set_card_profile_wait {
	my ($card, $profile) = @_;
	require JawnOS::Platform::Audio;
	for my $attempt (1 .. 10) {
		return 1 if JawnOS::Platform::Audio::set_card_profile($card, $profile);
		select undef, undef, undef, 0.1;
	}
	return 0;
}

# A profile renames the card's nodes, so the sink the engine should play out
# and the plan's input node both have to follow it. The default moves to the
# card's new playback sink; an input naming a node of the old profile is
# cleared, which means this machine's default source - the profile's new one.
sub _audio_profile_repoint {
	my ($card) = @_;
	require JawnOS::Platform::Audio;
	my $bus = $card;
	$bus =~ s/\Aalsa_card\.//;
	my ($sink) = grep { $_->{'id'} =~ /\Aalsa_output\.\Q$bus\E\./ }
		@{ JawnOS::Platform::Audio::devices('output') || [] };
	JawnOS::Platform::Audio::set_default('output', $sink->{'id'}) if $sink;

	my $saved = &audio_plan_read();
	my $changed = 0;
	foreach my $source (@{ $saved->{sources} || [] }) {
		next unless ( $source->{kind} || '' ) eq 'input';
		next unless JawnOS::Audio::Plan::audio_plan_on_this_machine($source->{machine});
		next unless defined $source->{node} && $source->{node} =~ /\Q$bus\E/;
		$source->{node} = '';
		$changed = 1;
	}
	eval { &audio_plan_write($saved) } if $changed;
	return;
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
