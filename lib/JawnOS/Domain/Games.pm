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

use Mojo::JSON qw(decode_json encode_json);
use Mojo::Util qw(url_escape b64_encode);
use File::Path ();

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

# ---- the shared library -----------------------------------------------------
#
# The house's shelf is the library. Every machine scans its own ~/roms, so the
# catalogue a peer asks for is simply this machine's shelf; a machine that wants
# a game asks for that one folder and nothing else is copied. No ROM bytes ride
# the record sync, which is what keeps a board's small disk out of it.
#
# A cover is small and a card without its picture looks broken, so covers travel
# with the catalogue itself (inline, bounded). The game does not.

our $GAME_PULL_CAP = 1_100 * 1024 * 1024;    # the most one game may be
our $GAME_ART_MAX = 128 * 1024;              # one cover, inline
our $GAME_ART_BUDGET = 6 * 1024 * 1024;      # covers in one catalogue

sub game_art_type {
	my ($path) = @_;
	my ($suffix) = (defined $path ? $path : '') =~ /\.([^.\/]+)$/;
	my %type = (png => 'image/png', jpg => 'image/jpeg', jpeg => 'image/jpeg', webp => 'image/webp', gif => 'image/gif');
	return $type{lc($suffix // '')} // 'application/octet-stream';
}

sub _game_slurp_bin {
	my ($path) = @_;
	return undef unless defined $path && length $path && -f $path;
	open my $fh, '<:raw', $path or return undef;
	local $/;
	my $bytes = <$fh>;
	close $fh;
	return $bytes;
}

# What one game's pull carries: the folder the card lives in (so a DOS game's
# .exe and .conf travel together) or the single file when it sits straight in
# the system folder, plus its cover when the cover is filed elsewhere under the
# same system. Members are relative to the games root.
sub game_pull_members {
	my ($game, $root) = @_;
	return () unless ref $game eq 'HASH';
	$root = defined $root ? $root : &game_root();
	my $file = $game->{'file'} // '';
	my $system = $game->{'system'} // '';
	return () unless length $file && length $system;
	my $prefix = "$root/$system/";
	return () unless index($file, $prefix) == 0;
	my $tail = substr($file, length $prefix);
	$tail =~ s{^/+}{};
	return () unless length $tail;
	my ($top) = split m{/}, $tail;
	return () unless defined $top && length $top && $top ne '.' && $top ne '..';
	my @members = ("$system/$top");
	my $art = $game->{'art'} // '';
	if (length $art && index($art, $prefix) == 0 && index($art, "$root/$system/$top/") != 0) {
		my $relative = substr($art, length($root));
		$relative =~ s{^/+}{};
		push @members, $relative if length $relative;
	}
	return @members;
}

# How big a pull will be, measured the way the tar is: a file's size, or a
# folder's whole contents.
sub game_members_size {
	my ($root, @members) = @_;
	my $total = 0;
	foreach my $member (@members) {
		my $path = "$root/$member";
		next unless -e $path;
		if (-f $path) { $total += -s $path || 0; next; }
		next unless -d $path;
		my @stack = ($path);
		while (@stack) {
			my $dir = pop @stack;
			next unless opendir(my $dh, $dir);
			foreach my $name (sort readdir $dh) {
				next if $name eq '.' || $name eq '..';
				my $child = "$dir/$name";
				next if -l $child;
				if (-d $child) { push @stack, $child; next; }
				$total += -s $child || 0 if -f $child;
			}
			closedir $dh;
		}
	}
	return $total;
}

# This machine's shelf as a peer reads it: what is here, how big a pull would
# be, and the cover inline so a card on the other machine is never blank.
sub game_peer_catalogue {
	my $library = &game_library();
	my (@games, $budget);
	$budget = $GAME_ART_BUDGET;
	foreach my $game (@{ $library->{'games'} || [] }) {
		next unless ref $game eq 'HASH' && defined $game->{'id'} && $game->{'id'} =~ /^[0-9a-f]{40}$/;
		my $root = &game_root();
		my @members = &game_pull_members($game, $root);
		next unless @members;
		my %row = (
			id => $game->{'id'},
			title => $game->{'title'},
			system => $game->{'system'},
			system_label => $game->{'system_label'},
			size => &game_members_size($root, @members),
		);
		my $art = $game->{'art'} // '';
		if (length $art && $budget > 0 && -f $art && (-s $art || 0) <= $GAME_ART_MAX) {
			my $bytes = &_game_slurp_bin($art);
			if (defined $bytes && length $bytes) {
				$row{'art'} = 'data:' . &game_art_type($art) . ';base64,' . b64_encode($bytes, '');
				$budget -= length $bytes;
			}
		}
		push @games, \%row;
	}
	return {
		ok => 1,
		signatorial => &subs::signatorial_designer(),
		hostname => &subs::machine_name(),
		games => \@games,
	};
}

# Pack one game into $tmp for a peer. The id is the only thing a caller sends;
# the members are derived from the scan, so no path from a request reaches tar.
sub game_serve_tar {
	my ($id, $tmp) = @_;
	return { ok => 0, error => 'That game is not in the library.' }
		unless defined $id && $id =~ /^[0-9a-f]{40}$/;
	my $root = &game_root();
	my $game = &game_by_id($id);
	return { ok => 0, error => 'That game is not in the library.' } unless ref $game eq 'HASH';
	my @members = &game_pull_members($game, $root);
	return { ok => 0, error => 'That game is not filed under a system folder.' } unless @members;
	my $size = &game_members_size($root, @members);
	return { ok => 0, error => 'That game is larger than a pull may carry.' } if $size > $GAME_PULL_CAP;
	return { ok => 0, error => 'Nothing to pack for that game.' } unless $size > 0;
	my $rc = system('tar', 'czf', $tmp, '-C', $root, @members);
	return { ok => 0, error => 'The game could not be packed.' } if $rc != 0;
	return { ok => 0, error => 'The pack came out empty.' } unless -s $tmp;
	return { ok => 1, path => $tmp, size => $size, members => \@members };
}

# Unpack a peer's game into this machine's shelf. The pack is checked before it
# is written: every member under a system folder, no absolute path, no `..`,
# and no link (a link could point out of the shelf and a later member would
# write through it). The same standoff code_sync_unpack uses for the tree.
sub game_unpack {
	my ($tmp) = @_;
	my $root = &game_root();
	return { ok => 0, error => 'The pack is not here.' } unless defined $tmp && -f $tmp;
	my @members;
	if (open(my $fh, '-|', 'tar', 'tzf', $tmp)) {
		while (defined(my $line = <$fh>)) { chomp $line; push @members, $line; }
		close $fh;
	}
	return { ok => 0, error => 'The pack could not be read.' } unless @members;
	my @types;
	if (open(my $tv, '-|', 'tar', 'tvzf', $tmp)) {
		while (defined(my $line = <$tv>)) { push @types, $line; }
		close $tv;
	}
	return { ok => 0, error => 'The pack could not be read.' } unless @types;
	foreach my $line (@types) {
		next if $line =~ /^\s/;   # the wrapped tail of a very long name
		return { ok => 0, error => 'The pack holds something that is not a file or a folder.' }
			unless $line =~ /^[-d]/;
	}
	my $top = '';
	foreach my $member (@members) {
		(my $name = $member) =~ s{^\./}{};
		next if $name eq '' || $name eq '.';
		return { ok => 0, error => 'The pack names a path outside the library.' }
			if $name =~ m{^/} || $name =~ m{(^|/)\.\.(/|$)};
		my ($first) = split m{/}, $name;
		return { ok => 0, error => 'The pack names a path outside the library.' }
			unless defined $first && $first =~ /^[A-Za-z0-9][A-Za-z0-9 ._-]*$/;
		$top = $first unless length $top;
	}
	return { ok => 0, error => 'The pack names no game folder.' } unless length $top;
	File::Path::make_path($root) unless -d $root;
	my $rc = system('tar', 'xzf', $tmp, '-C', $root);
	return { ok => 0, error => 'The game could not be unpacked.' } if $rc != 0;
	return { ok => 1, root => $root, system => $top };
}

# The catalogue every reachable machine offers, server first. A machine that is
# asleep is skipped quietly: a library that waits on a dead peer is worse than
# a shorter list.
sub game_house_library {
	my (@hosts, @games, %seen);
	my $self = &subs::signatorial_designer() // '';
	foreach my $row (@{ &subs::peer_candidates() }) {
		my $agent = eval { &subs::remote_agent_for($row->{'uuid'}) } || {};
		next if $agent->{'error'} || !$agent->{'manager'};
		my $url = $agent->{'manager'} . '/manager/games/peer_library?signatorial=' . url_escape($self);
		my $res = eval {
			$agent->{'ua'}->inactivity_timeout(5)->request_timeout(15)->connect_timeout(3)
				->max_response_size(16 * 1024 * 1024)->get($url)->result
		};
		next unless $res && $res->is_success;
		my $parsed = eval { decode_json($res->body) };
		next unless ref $parsed eq 'HASH' && ref $parsed->{'games'} eq 'ARRAY';
		my $host = $parsed->{'hostname'} // $row->{'hostname'} // '';
		push @hosts, { signatorial => $row->{'signatorial'}, hostname => $host };
		foreach my $game (@{ $parsed->{'games'} }) {
			next unless ref $game eq 'HASH' && defined $game->{'id'} && $game->{'id'} =~ /^[0-9a-f]{40}$/;
			next if $seen{ $game->{'id'} }++;
			push @games, { %{$game}, signatorial => $row->{'signatorial'}, hostname => $host };
		}
	}
	return { ok => 1, hosts => \@hosts, games => \@games };
}

# Pull one game from one machine into this machine's shelf. The pack is written
# beside the library first, so a transfer that dies halfway leaves no half a
# game on the shelf.
sub game_pull {
	my ($signatorial, $id) = @_;
	return { ok => 0, error => 'That is not a game.' }
		unless defined $id && $id =~ /^[0-9a-f]{40}$/;
	$signatorial = '' unless defined $signatorial;
	my ($row) = grep { ($_->{'signatorial'} // '') eq $signatorial } @{ &subs::peer_candidates() };
	return { ok => 0, error => 'That machine is not one the house can reach.' } unless $row;
	my $agent = eval { &subs::remote_agent_for($row->{'uuid'}) } || {};
	return { ok => 0, error => 'That machine could not be reached.' } if $agent->{'error'} || !$agent->{'manager'};
	my $url = $agent->{'manager'} . '/manager/games/serve?signatorial='
		. url_escape(&subs::signatorial_designer() // '') . '&id=' . $id;
	my $res = eval {
		$agent->{'ua'}->inactivity_timeout(30)->request_timeout(900)->connect_timeout(6)
			->max_response_size($GAME_PULL_CAP + (8 * 1024 * 1024))->get($url)->result
	};
	return { ok => 0, error => 'That machine did not answer.' } unless $res && $res->is_success;
	my $body = $res->body;
	return { ok => 0, error => 'The game arrived empty.' } unless defined $body && length $body;
	my $root = &game_root();
	File::Path::make_path($root) unless -d $root;
	my $temp = "$root/.pull-" . $$ . '-' . int(rand(1_000_000)) . '.tgz';
	open my $fh, '>:raw', $temp or return { ok => 0, error => 'The game could not be saved.' };
	my $wrote = print {$fh} $body;
	close $fh;
	unless ($wrote && -s $temp) { unlink $temp; return { ok => 0, error => 'The game could not be saved.' }; }
	my $unpacked = &game_unpack($temp);
	unlink $temp;
	return $unpacked unless $unpacked->{'ok'};
	return {
		ok => 1,
		id => $id,
		signatorial => $signatorial,
		system => $unpacked->{'system'},
		root => $unpacked->{'root'},
	};
}

1;
