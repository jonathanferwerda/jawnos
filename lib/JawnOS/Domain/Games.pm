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
	return &JawnOS::Games::scan(&game_root());
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

# The launcher's install button exists because this machine has no RetroArch
# yet. Asking the filesystem is the honest answer, and the same one the action
# uses to refuse a launch with a sentence a person can act on.
sub game_runner {
	require JawnOS::Games;
	return &JawnOS::Games::runner_for($_[0]);
}

sub game_emulator_present {
	foreach my $path ('/usr/bin/retroarch', '/usr/local/bin/retroarch') {
		return 1 if -x $path;
	}
	return 0;
}

1;
