package JawnOS::Audio::SystemMix;

# The machine's ordinary audio while the engine plays it.
#
# A managed engine takes the machine's output: on ALSA it opens the card
# exclusively, and on the shared PipeWire backend it plays the machine's output
# itself. Either way Music, a video, a notification or a call needs a sink the
# engine can capture. This module makes a null sink, makes it the default
# output, and leaves the engine to capture that sink's monitor as its `device`
# source (engine/src/system_capture.rs). Off, or after a crash, the previous
# default comes back and the sink is unloaded
# (docs/studio-audio-roadmap.md §8-§9, D11).
#
# The state file is what makes the cleanup honest: it records the sink, the
# module id and the default it replaced, so a supervisor that is killed can be
# followed by one that puts the machine back. `ensure` and `remove` are
# idempotent; a machine with no pactl/PipeWire answers `skipped`, never a
# failure that would stop the plan from saving.
#
# The record is the fast path, not the only one. A boot wipe once deleted it
# while the sink lived on: `jawn_system` stayed the default with nothing
# capturing it (every app silent) and the hardware sink stayed pinned at unity,
# and `remove` answered `skipped`. So a removal with no state finds the
# null-sink module by the sink name it was loaded with, hands the default to a
# real sink, carries the mix's own level onto it (never a stored one, and never
# a mute), and unloads that module by id - the same machine the record would
# have restored.
#
# The WirePlumber rule is for an ALSA card only. A PipeWire device (`default`)
# names no card, so `ensure` makes just the sink and the default switch. The
# default the sink replaced is also the device a PipeWire engine must play out -
# never the sink itself, or it would capture its own output.
#
# The tray's volume follows the default sink. A null sink is born at the server
# default (100%), so `ensure` copies the replaced output's volume and mute onto
# it once, and raises that output to unity: the mix carries the person's level,
# the hardware sink only passes the engine's signal through. Leaving both at
# the same level applied it twice - the engine read the mix at V and played it
# out a sink still at V, so the room heard V squared.
#
# `ensure` is the same handover in the other direction, so it has the same
# order: the mix's level is written first, the default moves second, and only
# then is the hardware output raised to unity. Raising it before the switch
# lands a live app stream on full scale for however long `set-default-sink`
# takes, which a restart is heard as a burst of 100%. Each step is honest if it
# is cut short: a mix level with the default still on the output changes
# nothing anyone hears, and a default on the mix with the output still at the
# person's level is quiet twice over, never loud.
#
# `remove` is the handover, and its order is the whole point. Moving the
# default or unloading the sink lands a live app stream on the hardware output
# at once; if that output is still at the unity the engine held it at, the
# person hears a burst of full-scale audio until something lowers it. So the
# level is written first, the default moves second, and the sink is unloaded
# last, and the level written is the live mix's own - the loudness the person
# hears today, not the level the mix was born with. Every step leaves the
# machine somewhere honest if the process is killed in the middle (a stop is
# routinely cut short by the tree's stop sweep), including after a crash.
#
# This is deliberately the same `pactl` idiom JawnOS::Sco::Mixer already uses,
# through JawnOS::Platform::Audio::run so a test can inject the tool and a
# machine without it behaves as if there were nothing to do.

use strict;
use warnings;

use File::Path qw(make_path);
use JSON::PP ();
use Time::HiRes qw(sleep);

use JawnOS::Platform::Audio ();

our $system_sink   = 'jawn_system';
our $system_source = 'jawn_system.monitor';
our $state_name    = 'audio-system-mix.json';

# The receptionist's virtual handset publishes the screened call here
# (lib/JawnOS/Sco/Mixer.pm). A plan source of kind `handset` taps it; the
# supervisor names it on every start and the engine binds it only when the plan
# asks, so an ordinary machine starts no extra capture.
our $handset_source = 'jawn_call_in.monitor';

# The WirePlumber drop-in that frees the card's playback node while the engine
# owns it. It lives beside the machine's other WirePlumber rules, and the
# marker is how `remove` tells this module's rule from a person's file.
our $managed_card_name   = '51-jawnos-studio-card.conf';
our $managed_card_marker = '# managed by JawnOS Sound while the engine owns the card';

# Where the state lives. The caller passes the supervisor's state directory
# (`~/.president`); the domain derives the same one from the plan path. A test
# passes a tempdir.
sub state_path {
	my ($state_dir) = @_;
	return undef unless defined $state_dir && length $state_dir;
	return "$state_dir/$state_name";
}

# Is there a PulseAudio-compatible server and the tool to talk to it? A machine
# with neither has no system mix to make, and must not lose its plan over it.
sub available {
	return 0 unless JawnOS::Platform::Audio::which('pactl');
	# The platform module caches the first probe. A supervisor outlives a
	# PipeWire restart, so ask again before deciding there is no server.
	JawnOS::Platform::Audio::reset_backend();
	my $backend = JawnOS::Platform::Audio::backend();
	return ( $backend->{'kind'} || '' ) eq 'pactl' ? 1 : 0;
}

# Is this sink in the server's own listing right now? `undef` means the question
# cannot be asked (no pactl/server), so a caller does not drop a source it
# cannot check. The supervisor asks this of the source it is about to hand the
# engine: a name the server does not list is one `parec` can only retry
# forever against.
sub sink_present {
	my ($name) = @_;
	return undef unless defined $name && length $name;
	return undef unless available();
	my $sinks = _sinks();
	return $sinks->{$name} ? 1 : 0;
}

sub _read_state {
	my ($state_dir) = @_;
	my $path = state_path($state_dir);
	return undef unless defined $path && -s $path;
	open(my $fh, '<', $path) or return undef;
	local $/;
	my $raw = <$fh>;
	close $fh;
	my $doc = eval { JSON::PP->new->decode($raw) };
	return ref $doc eq 'HASH' ? $doc : undef;
}

sub _write_state {
	my ($state_dir, $doc) = @_;
	my $path = state_path($state_dir);
	return { ok => 0, error => 'the system mix has no state directory' }
		unless defined $path && length $path;
	eval { make_path($state_dir) };
	my $tmp = "$path.tmp.$$";
	my $wrote = eval {
		open(my $fh, '>', $tmp) or die "open: $!";
		print {$fh} JSON::PP->new->canonical->encode($doc) or die "write: $!";
		close $fh or die "close: $!";
		rename $tmp, $path or die "rename: $!";
		1;
	};
	unless ($wrote) {
		my $error = $@ || 'unknown error';
		unlink $tmp;
		return { ok => 0, error => "the system mix state could not be written: $error" };
	}
	return { ok => 1, path => $path };
}

sub _slurp {
	my ($path) = @_;
	return undef unless defined $path;
	open(my $fh, '<', $path) or return undef;
	local $/;
	my $text = <$fh>;
	close $fh;
	return defined $text ? $text : '';
}

# WirePlumber reads every `*.conf` under this directory. A test points
# JAWNOS_WIREPLUMBER_DIR at a tempdir; a machine uses its ordinary config home.
sub managed_card_dir {
	my $dir = $ENV{JAWNOS_WIREPLUMBER_DIR};
	return $dir if defined $dir && length $dir;
	my $home = $ENV{HOME};
	$home = eval { (getpwuid($<))[7] } || '.'
		unless defined $home && length $home;
	return "$home/.config/wireplumber/wireplumber.conf.d";
}

