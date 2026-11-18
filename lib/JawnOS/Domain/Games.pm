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
	# The scan records each card's picture in the art index, so the one image
	# request per card is answered from a file instead of another tree walk.
	my $library = &JawnOS::Games::scan(&game_root(), { art_index => 1 });
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
	return &JawnOS::Games::art_path(&game_root(), $_[0]);
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

# Whether this card is one the browser player can start at all. The route asks
# before it draws a player, so a crafted id gets the note, not an empty canvas.
sub game_browser_runnable {
	require JawnOS::Games;
	return &JawnOS::Games::browser_runnable($_[0]);
}

sub game_browser_bundle {
	require JawnOS::Games;
	my ($id, $cache_dir) = @_;
	my $game = &game_by_id($id);
	return { ok => 0, error => 'That game is not in the library.' } unless ref $game eq 'HASH';
	$cache_dir = &subs::home('~/.cache/jawnos/dos-bundles')
		unless defined $cache_dir && length $cache_dir;
	return &JawnOS::Games::browser_bundle($game, $cache_dir);
}

# What a desk or a phone puts in the start menu's games shelf: one entry per
# card the browser can actually run. The handheld runs the shelf natively, so
# it is not offered a second launcher for the same file. The scan is cached for
# a minute and keyed on the ROM folders' mtimes, because the start menu is
# opened far more often than the games change.
my ($MENU_ENTRIES, $MENU_KEY, $MENU_AT);

sub game_menu_entries {
	my $device = &subs::device_setter() || '';
	return [] unless $device eq 'computer' || $device eq 'mobile';
	require JawnOS::Games;
	my $root = &game_root();
	my @root_stat = stat($root);
	my @dos_stat = stat("$root/dos");
	my $key = join ':', $root, ($root_stat[9] // 0), ($dos_stat[9] // 0);
	return $MENU_ENTRIES
		if ref $MENU_ENTRIES eq 'ARRAY' && defined $MENU_KEY
			&& $MENU_KEY eq $key && defined $MENU_AT && time - $MENU_AT < 60;
	# Keep the art index current, so a row's cover is one small file read and
	# not a tree walk behind every icon.
	my $library = &JawnOS::Games::scan($root, { art_index => 1 });
	my @entries;
	foreach my $game (@{ $library->{'games'} || [] }) {
		next unless &JawnOS::Games::browser_runnable($game);
		push @entries, {
			id => $game->{'id'},
			title => $game->{'title'},
			system => $game->{'system'},
			system_label => $game->{'system_label'},
			art => (defined $game->{'art'} && length $game->{'art'}) ? 1 : 0,
		};
	}
	$MENU_ENTRIES = \@entries;
	$MENU_KEY = $key;
	$MENU_AT = time;
	return $MENU_ENTRIES;
}

1;
