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
# The WirePlumber rule is for an ALSA card only. A PipeWire device (`default`)
# names no card, so `ensure` makes just the sink and the default switch. The
# default the sink replaced is also the device a PipeWire engine must play out -
# never the sink itself, or it would capture its own output.
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

# `hw:N,0` (or the picker's `alsa|hw:N,0`) names a card. A PipeWire or null
# device names no card, so there is no playback node to free.
sub _card_index {
	my ($device) = @_;
	return undef unless defined $device && length $device;
	my $name = $device;
	$name = $1 if $name =~ /\Aalsa\|(.+)\z/;
	return $1 if $name =~ /\A(?:hw|plughw):(\d+)(?:,\d+)?\z/;
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

sub _plan_on_this_machine {
	my ($node_machine, $host) = @_;
	$node_machine = '' unless defined $node_machine;
	return 1 if $node_machine eq '';
	return lc($node_machine) eq lc($host) ? 1 : 0;
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

sub _sinks {
	my $text = JawnOS::Platform::Audio::run('pactl', 'list', 'short', 'sinks');
	my %name;
	foreach my $line ( split /\n/, $text ) {
		my @field = split /\t/, $line;
		$name{ $field[1] } = 1 if @field > 1 && length $field[1];
	}
	return \%name;
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

	my $doc = {
		%{$state},
		sink             => $system_sink,
		source           => $system_source,
		previous_default => $previous,
		module_id        => $module_id,
		created_at       => time,
	};
	my $wrote = _write_state($state_dir, $doc);
	return $wrote unless $wrote->{ok};

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
		( $card_rule ? ( managed_card => $card_rule ) : () ),
	};
}

# Put the previous default back and unload our sink. A state file with no sink
# (the server restarted, or a crash happened between the two writes) still
# restores the default and then goes away.
sub remove {
	my ($state_dir) = @_;
	my $state = _read_state($state_dir);
	unless ($state) {
		return { ok => 1, skipped => 1, error => '' };
	}

	# The rule is independent of the Pulse shim: a machine whose server is down
	# still gets its card back, and a person's file is never unlinked.
	my $card = _remove_managed_card($state_dir, $state);

	my $previous   = $state->{'previous_default'} // '';
	my $module_id  = $state->{'module_id'} // '';
	my $restored   = 0;
	my $unloaded   = 0;

	my $sinks = available() ? _sinks() : {};
	if ( length $previous && $previous ne $system_sink && $sinks->{$previous} ) {
		$restored = JawnOS::Platform::Audio::set_default('output', $previous) ? 1 : 0;
	}
	if ( available() ) {
		$unloaded = _unload($module_id);
	}

	# If the sink is still there after unload, keep the state so a later run
	# can retry rather than forgetting an id it may need.
	if ( available() && _sinks()->{$system_sink} ) {
		return {
			ok => 0, restored => $restored, unloaded => $unloaded,
			managed_card => $card,
			error => "the $system_sink sink is still loaded",
		};
	}

	my $path = state_path($state_dir);
	unlink $path if defined $path && -e $path;
	return {
		ok => 1, restored => $restored, unloaded => $unloaded,
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