sub managed_card_path {
	return managed_card_dir() . '/' . $managed_card_name;
}

# `hw:N,0` (or the picker's `alsa|hw:N,0`) names a card, and so does the
# picker's stable spelling `hw:CODEC,0` — the card's ALSA id, which survives a
# reboot that renumbers the cards. The id is resolved to today's number here,
# every time, because the rule matches the numeric `alsa.card` property. A
# PipeWire or null device names no card, so there is no playback node to free.
sub _card_index {
	my ($device) = @_;
	return undef unless defined $device && length $device;
	my $name = $device;
	$name = $1 if $name =~ /\Aalsa\|(.+)\z/;
	return $1 if $name =~ /\A(?:hw|plughw):(\d+)(?:,\d+)?\z/;
	return &_card_index_for_id($1)
		if $name =~ /\A(?:hw|plughw):([A-Za-z][A-Za-z0-9_-]*)(?:,\d+)?\z/;
	return undef;
}

# The number a card's ALSA id has right now. An absent card file, or an id it
# does not list, answers undef: the caller reports "not an ALSA card" rather
# than guessing a card and writing a rule for the wrong one.
sub _card_index_for_id {
	my ($id) = @_;
	return undef unless defined $id && length $id;
	my $path = $ENV{JAWNOS_ASOUND_CARDS} || '/proc/asound/cards';
	open my $fh, '<', $path or return undef;
	while (my $line = <$fh>) {
		next unless $line =~ /^\s*(\d+)\s+\[([^\]]*)\]:/;
		my ($index, $short) = ($1, $2);
		$short =~ s/\s+\z//;
		return $index + 0 if lc $short eq lc $id;
	}
	close $fh;
	return undef;
}

sub _json_devices {
	my ($type) = @_;
	my $raw = JawnOS::Platform::Audio::run('pactl', '-f', 'json', 'list', $type);
	return undef unless defined $raw && length $raw;
	my $doc = eval { JSON::PP->new->decode($raw) };
	return ref $doc eq 'ARRAY' ? $doc : undef;
}

# One row names this card and carries the stream direction we want. If the
# stream property is absent, the node-name prefix (`alsa_output.` or
# `alsa_input.`) is the same fact; the opposite direction is never a candidate.
sub _node_from_json_devices {
	my ($rows, $card, $stream, $prefix) = @_;
	my $wanted = qr/\A\Q$prefix\E\./;
	my (@exact, @named);
	foreach my $row (@{$rows}) {
		next unless ref $row eq 'HASH';
		my $props = ref $row->{'properties'} eq 'HASH' ? $row->{'properties'} : {};
		my $row_card = $props->{'alsa.card'};
		$row_card = $row->{'alsa.card'} unless defined $row_card;
		next unless defined $row_card && "$row_card" eq "$card";
		my $name = $props->{'node.name'};
		$name = $row->{'name'} unless defined $name && length $name;
		next unless defined $name && length $name;
		my $row_stream = $props->{'api.alsa.pcm.stream'} // '';
		push @exact, $name if $row_stream eq $stream;
		push @named, $name if $name =~ $wanted;
	}
	return $exact[0] if @exact;
	return $named[0] if @named;
	return undef;
}

# Older pactl has no `-f json`. The long listing carries the same facts: each
# `Sink #N` or `Source #N` block names the node and prints its properties.
sub _node_from_text_devices {
	my ($text, $card, $header, $stream, $prefix) = @_;
	return undef unless defined $text && length $text;
	my @blocks = split /^\Q$header\E\s+#\d+\b.*$/m, $text;
	shift @blocks;
	my $wanted = qr/\A\Q$prefix\E\./;
	my (@exact, @named);
	foreach my $block (@blocks) {
		my ($name) = $block =~ /^\s*Name:\s*(\S+)\s*$/m;
		next unless defined $name && length $name;
		my ($row_card) = $block =~ /^\s*alsa\.card\s*=\s*"?(\d+)"?\s*$/m;
		next unless defined $row_card && $row_card eq "$card";
		my ($row_stream) = $block =~ /^\s*api\.alsa\.pcm\.stream\s*=\s*"?(\w+)"?\s*$/m;
		push @exact, $name if defined $row_stream && $row_stream eq $stream;
		push @named, $name if $name =~ $wanted;
	}
	return $exact[0] if @exact;
	return $named[0] if @named;
	return undef;
}

sub _playback_node {
	my ($card) = @_;
	my $rows = _json_devices('sinks');
	my $node = $rows
		? _node_from_json_devices($rows, $card, 'playback', 'alsa_output') : undef;
	if (!defined $node) {
		my $text = JawnOS::Platform::Audio::run('pactl', 'list', 'sinks');
		$node = _node_from_text_devices($text, $card, 'Sink', 'playback', 'alsa_output')
			if defined $text && length $text;
	}
	return $node;
}

sub _capture_node {
	my ($card) = @_;
	my $rows = _json_devices('sources');
	my $node = $rows
		? _node_from_json_devices($rows, $card, 'capture', 'alsa_input') : undef;
	if (!defined $node) {
		my $text = JawnOS::Platform::Audio::run('pactl', 'list', 'sources');
		$node = _node_from_text_devices($text, $card, 'Source', 'capture', 'alsa_input')
			if defined $text && length $text;
	}
	return $node;
}

# Map the engine's ALSA device to the PipeWire nodes it needs. `playback` is
# always required; `duplex` also requires the capture node because the plan
# routes a local input. A miss is a refusal, never a guessed rule: a wrong
# node name would disable an unrelated device and still not free the card.
# `known` names nodes from an earlier run, so a mode flip can map only the
# direction that was not already hidden from pactl by our own rule.
sub card_nodes {
	my ($device, $mode, $known) = @_;
	$mode = defined $mode && $mode eq 'duplex' ? 'duplex' : 'playback';

	my $card = _card_index($device);
	unless (defined $card) {
		my $shown = defined $device && length $device ? $device : '(none)';
		return {
			ok    => 0,
			error => "the engine device $shown is not an ALSA card (hw:N,0),"
				. ' so there are no nodes to free',
		};
	}

	my $playback = $known && defined $known->{'playback'} && length $known->{'playback'}
		? $known->{'playback'} : _playback_node($card);
	unless (defined $playback && length $playback) {
		return {
			ok => 0, card => $card, mode => $mode,
			error => "cannot find the PipeWire playback node for ALSA card $card;"
				. ' not writing a guessed WirePlumber rule',
		};
	}

	my $capture;
	if ($mode eq 'duplex') {
		$capture = $known && defined $known->{'capture'} && length $known->{'capture'}
			? $known->{'capture'} : _capture_node($card);
		unless (defined $capture && length $capture) {
			return {
				ok => 0, card => $card, mode => $mode,
				error => "the plan routes a local input, but there is no PipeWire"
					. " capture node for ALSA card $card; not writing a guessed"
					. ' WirePlumber rule',
			};
		}
	}

	return {
		ok => 1, card => $card, mode => $mode, device => $device,
		playback => $playback, ( defined $capture ? ( capture => $capture ) : () ),
	};
}

sub card_playback_node {
	my ($device) = @_;
	my $map = card_nodes($device, 'playback');
	return $map unless $map->{ok};
	return { %{$map}, node => $map->{playback} };
}

