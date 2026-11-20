package JawnOS::Audio::SystemMix;

# The machine's ordinary audio while the engine owns the interface.
#
# A managed engine opens the card exclusively, so Music, a video, a
# notification or a call has nowhere to go. This module makes a null sink,
# makes it the default output, and leaves the engine to capture that sink's
# monitor as its `device` source (engine/src/system_capture.rs). Off, or after
# a crash, the previous default comes back and the sink is unloaded
# (docs/studio-audio-roadmap.md §8-§9, D11).
#
# The state file is what makes the cleanup honest: it records the sink, the
# module id and the default it replaced, so a supervisor that is killed can be
# followed by one that puts the machine back. `ensure` and `remove` are
# idempotent; a machine with no pactl/PipeWire answers `skipped`, never a
# failure that would stop the plan from saving.
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
	my ($state_dir) = @_;
	unless (available()) {
		return {
			ok => 0, skipped => 1,
			error => 'no pactl or PulseAudio/PipeWire server: the machine keeps its ordinary output',
		};
	}

	my $state     = _read_state($state_dir);
	my $had_state = $state ? 1 : 0;
	$state ||= {};
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

	my $previous = $state->{'previous_default'};
	if ( !defined $previous || !length $previous ) {
		$previous = _current_default();
		# If our sink is already the default and no state explains why, there
		# is no previous output to name; PulseAudio picks one when it goes.
		$previous = '' if $previous eq $system_sink;
	}

	my $doc = {
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

	return {
		ok               => 1,
		sink             => $system_sink,
		source           => $system_source,
		previous_default => $previous,
		module_id        => $module_id,
		created          => $created,
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
			error => "the $system_sink sink is still loaded",
		};
	}

	my $path = state_path($state_dir);
	unlink $path if defined $path && -e $path;
	return { ok => 1, restored => $restored, unloaded => $unloaded };
}

# Read-only: what this machine has, for the Sound window and the supervisor's
# status file. It never creates, sets or unloads anything.
sub status {
	my ($state_dir) = @_;
	my $state = _read_state($state_dir);
	my $ready = available();
	my $sinks = $ready ? _sinks() : {};
	return {
		available   => $ready ? 1 : 0,
		sink        => $system_sink,
		source      => $system_source,
		active      => $state ? 1 : 0,
		present     => $sinks->{$system_sink} ? 1 : 0,
		previous    => $state ? ( $state->{'previous_default'} // '' ) : '',
		module_id   => $state ? ( $state->{'module_id'} // '' ) : '',
		current     => $ready ? _current_default() : '',
	};
}

1;
