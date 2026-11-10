package subs;

# Games: the emulated library under the person's ~/roms.
#
# The scan and the system table live in JawnOS::Games, so the launcher, the
# install helper and the launch helper all read one list. This is the domain
# seam: the root is the person's own ~/roms, or JAWNOS_GAMES_ROOT for a test.
#
# Loaded on demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;

sub game_root {
	my $forced = $ENV{'JAWNOS_GAMES_ROOT'};
	return $forced if defined $forced && length $forced;
	return &subs::home('~/roms');
}

sub game_library {
	require JawnOS::Games;
	my $library = &JawnOS::Games::scan(&game_root());
	# One scan, then the saved per-system choice is laid over it. The scan's own
	# `chosen` is the default runner; a system the person has configured must show
	# that pick instead.
	if (ref $library eq 'HASH' && ref $library->{'systems'} eq 'ARRAY') {
		foreach my $system (@{ $library->{'systems'} }) {
			next unless ref $system eq 'HASH' && defined $system->{'id'};
			my $choice = &game_runner_choice($system->{'id'});
			$system->{'chosen'} = $choice if defined $choice;
		}
	}
	return $library;
}

sub game_by_id {
	require JawnOS::Games;
	return &JawnOS::Games::find(&game_root(), $_[0]);
}

sub game_art {
	require JawnOS::Games;
	my $game = &JawnOS::Games::find(&game_root(), $_[0]);
	return ($game && defined $game->{'art'}) ? $game->{'art'} : undef;
}

sub game_systems {
	require JawnOS::Games;
	return &JawnOS::Games::systems();
}

sub game_system_label {
	require JawnOS::Games;
	return &JawnOS::Games::system_label($_[0]);
}

sub game_core_path {
	require JawnOS::Games;
	return &JawnOS::Games::core_path($_[0]);
}

# The page-facing runner list: an id, what it is called, whether this machine
# can run it, and why not when it cannot. No core path or command leaves here.
sub game_runners {
	require JawnOS::Games;
	my @out;
	foreach my $runner (@{ &JawnOS::Games::runners_for($_[0]) }) {
		my %row = (
			id => $runner->{'id'},
			label => $runner->{'label'},
			available => $runner->{'available'} ? 1 : 0,
		);
		$row{'reason'} = $runner->{'reason'} if defined $runner->{'reason'} && length $runner->{'reason'};
		push @out, \%row;
	}
	return \@out;
}

# The runner saved for this device and this system, or the first one this
# machine can actually run. A saved id whose core has since been removed falls
# back rather than launching nothing.
sub game_runner_choice {
	require JawnOS::Games;
	my ($system) = @_;
	return undef unless defined $system && &JawnOS::Games::systems()->{$system};
	my $saved = &subs::setting_grabber({ app => 'games', setting => "runner_$system" });
	if (defined $saved && length $saved) {
		my $runner = &JawnOS::Games::runner_by_id($system, $saved);
		return $saved if ref $runner eq 'HASH' && $runner->{'id'} eq $saved && $runner->{'available'};
	}
	my $default = &JawnOS::Games::default_runner($system);
	return $default->{'id'} if ref $default eq 'HASH';
	return undef;
}

# Save the emulator this system should run on. A runner that is not in the
# table, or is in it but cannot run on this machine, is refused: the picker can
# show a disabled choice, but nothing may write it into the house settings.
sub game_runner_choose {
	require JawnOS::Games;
	my ($system, $runner_id) = @_;
	$system = '' unless defined $system;
	$runner_id = '' unless defined $runner_id;
	return { ok => 0, error => 'That is not a system this shelf knows.' }
		unless &JawnOS::Games::systems()->{$system};
	return { ok => 0, error => 'That is not an emulator for this system.' }
		unless length $runner_id;
	my $runner = &JawnOS::Games::runner_by_id($system, $runner_id);
	return { ok => 0, error => 'That is not an emulator for this system.' }
		unless ref $runner eq 'HASH' && $runner->{'id'} eq $runner_id;
	return { ok => 0, error => ($runner->{'reason'} || 'That emulator is not available on this machine.') }
		unless $runner->{'available'};
	&subs::setting_setter({ app => 'games', setting => "runner_$system", value => $runner_id });
	return { ok => 1, system => $system, runner => $runner_id, label => $runner->{'label'} };
}

# The launcher's install button exists because this machine has no RetroArch
# yet. Asking the filesystem is the honest answer, and the same one the action
# uses to refuse a launch with a sentence a person can act on.
sub game_runner {
	require JawnOS::Games;
	my $choice = &game_runner_choice($_[0]);
	return undef unless defined $choice;
	return &JawnOS::Games::runner_for($_[0], $choice);
}

sub game_emulator_present {
	require JawnOS::Games;
	return defined &JawnOS::Games::retroarch_binary() ? 1 : 0;
}

1;