# A table's existing rule hides both nodes from pactl. That file is at this
# module's own path and names the engine's card, so it is adopted rather than
# refused: the node names it matches are the nodes we need.
sub _adopt_existing_rule {
	my ($device, $mode) = @_;
	$mode = defined $mode && $mode eq 'duplex' ? 'duplex' : 'playback';
	my $path = managed_card_path();
	return undef unless -e $path;
	my $text = _slurp($path);
	return undef unless defined $text && length $text;
	my @names = $text =~ /node\.name\s*=\s*"([^"]+)"/g;
	my ($playback) = grep { /\A~?alsa_output\./ } @names;
	my ($capture)  = grep { /\A~?alsa_input\./ } @names;
	return undef unless defined $playback;
	if ($mode eq 'duplex') {
		return undef unless defined $capture;
	}
	else {
		undef $capture;
	}
	my $card = _card_index($device);
	return {
		ok => 1, adopted => 1, card => $card, mode => $mode, device => $device,
		playback => $playback, ( defined $capture ? ( capture => $capture ) : () ),
	};
}

# A file at the managed path that names alsa_output/alsa_input is the engine's
# card rule (the table's hand-written one included), not an unrelated person's
# file. `remove` unlinks that kind rather than restoring it, because restoring
# it would leave the card hidden.
sub _rule_names_engine_card {
	my ($text) = @_;
	return 0 unless defined $text && length $text;
	return $text =~ /node\.name\s*=\s*"~?alsa_(?:output|input)\./ ? 1 : 0;
}

# Whether the plan needs the card's capture. This mirrors
# `Patchbay::wants_input`: a local `input` source with a channel and at least
# one non-muted, executable route (to a bus, or to a local bound
# interface/speakers). A device/handset source, a source for another machine,
# an unrouted input and a muted route all need playback only.
sub plan_mode {
	my ($plan, $machine) = @_;
	return 'playback' unless ref $plan eq 'HASH';
	require JawnOS::Audio::Plan;
	my $clean = eval { JawnOS::Audio::Plan::audio_plan_normalize($plan) };
	return 'playback' unless ref $clean eq 'HASH';

	my (%source, %sink, %bus);
	$source{ $_->{id} } = $_ for @{ $clean->{sources} || [] };
	$sink{ $_->{id} }   = $_ for @{ $clean->{sinks}   || [] };
	$bus{ $_->{id} }    = 1  for @{ $clean->{buses}   || [] };
	my $host = defined $machine ? "$machine" : '';

	foreach my $route (@{ $clean->{routes} || [] }) {
		next if $route->{'mute'};
		my $from = $source{ $route->{'from'} // '' } or next;
		next unless ( $from->{'kind'} // '' ) eq 'input';
		next unless _plan_on_this_machine( $from->{'machine'}, $host );
		next unless defined $from->{'channel'};

		my $to = $route->{'to'} // '';
		return 'duplex' if $bus{$to};

		my $sink = $sink{$to} or next;
		next unless _plan_on_this_machine( $sink->{'machine'}, $host );
		next unless ( $sink->{'kind'} // '' ) =~ /\A(?:interface|speakers)\z/;
		next unless defined $sink->{'channel'} && $sink->{'channel'} == 0;
		return 'duplex';
	}
	return 'playback';
}

# One rule for "is this plan node this machine's": a blank machine is this
# machine's older spelling, and a named one is local only when it is this host,
# case-insensitively. It lives in Plan beside the field, so the picker, the
# write path and this mode check cannot drift apart.
sub _plan_on_this_machine {
	my ($node_machine, $host) = @_;
	require JawnOS::Audio::Plan;
	return JawnOS::Audio::Plan::audio_plan_on_this_machine($node_machine, $host);
}

# The engine's reported mode and the plan's mode can disagree for one patch
# while an old engine is still running the previous plan. A capture rule during
# that window is harmless; a sink-only rule when the new plan needs capture
# makes the patch fail, so the union always keeps duplex.
sub mode_union {
	my (@modes) = @_;
	foreach my $mode (@modes) {
		return 'duplex' if defined $mode && $mode eq 'duplex';
	}
	return 'playback';
}

sub _rule_value {
	my ($value) = @_;
	$value = '' unless defined $value;
	$value =~ s/([\\"])/\\$1/g;
	return $value;
}

# `duplex` disables both nodes because the engine captures the microphone too;
# `playback` leaves the source with PipeWire so apps keep recording and the
# privacy indicator follows their use.
sub managed_card_text {
	my ($playback, $capture, $mode) = @_;
	$mode = defined $mode && $mode eq 'duplex' ? 'duplex' : 'playback';
	my $play = _rule_value($playback);
	my $matches = "      { node.name = \"$play\" }";
	my $comment;
	if ($mode eq 'duplex') {
		my $cap = _rule_value($capture);
		$matches .= "\n      { node.name = \"$cap\" }";
		$comment = "# The plan routes a local input, so the engine captures this card's\n"
			. "# microphone as well. Both nodes stay with the engine while manage is on.\n";
	}
	else {
		$comment = "# The engine owns this card's playback PCM while manage is on, so PipeWire\n"
			. "# must not open it. The microphone node is deliberately left to PipeWire:\n"
			. "# apps can still record through it, and the privacy indicator follows them.\n";
	}
	return $managed_card_marker . "\n" . $comment
		. "monitor.alsa.rules = [\n  {\n    matches = [\n$matches\n    ]\n"
		. "    actions = { update-props = { node.disabled = true } }\n  }\n]\n";
}

sub _atomic_write {
	my ($path, $text) = @_;
	require File::Basename;
	my $dir = File::Basename::dirname($path);
	eval { make_path($dir) };
	my $tmp = "$path.tmp.$$";
	my $wrote = eval {
		open(my $fh, '>', $tmp) or die "open: $!";
		print {$fh} $text or die "write: $!";
		close $fh or die "close: $!";
		rename $tmp, $path or die "rename: $!";
		1;
	};
	unless ($wrote) {
		my $error = $@ || 'unknown error';
		unlink $tmp;
		return { ok => 0, error => "the WirePlumber rule could not be written: $error" };
	}
	return { ok => 1, path => $path };
}

sub managed_card_is_ours {
	my ($path) = @_;
	my $text = _slurp($path);
	return 0 unless defined $text && length $text;
	return index($text, $managed_card_marker) >= 0 ? 1 : 0;
}

sub _systemctl_bin {
	return $ENV{JAWNOS_SYSTEMCTL} if exists $ENV{JAWNOS_SYSTEMCTL};
	return JawnOS::Platform::Audio::which('systemctl');
}

# WirePlumber only reads its rules at start, so the drop-in needs a restart.
# A machine without systemd (a container, a test) keeps the rule for the next
# natural start and says so; it never dies over it.
sub restart_wireplumber {
	my $bin = _systemctl_bin();
	unless (defined $bin && length $bin) {
		return {
			ok => 1, skipped => 1,
			note => 'no systemctl here: WirePlumber will read the card rule on its next start',
		};
	}
	my $rc = system($bin, '--user', 'restart', 'wireplumber');
	if ($rc == -1) {
		return { ok => 0, error => "cannot run $bin: $!" };
	}
	if ($rc != 0) {
		my $how = ($rc & 127) ? 'signal ' . ($rc & 127) : 'exit ' . ($rc >> 8);
		return { ok => 0, error => "systemctl --user restart wireplumber failed ($how)" };
	}
	return { ok => 1 };
}

# `systemctl --user restart wireplumber` returns before the card's nodes are
# back in the server's listing, so a removal that read the list once could miss
# the output it has to hand the level to - and a sink that appears after that
# moment is heard at the unity the engine held it at. Wait for the output
# (bounded: about a second, because an unplugged card never comes back), then
# the caller's own order of level, default and unload is the handover it was
# meant to be. With no name, any sink that is neither the mix nor a null sink
# counts.
sub _await_restored_output {
	my ($want) = @_;
	my $named = defined $want && length $want;
	my %null;
	unless ($named) {
		%null = map { $_->{'sink'} => 1 }
			grep { ref $_ eq 'HASH' && defined $_->{'sink'} } @{ _null_sink_modules() };
	}
	my $sinks = _sinks();
	for my $attempt (0 .. 39) {
		if ($named) {
			return $sinks if $sinks->{$want};
		}
		else {
			return $sinks
				if grep { $_ ne $system_sink && !/\Ajawn_call_in\z/ && !/\.monitor\z/ && !$null{$_} }
				keys %{$sinks};
		}
		last if $attempt == 39;
		# A short poll: the moment the node is listed is the moment a stream can
		# land on it, and the level write is what keeps that moment quiet.
		sleep 0.025;
		$sinks = _sinks();
	}
	return $sinks;
}

# Record the rule before writing it, so a crash between the two leaves enough
# for `remove` to find and undo. A file at the target path that names an ALSA
# playback/capture node is the engine's rule and is adopted (unlinked on
# removal). A file that clearly is not is captured verbatim and put back.
sub _install_managed_card {
	my ($state_dir, $map) = @_;
	my $path  = managed_card_path();
	my $state = _read_state($state_dir) || {};
	my $card  = ref $state->{'managed_card'} eq 'HASH' ? $state->{'managed_card'} : {};
	my $mode  = defined $map->{'mode'} && $map->{'mode'} eq 'duplex' ? 'duplex' : 'playback';

	my $previous_present = $card->{'previous_present'};
	my $previous         = $card->{'previous'};
	unless (defined $previous_present) {
		if (-e $path && !managed_card_is_ours($path)) {
			my $existing = _slurp($path);
			if (_rule_names_engine_card($existing)) {
				$previous_present = 0;
				undef $previous;
			}
			else {
				$previous         = $existing;
				$previous_present = 1;
			}
		}
		else {
			$previous_present = 0;
			undef $previous;
		}
	}
	# An earlier version captured the table's hand-written rule as if it were a
	# person's file. It is the engine's rule, so forget the backup and unlink.
	if ($previous_present && _rule_names_engine_card($previous)) {
		$previous_present = 0;
		undef $previous;
	}

	$card = {
		path             => $path,
		node             => $map->{'playback'},
		playback         => $map->{'playback'},
		card             => $map->{'card'},
		device           => $map->{'device'},
		mode             => $mode,
		previous_present => $previous_present ? 1 : 0,
		installed_at     => time,
	};
	$card->{'capture'} = $map->{'capture'} if defined $map->{'capture'};
	$card->{'previous'} = $previous if $previous_present && defined $previous;
	$state->{'managed_card'} = $card;
	my $recorded = _write_state($state_dir, $state);
	return $recorded unless $recorded->{ok};

	# A repeated ensure that already wrote the same rule must not restart the
	# session manager once a second; that would glitch every app's audio.
	my $text     = managed_card_text($map->{'playback'}, $map->{'capture'}, $mode);
	my $existing = -e $path ? _slurp($path) : undef;
	my $restart;
	if (defined $existing && $existing eq $text) {
		$restart = { ok => 1, skipped => 1, note => 'the card rule is already in place' };
	}
	else {
		my $written = _atomic_write($path, $text);
		return $written unless $written->{ok};
		$restart = restart_wireplumber();
	}

	my $restart_note = $restart->{note};
	$restart_note = $restart->{error}
		if !defined $restart_note && defined $restart->{error};
	$card->{'restarted'}    = $restart->{ok} ? 1 : 0;
	$card->{'restart_note'} = $restart_note if defined $restart_note;
	$state->{'managed_card'} = $card;
	_write_state($state_dir, $state);

	return {
		ok       => 1,
		path     => $path,
		node     => $map->{'playback'},
		playback => $map->{'playback'},
		( defined $map->{'capture'} ? ( capture => $map->{'capture'} ) : () ),
		mode     => $mode,
		card     => $map->{'card'},
		previous_present => $card->{'previous_present'},
		restart  => $restart,
		note     => $restart_note,
	};
}

sub _remove_managed_card {
	my ($state_dir, $state) = @_;
	my $card = ref $state->{'managed_card'} eq 'HASH' ? $state->{'managed_card'} : undef;
	return { ok => 1, skipped => 1 } unless $card;

	my $path = defined $card->{'path'} && length $card->{'path'}
		? $card->{'path'} : managed_card_path();
	my $acted   = 0;
	my $removed = 0;
	my $restored = 0;
	my $note;

	if (-e $path) {
		if (!managed_card_is_ours($path)) {
			$note = "$path is not this module's rule; leaving it alone";
		}
		elsif ($card->{'previous_present'}
			&& defined $card->{'previous'}
			&& !_rule_names_engine_card($card->{'previous'})) {
			my $previous = $card->{'previous'};
			my $wrote = _atomic_write($path, $previous);
			if ($wrote->{ok}) {
				$restored = 1;
				$acted    = 1;
			}
			else {
				$note = $wrote->{error};
			}
		}
		else {
			if (unlink $path) {
				$removed = 1;
				$acted   = 1;
			}
			else {
				$note = "cannot remove $path: $!";
			}
		}
	}
	else {
		# Already gone (a natural WirePlumber start, or a previous removal).
		$acted = 1;
	}

	my $restart = $acted ? restart_wireplumber() : { ok => 1, skipped => 1 };
	$restart->{note} = $note if defined $note && !defined $restart->{note};
	$restart->{error} = $note
		if defined $note && !defined $restart->{error} && !$restart->{ok};
	return {
		ok       => defined $note && !$acted ? 0 : 1,
		path     => $path,
		removed  => $removed,
		restored => $restored,
		restart  => $restart,
		( defined $note ? ( error => $note ) : () ),
	};
}

# The sinks in the server's own order. A removal with no state record has to
# pick one to hand the machine back to, and the server's order is the only
# preference it has; `_sinks` keeps the hash shape the rest of the module reads.
sub _sink_list {
	my $text = JawnOS::Platform::Audio::run('pactl', 'list', 'short', 'sinks');
	my @name;
	foreach my $line ( split /\n/, defined $text ? $text : '' ) {
		my @field = split /\t/, $line;
		push @name, $field[1] if @field > 1 && defined $field[1] && length $field[1];
	}
	return \@name;
}

sub _sinks {
	my $names = _sink_list();
	return { map { $_ => 1 } @{$names} };
}

# The sink a null-sink module was loaded with. Modules are matched on this
# rather than on a recorded id, and a sink that is any null module is not a
# hardware output to hand the machine back to (the reception handset is one).
sub _sink_name_in {
	my ($argument) = @_;
	return undef unless defined $argument && length $argument;
	foreach my $token ( split /\s+/, $argument ) {
		return $1 if $token =~ /\Asink_name=(.+)\z/;
	}
	return undef;
}

sub _module_from_short {
	my ($text) = @_;
	my @found;
	foreach my $line ( split /\n/, defined $text ? $text : '' ) {
		my @field = split /\t/, $line;
		next unless @field >= 2;
		my ($id, $name, $argument) = @field;
		next unless defined $id && $id =~ /\A\d+\z/;
		next unless defined $name && $name eq 'module-null-sink';
		push @found, { id => $id + 0, name => $name, sink => _sink_name_in($argument) };
	}
	return \@found;
}

sub _module_from_long {
	my ($text) = @_;
	my @found;
	my ($id, $name, $argument);
	my $keep = sub {
		return unless defined $id && defined $name && $name eq 'module-null-sink';
		push @found, { id => $id + 0, name => $name, sink => _sink_name_in($argument) };
	};
	foreach my $line ( split /\n/, defined $text ? $text : '' ) {
		if ( $line =~ /^Module #(\d+)/ ) {
			$keep->();
			($id, $name, $argument) = ($1, undef, undef);
			next;
		}
		next unless defined $id;
		$name     = $1 if $line =~ /^\s*Name:\s*(\S+)/;
		$argument = $1 if $line =~ /^\s*Argument:\s*(.*?)\s*$/;
	}
	$keep->();
	return \@found;
}

# Every null-sink module the server reports, short listing first and the long
# listing as the fallback for an older tool. A tool that answers neither gives
# an empty list, which simply means there is nothing to undo.
sub _null_sink_modules {
	my $short = JawnOS::Platform::Audio::run('pactl', 'list', 'short', 'modules');
	my $found = _module_from_short($short);
	return $found if ref $found eq 'ARRAY' && @{$found};
	my $long = JawnOS::Platform::Audio::run('pactl', 'list', 'modules');
	return _module_from_long($long);
}

# The output the mix replaced, when no record says which one it was: the first
# real sink the server lists, excluding ours and every other null sink. A
# reception handset's null sink is silent to play into, so it is not a
# candidate; a monitor is a capture end, not an output a person can hear.
sub _real_output {
	my ($order, $sinks, $null) = @_;
	$sinks ||= _sinks();
	$null  ||= {};
	foreach my $name ( @{ $order || _sink_list() } ) {
		next unless defined $name && length $name;
		next if $name eq $system_sink;
		next if $null->{$name};
		next if $sinks && !$sinks->{$name};
		next if $name =~ /\.monitor\z/;
		return $name;
	}
	return '';
}

sub _current_default {
	# The system mix only exists when `pactl` does, and the Pulse shim is what OS
	# apps follow. Ask it directly first: on PipeWire the generic backend probe
	# can see WirePlumber's view, which lags the shim's default by a moment and
	# made `ensure` believe a switch that had not happened.
	my $pactl = JawnOS::Platform::Audio::which('pactl');
	if ($pactl) {
		my $out = JawnOS::Platform::Audio::run('pactl', 'get-default-sink');
		my ($id) = defined $out ? $out =~ /^\s*(\S+)/ : ();
		return $id if defined $id && length $id;
	}
	my $name = JawnOS::Platform::Audio::default('output');
	$name = '' unless defined $name && !ref $name;
	# Older PulseAudio has no get-default-sink verb; its info line carries the
	# same fact. PipeWire's shim supports the verb, so this is only the fallback.
	if ( !length $name ) {
		my $info = JawnOS::Platform::Audio::run('pactl', 'info');
		($name) = $info =~ /^Default Sink:\s*(\S+)/m if defined $info;
		$name = '' unless defined $name && length $name;
	}
	return $name;
}

sub _unload {
	my ($module_id) = @_;
	return 0 unless defined $module_id && $module_id =~ /\A\d+\z/;
	JawnOS::Platform::Audio::run('pactl', 'unload-module', $module_id);
	return 1;
}

# The tray's volume control follows the default sink, so a null sink born at
# the server default would show 100% while the person still hears the level
# their hardware sink was at. Read the output being replaced once: its volume
# and its mute. App streams normally sit at 100%, so the sink is the master the
# tray is showing. Each half counts only if the server reports it (a sink that
# vanished answers nothing); with neither, the level is unknown and the caller
# must leave both sinks alone rather than guess one.
sub _read_output_level {
	my ($previous, $sinks) = @_;
	return undef unless defined $previous && length $previous;
	return undef if $previous eq $system_sink;
	return undef unless $sinks && $sinks->{$previous};

	my $volume = JawnOS::Platform::Audio::get_volume('output', $previous);
	my $mute   = JawnOS::Platform::Audio::get_mute('output', $previous);
	return undef unless defined $volume || defined $mute;
	return {
		( defined $volume ? ( volume => $volume ) : () ),
		( defined $mute   ? ( mute   => $mute )   : () ),
	};
}

# The output the engine plays through only passes the engine's signal on: the
# mix already holds the person's level. A second volume on the hardware sink
# would apply it twice, so it is held at 100% and unmuted while the mix lives.
sub _hold_output_unity {
	my ($previous, $sinks) = @_;
	return 0 unless defined $previous && length $previous;
	return 0 if $previous eq $system_sink;
	return 0 if $sinks && !$sinks->{$previous};
	JawnOS::Platform::Audio::set_volume('output', $previous, 100);
	JawnOS::Platform::Audio::set_mute('output', $previous, 0);
	return 1;
}

# The playback controls an interface tends to offer, in the order a person
# would reach for them. `amixer` names them per card, and a class-compliant
# interface with only a physical knob answers none — which is a fine answer.
our @card_mixer_controls = (
	'Master', 'PCM', 'Speaker', 'Headphone', 'Master Playback Volume',
);

# On an ALSA plan the engine opens the card's PCM directly, so the PipeWire
# sink's volume is not in the signal path at all; the card's own mixer is.
# Leaving that mixer where it was multiplies the person's level twice (a mix at
# 100% over a card at 30% is heard as 30%), and the hidden node gives them no
# way to see or move it. So the card's playback controls are read once and
# held at unity while the engine owns the card, and `remove` puts them back.
#
# `JAWNOS_AUDIO_SKIP_CARD_MIXER` exists for a test that models a card on a
# machine where a real one is present: it must not move the real card's levels.
sub card_mixer_skipped {
	return $ENV{'JAWNOS_AUDIO_SKIP_CARD_MIXER'} ? 1 : 0;
}

sub card_mixer_read {
	my ($card) = @_;
	return [] if card_mixer_skipped();
	return [] unless defined $card && $card =~ /\A\d+\z/;
	my @controls;
	foreach my $control (@card_mixer_controls) {
		my $out = JawnOS::Platform::Audio::run('amixer', '-c', $card, 'sget', $control);
		next unless defined $out && length $out;
		my ($volume) = $out =~ /\[(\d+)%\]/;
		next unless defined $volume;
		my ($switch) = $out =~ /\[(on|off)\]/i;
		push @controls, {
			control => $control,
			volume  => $volume + 0,
			muted   => ( defined $switch && lc $switch eq 'off' ) ? 1 : 0,
		};
	}
	return \@controls;
}

sub card_mixer_unity {
	my ($card, $controls) = @_;
	return 0 if card_mixer_skipped();
	return 0 unless defined $card && $card =~ /\A\d+\z/;
	my $did = 0;
	foreach my $control (@{ $controls || [] }) {
		next unless ref $control eq 'HASH' && defined $control->{'control'};
		JawnOS::Platform::Audio::run(
			'amixer', '-c', $card, 'sset', $control->{'control'}, '100%', 'unmute');
		$did = 1;
	}
	return $did;
}

sub card_mixer_restore {
	my ($card, $controls) = @_;
	return 0 if card_mixer_skipped();
	return 0 unless defined $card && $card =~ /\A\d+\z/;
	my $did = 0;
	foreach my $control (@{ $controls || [] }) {
		next unless ref $control eq 'HASH' && defined $control->{'control'};
		next unless defined $control->{'volume'};
		JawnOS::Platform::Audio::run(
			'amixer', '-c', $card, 'sset', $control->{'control'},
			$control->{'volume'} . '%',
			$control->{'muted'} ? 'mute' : 'unmute',
		);
		$did = 1;
	}
	return $did;
}

# Give the mix the person's level. It is written before the switch: a null sink
# is born at the server's 100%, and a stream that lands on it the moment the
# default moves must find the person's loudness already there. The hardware
# output is deliberately not touched here - it is raised only after the default
# has left it (see `ensure`).
sub _apply_mix_level {
	my ($level) = @_;
	return 0 unless ref $level eq 'HASH';
	my $did = 0;
	$did = 1 if defined $level->{'volume'}
		&& JawnOS::Platform::Audio::set_volume('output', $system_sink, $level->{'volume'});
	$did = 1 if defined $level->{'mute'}
		&& JawnOS::Platform::Audio::set_mute('output', $system_sink, $level->{'mute'});
	return $did;
}

# Put the output's own level back, whether `remove` is undoing a live mix or one
# a crash left behind. Without this the hardware sink would stay pinned at 100%
# and the person's next ordinary playback would be much louder than before.
sub _restore_output_level {
	my ($previous, $saved, $sinks) = @_;
	return 0 unless ref $saved eq 'HASH';
	return 0 unless defined $previous && length $previous;
	return 0 if $previous eq $system_sink;
	return 0 if $sinks && !$sinks->{$previous};
	my $did = 0;
	$did = 1 if defined $saved->{'volume'}
		&& JawnOS::Platform::Audio::set_volume('output', $previous, $saved->{'volume'});
	$did = 1 if defined $saved->{'mute'}
		&& JawnOS::Platform::Audio::set_mute('output', $previous, $saved->{'mute'});
	return $did;
}

# The level to carry off the mix. The live sink answers first, because it is
# the loudness the person hears today: `ensure` copied the output's level into
# the mix when it was made, so an untouched mix answers the record exactly, and
# one the person moved answers what they moved it to. A key the server will not
# report falls back to the saved level rather than being guessed.
sub _handover_level {
	my ($saved, $sinks) = @_;
	my $level = ref $saved eq 'HASH' ? { %{$saved} } : {};
	if ( $sinks && $sinks->{$system_sink} ) {
		my $volume = JawnOS::Platform::Audio::get_volume('output', $system_sink);
		my $mute   = JawnOS::Platform::Audio::get_mute('output', $system_sink);
		$level->{'volume'} = $volume if defined $volume;
		$level->{'mute'}   = $mute   if defined $mute;
	}
	return %{$level} ? $level : undef;
}

# Create the sink if it is not there, remember the default it replaced, and
# make it the default. Repeating this while it is already active changes
# nothing. The switch is verified rather than trusted: `set-default-sink` can
# return before the server has moved the default, and reporting success then
# would strand a later run on a sink that is not the output.
sub ensure {
	my ($state_dir, $device, $mode) = @_;
	$mode = defined $mode && $mode eq 'duplex' ? 'duplex' : 'playback';
	unless (available()) {
		return {
			ok => 0, skipped => 1,
			error => 'no pactl or PulseAudio/PipeWire server: the machine keeps its ordinary output',
		};
	}

	# The card rule is for a card only. `hw:N,0` (or the picker's
	# `alsa|hw:N,0`) names one; a PipeWire device such as `default` names no
	# card, so it gets the sink and the switch and no WirePlumber rule.
	my $card = defined $device && length $device ? _card_index($device) : undef;

	# Find the nodes before touching anything. A miss must leave the machine
	# exactly as it was, because a guessed rule would disable the wrong device
	# and still not free the card. A rule we wrote already hides its nodes from
	# pactl, so an earlier state supplies them and only a mode change maps the
	# direction that was not hidden.
	my $mapping;
	if (defined $card) {
		my $state = _read_state($state_dir);
		my $known = $state && ref $state->{'managed_card'} eq 'HASH'
			? $state->{'managed_card'} : undef;
		my $path  = managed_card_path();
		my $reuse;
		if ($known && defined $card
			&& "$card" eq "" . ( $known->{'card'} // '' )
			&& $path eq ( $known->{'path'} // '' )
			&& managed_card_is_ours($path)) {
			$reuse = {
				playback => defined $known->{'playback'}
					? $known->{'playback'} : $known->{'node'},
				capture  => $known->{'capture'},
			};
		}
		$mapping = card_nodes($device, $mode, $reuse);
		unless ($mapping->{ok}) {
			# The table's hand-written both-direction rule is at this module's
			# own path; adopt its node names rather than refuse a hidden card.
			my $adopted = _adopt_existing_rule($device, $mode);
			$mapping = $adopted if $adopted;
		}
		return { ok => 0, error => $mapping->{'error'} } unless $mapping->{ok};
	}

	my $state     = _read_state($state_dir);
	my $had_state = $state ? 1 : 0;
	$state ||= {};

	# The output the sink replaces is also the device a PipeWire engine must
	# play through. Resolve it before the sink exists - it is the ordinary
	# output, not ours - and refuse a mix we cannot play out of: an engine left
	# on `default` after the switch would open this sink and capture itself.
	my $previous = $state->{'previous_default'};
	if ( !defined $previous || !length $previous ) {
		$previous = _current_default();
		# If our sink is already the default and no state explains why, there
		# is no previous output to name; PulseAudio picks one when it goes.
		$previous = '' if $previous eq $system_sink;
	}
	if ( !defined $card && defined $device && length $device
		&& !length $previous ) {
		# An active mix with no named output is exactly the state that would
		# loop; hand the machine back instead of keeping it.
		remove($state_dir) if $had_state;
		return {
			ok => 0,
			error => "$system_sink is already the default output and no earlier"
				. ' output is recorded; not playing the engine into its own capture',
		};
	}

	my $sinks     = _sinks();
	my $created   = 0;
	my $module_id = $state->{'module_id'};

	unless ( $sinks->{$system_sink} ) {
		my $out = JawnOS::Platform::Audio::run(
			'pactl', 'load-module', 'module-null-sink', "sink_name=$system_sink"
		);
		($module_id) = defined $out ? $out =~ /(\d+)/ : ();
		unless ( defined $module_id && length $module_id ) {
			return { ok => 0, error => "cannot create the $system_sink null sink" };
		}
		$created = 1;
	}

	# A sink this call created, or one it finds with no state of its own, is
	# new to the person's ears and to the tray: the mix takes the level of the
	# output it replaced. A repeated ensure keeps the state, so it never
	# overwrites a volume the person has since set on the live mix. Read before
	# writing anything: the state records what `remove` must put back, so the
	# raise below can never outlive its own cleanup.
	my $adopt = $created || !$had_state;
	my $read  = $adopt ? _read_output_level($previous, $sinks) : undef;
	my $saved_level;
	if ($read) {
		$saved_level = {
			( defined $read->{'volume'} ? ( volume => $read->{'volume'} ) : () ),
			( defined $read->{'mute'}   ? ( mute   => $read->{'mute'} )   : () ),
		};
	}

	my $doc = {
		%{$state},
		sink             => $system_sink,
		source           => $system_source,
		previous_default => $previous,
		module_id        => $module_id,
		created_at       => time,
		( $saved_level ? ( previous_level => $saved_level ) : () ),
	};
	my $wrote = _write_state($state_dir, $doc);
	return $wrote unless $wrote->{ok};

	# The person's level goes onto the mix, and nowhere else yet. A repeat
	# ensure must not re-apply it, so only an adopted level is written; the
	# hardware output is raised to unity after the switch below, never before.
	if ($read) {
		_apply_mix_level($read);
	}

	# What the person's tray now shows, and why it could not be adopted.
	my $level = $read
		? { ok => 1, %{$read} }
		: $adopt
		? {
			ok    => 0,
			error => 'the level of ' . ( length $previous ? $previous : 'the replaced output' )
				. ' cannot be read; the mix and the output keep the levels they have',
		}
		: undef;

	my $current  = _current_default();
	my $switched = 1;
	if ( $current ne $system_sink ) {
		$switched = JawnOS::Platform::Audio::set_default('output', $system_sink) ? 1 : 0;
		$current  = _current_default();
	}

	# The hardware run that found this: the sink was loaded and
	# `set-default-sink` answered 0, but `get-default-sink` still named the
	# built-in card, so the next run could not move it. Give the server a
	# moment to settle and ask for the switch once more.
	if ( !$switched || $current ne $system_sink ) {
		sleep 0.15;
		$switched = JawnOS::Platform::Audio::set_default('output', $system_sink) ? 1 : 0;
		$current  = _current_default();
	}

	if ( !$switched || $current ne $system_sink ) {
		# A sink this call created has no owner once we give up on it. An
		# earlier state still records a loaded sink and its module id, so it is
		# kept for `remove` to clean later rather than forgetting the id.
		# The hardware output was never raised - that happens only after a
		# verified switch - so there is no level to put back here.
		if ($created) {
			_unload($module_id);
			my $path = state_path($state_dir);
			unlink $path if defined $path && -e $path;
		}
		elsif ( !$had_state ) {
			my $path = state_path($state_dir);
			unlink $path if defined $path && -e $path;
		}
		my $still = length $current ? $current : 'another output';
		return {
			ok    => 0,
			error => "$system_sink did not become the default output; the machine is still on $still",
		};
	}

	# The card rule goes on last, after the sink is the default, so the desk's
	# audio has somewhere to land the moment PipeWire lets the card go.
	my $card_rule;
	if ($mapping) {
		$card_rule = _install_managed_card($state_dir, $mapping);
		unless ($card_rule->{ok}) {
			# A sink this call created must not stay behind with no engine and
			# no freed card. State from an earlier run keeps its module id for a
			# later `remove` instead.
			if ($created) {
				if (length $previous && $previous ne $system_sink) {
					JawnOS::Platform::Audio::set_default('output', $previous);
				}
				_unload($module_id);
				my $path = state_path($state_dir);
				unlink $path if defined $path && -e $path;
			}
			return { ok => 0, error => $card_rule->{error} };
		}
	}

	# Only now, with the default off the hardware output, is that output raised.
	# Every stream that was playing there landed on the mix at the person's
	# level when the default moved, so unity now scales the engine's own signal
	# alone. This is the mirror of `remove`: the mix's level first, the default
	# second, the output raised (or unloaded) last.
	if ( $read || ( !$created && $had_state
		&& ref $state->{'previous_level'} eq 'HASH' ) ) {
		_hold_output_unity($previous, $sinks);
	}

	# The card's mixer, for the ALSA path the sink volume does not reach. The
	# levels are recorded before anything is moved, and only once: a repeat
	# ensure re-applies unity but keeps the first reading, so `remove` always
	# has the levels the person actually had. If the record cannot be written,
	# the card is left alone rather than held blind.
	if (defined $card) {
		my $mixer = ref $state->{'previous_mixer'} eq 'HASH'
			? $state->{'previous_mixer'} : undef;
		$mixer = undef if $mixer && "" . ( $mixer->{'card'} // '' ) ne "" . $card;
		unless ($mixer) {
			my $controls = card_mixer_read($card);
			if ( @{$controls} ) {
				my $candidate = { card => $card, controls => $controls };
				$doc->{'previous_mixer'} = $candidate;
				my $recorded = _write_state($state_dir, $doc);
				$mixer = $recorded->{'ok'} ? $candidate : undef;
			}
		}
		card_mixer_unity($card, $mixer->{'controls'}) if $mixer;
	}

	return {
		ok               => 1,
		sink             => $system_sink,
		source           => $system_source,
		previous_default => $previous,
		# Where the engine must play out: the output this sink replaced. A
		# PipeWire engine given `default` would resolve to the sink above.
		playback_device  => $previous,
		module_id        => $module_id,
		created          => $created,
		( $level ? ( level => $level ) : () ),
		( $card_rule ? ( managed_card => $card_rule ) : () ),
	};
}

# A removal with no record. The state file is the fast path, but losing it must
# not strand the machine: the sink is still the default, nothing captures it, and
# the hardware sink may still be held at unity. Find the module by the sink name
# it was loaded with, hand the default back to a real output, carry the mix's own
# level onto that output (the person's loudness was moved onto the mix), unmute,
# and unload by id. Safe on a machine that has no null sink at all: it answers
# `skipped` and touches nothing.
sub _recover_without_state {
	my ($state_dir) = @_;

	# The card rule is independent of the Pulse shim, the same as the recorded
	# path. Only a rule that is actually on disk is looked at: an absent one has
	# nothing to undo, and a needless WirePlumber restart glitches every app.
	my $card = { ok => 1, skipped => 1 };
	my $rule_path = managed_card_path();
	if ( defined $rule_path && -e $rule_path ) {
		$card = _remove_managed_card($state_dir, { managed_card => { path => $rule_path } });
	}

	my $nothing = {
		ok => 1, skipped => 1, error => '',
		( $card->{'removed'} || $card->{'restored'} ? ( managed_card => $card ) : () ),
	};
	return $nothing unless available();

	# A rule removal restarts WirePlumber, whose nodes can be back only after
	# the server has answered `systemctl`. Wait for a real output before the
	# listing picks one, or the level is skipped and the node returns at unity.
	_await_restored_output(undef)
		if ref $card->{'restart'} eq 'HASH'
		&& $card->{'restart'}->{'ok'}
		&& !$card->{'restart'}->{'skipped'};

	my $order   = _sink_list();
	my $sinks   = { map { $_ => 1 } @{$order} };
	my $modules = _null_sink_modules();
	my ($module) = grep {
		ref $_ eq 'HASH' && defined $_->{'sink'} && $_->{'sink'} eq $system_sink
	} @{$modules};
	return $nothing unless $module;
	my %null = map {
		ref $_ eq 'HASH' && defined $_->{'sink'} ? ( $_->{'sink'} => 1 ) : ()
	} @{$modules};

	# Read the mix's level while the sink is still here; it is the only copy of
	# the loudness the person hears today.
	my $volume = JawnOS::Platform::Audio::get_volume('output', $system_sink);

	my $current  = _current_default();
	my $target   = '';
	if ( $current eq $system_sink ) {
		$target = _real_output($order, $sinks, \%null);
	}
	elsif ( length $current && $current ne $system_sink && $sinks->{$current} ) {
		# Something already handed the default back; the level still goes there.
		$target = $current;
	}

	# Carry the level before the default moves: the same reason as the recorded
	# path, and a crash is where an interrupted handover is most likely. The
	# mix may have been muted; the machine handed back must not be.
	my $carry = sub {
		my ($where) = @_;
		return 0 unless length $where && $where ne $system_sink && $sinks->{$where};
		my $did = 0;
		$did = 1
			if defined $volume
			&& JawnOS::Platform::Audio::set_volume('output', $where, $volume);
		JawnOS::Platform::Audio::set_mute('output', $where, 0);
		return $did;
	};
	my $level_restored = $carry->($target);

	my $restored = 0;
	if ( $current eq $system_sink && length $target ) {
		$restored = JawnOS::Platform::Audio::set_default('output', $target) ? 1 : 0;
		# A server that put the default somewhere else still gets the level.
		my $after = _current_default();
		if ( length $after && $after ne $system_sink && $after ne $target ) {
			$level_restored = $carry->($after) || $level_restored;
		}
	}

	my $unloaded = _unload($module->{'id'});
	if ( _sinks()->{$system_sink} ) {
		return {
			ok => 0, recovered => 1, restored => $restored, unloaded => $unloaded,
			level_restored => $level_restored, managed_card => $card,
			error => "the $system_sink sink is still loaded",
		};
	}

	my $path = state_path($state_dir);
	unlink $path if defined $path && -e $path;
	return {
		ok => 1, recovered => 1, restored => $restored, unloaded => $unloaded,
		level_restored => $level_restored, managed_card => $card,
		( defined $volume ? ( level => $volume ) : () ),
		note => 'the system mix was found without its state file;'
			. ' the default output, its level and the module are back',
	};
}

# Put the previous default back and unload our sink. A state file with no sink
# (the server restarted, or a crash happened between the two writes) still
# restores the default and then goes away. No state at all is recovered from the
# server's own module list.
sub remove {
	my ($state_dir) = @_;
	my $state = _read_state($state_dir);
	return _recover_without_state($state_dir) unless $state;

	my $previous   = $state->{'previous_default'} // '';
	my $module_id  = $state->{'module_id'} // '';
	my $saved_level = $state->{'previous_level'};

	# Read the live mix's level while it is still the default and still in the
	# listing: it is the loudness the person hears today, the card's restart does
	# not change it, and every call made after the nodes come back is time a
	# stream can spend on the output at unity.
	my $handover = available() ? _handover_level($saved_level, _sinks()) : undef;

	# The rule is independent of the Pulse shim: a machine whose server is down
	# still gets its card back, and a person's file is never unlinked.
	my $card = _remove_managed_card($state_dir, $state);

	my $restored   = 0;
	my $level_restored = 0;
	my $unloaded   = 0;

	my $sinks = {};
	if ( available() ) {
		# A rule removal restarts WirePlumber, and the server can answer before
		# the card's nodes are rebuilt. The output this removal hands the level
		# to is one of those nodes: wait for it rather than skip the write and
		# leave it at the unity the engine held.
		$sinks = ( ref $card eq 'HASH' && ref $card->{'restart'} eq 'HASH'
			&& $card->{'restart'}->{'ok'}
			&& !$card->{'restart'}->{'skipped'} )
			? _await_restored_output( length $previous ? $previous : undef )
			: _sinks();
	}
	# The card's mixer was held at unity while the engine owned it on ALSA.
	# Put the levels it had back first: the live mix level written below is the
	# person's current loudness and wins when the server can read it, and this
	# is the fallback when it cannot.
	if ( ref $state->{'previous_mixer'} eq 'HASH' ) {
		card_mixer_restore(
			$state->{'previous_mixer'}{'card'},
			$state->{'previous_mixer'}{'controls'},
		);
	}
	# The mix carried the person's level while the hardware sink played at
	# unity. Write that level back before the default moves: whatever stream
	# lands on the output next must already find the person's level there, or
	# it is heard at the unity the engine was holding. The live mix is the
	# copy to read - `previous_level` only remembers what the mix was born
	# with, and the tray may have moved since.
	if ($handover) {
		$level_restored = _restore_output_level($previous, $handover, $sinks);
	}
	if ( length $previous && $previous ne $system_sink && $sinks->{$previous} ) {
		$restored = JawnOS::Platform::Audio::set_default('output', $previous) ? 1 : 0;
	}
	# Last: the unload is what moves the sink's streams to the output whose
	# level was just set.
	if ( available() ) {
		$unloaded = _unload($module_id);
	}

	# If the sink is still there after unload, keep the state so a later run
	# can retry rather than forgetting an id it may need.
	if ( available() && _sinks()->{$system_sink} ) {
		return {
			ok => 0, restored => $restored, unloaded => $unloaded,
			level_restored => $level_restored,
			managed_card => $card,
			error => "the $system_sink sink is still loaded",
		};
	}

	my $path = state_path($state_dir);
	unlink $path if defined $path && -e $path;
	return {
		ok => 1, restored => $restored, unloaded => $unloaded,
		level_restored => $level_restored,
		managed_card => $card,
	};
}

# Read-only: what this machine has, for the Sound window and the supervisor's
# status file. It never creates, sets or unloads anything.
sub status {
	my ($state_dir) = @_;
	my $state = _read_state($state_dir);
	my $ready = available();
	my $sinks = $ready ? _sinks() : {};
	my $card  = $state && ref $state->{'managed_card'} eq 'HASH'
		? $state->{'managed_card'} : {};
	return {
		available   => $ready ? 1 : 0,
		sink        => $system_sink,
		source      => $system_source,
		active      => $state ? 1 : 0,
		present     => $sinks->{$system_sink} ? 1 : 0,
		previous    => $state ? ( $state->{'previous_default'} // '' ) : '',
		module_id   => $state ? ( $state->{'module_id'} // '' ) : '',
		current     => $ready ? _current_default() : '',
		card_rule   => $card->{'path'} // '',
		card_node   => $card->{'playback'} // $card->{'node'} // '',
		card_capture => $card->{'capture'} // '',
		card_mode   => $card->{'mode'} // '',
		card_card   => $card->{'card'} // '',
		card_written => ( defined $card->{'path'} && -e $card->{'path'} ) ? 1 : 0,
	};
}

1;
