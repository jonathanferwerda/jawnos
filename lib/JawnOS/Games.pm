package JawnOS::Games;

# The emulated games shelf: the ROMs under ~/roms, the emulator each system
# needs, and the picture beside a title. Both the launcher and the two device
# helpers read this module, so the file a card shows is the file an emulator is
# handed, and the package list the install button runs is the list the launch
# helper looks in.
#
# The system names are the EmulationStation folders the retro images use, which
# is also how the ROMs are filed. A folder the table does not know still shows
# in the library; its card just has no emulator to run.

use strict;
use warnings;
use utf8;
use Digest::SHA qw(sha1_hex);
use File::Path qw(make_path);
use JSON::PP ();

our %SYSTEM = (
	nes         => { label => 'Nintendo', core => 'nestopia_libretro.so', package => 'libretro-nestopia' },
	snes        => { label => 'Super Nintendo', core => 'snes9x_libretro.so', package => 'libretro-snes9x' },
	gb          => { label => 'Game Boy', core => 'gambatte_libretro.so', package => 'libretro-gambatte' },
	gbc         => { label => 'Game Boy Color', core => 'gambatte_libretro.so', package => 'libretro-gambatte' },
	gba         => { label => 'Game Boy Advance', core => 'mgba_libretro.so', package => 'libretro-mgba' },
	n64         => { label => 'Nintendo 64', core => 'mupen64plus_next_libretro.so', package => 'libretro-mupen64plus-next' },
	gamegear    => { label => 'Game Gear', core => 'genesis_plus_gx_libretro.so', package => 'libretro-genesis-plus-gx' },
	mastersystem => { label => 'Master System', core => 'genesis_plus_gx_libretro.so', package => 'libretro-genesis-plus-gx' },
	megadrive   => { label => 'Mega Drive', core => 'genesis_plus_gx_libretro.so', package => 'libretro-genesis-plus-gx' },
	sega32x     => { label => '32X', core => 'picodrive_libretro.so', package => 'libretro-picodrive' },
	segacd      => { label => 'Sega CD', core => 'genesis_plus_gx_libretro.so', package => 'libretro-genesis-plus-gx' },
	saturn      => { label => 'Saturn', core => 'yabause_libretro.so', package => 'libretro-yabause' },
	psx         => { label => 'PlayStation', core => 'pcsx_rearmed_libretro.so', package => 'libretro-pcsx-rearmed' },
	psp         => { label => 'PlayStation Portable', core => 'ppsspp_libretro.so', package => '' },
	dreamcast   => { label => 'Dreamcast', core => 'flycast_libretro.so', package => 'libretro-flycast' },
	gc          => { label => 'GameCube', core => 'dolphin_libretro.so', package => 'libretro-dolphin' },
	dos         => { label => 'DOS', standalone => 'jawnos-dosbox', package => 'dosbox' },
	pcengine    => { label => 'PC Engine', core => 'mednafen_pce_libretro.so', package => 'libretro-beetle-pce' },
	pcenginecd  => { label => 'PC Engine CD', core => 'mednafen_pce_libretro.so', package => 'libretro-beetle-pce' },
	neogeo      => { label => 'Neo Geo', core => 'fbneo_libretro.so', package => '' },
	mame2003    => { label => 'Arcade', core => 'mame_libretro.so', package => 'libretro-mame' },
	atari2600   => { label => 'Atari 2600', core => 'stella_libretro.so', package => '' },
	atari5200   => { label => 'Atari 5200', core => 'atari800_libretro.so', package => '' },
	atari7800   => { label => 'Atari 7800', core => 'prosystem_libretro.so', package => '' },
	atarilynx   => { label => 'Atari Lynx', core => 'handy_libretro.so', package => '' },
	'3do'       => { label => '3DO', core => 'opera_libretro.so', package => '' },
	coleco      => { label => 'ColecoVision', core => 'bluemsx_libretro.so', package => '' },
	ngp         => { label => 'Neo Geo Pocket', core => 'mednafen_ngp_libretro.so', package => '' },
	ngpc        => { label => 'Neo Geo Pocket Color', core => 'mednafen_ngp_libretro.so', package => '' },
);

# The suffixes a ROM may carry. A zip or 7z is a whole ROM to RetroArch, so it
# belongs in the library; an image or a metadata file does not.
our @EXTENSION = qw(
	nes smc sfc fig swc gb gbc gba z64 n64 v64 ndd
	iso cue chd gdi cdi pbp cso rvz gcm wad bin img mdf mds
	32x sms gg sg md gen smd pce sgx ngp ngc col a26 a52 a78 lnx
	d64 g64 crt tap tzx z80 dsk zip 7z
	exe com bat conf
);

# The first directory wins, so the cores built beside the desktop-OpenGL
# frontend are found before the packaged ones: mupen64plus-next ships as the
# ParaLLEl/Vulkan build in the repositories, and that one renders nothing on a
# machine with no Vulkan device.
our @CORE_DIR = ('/opt/retroarch-gl/cores', '/usr/lib/libretro', '/usr/lib/retroarch/cores', '/usr/share/libretro/cores');

# The emulators a system may run on, in the order the page offers them. A
# system with no entry here has the one RetroArch runner its core names, so the
# table only grows where a machine has a real second choice. The N64 is the case
# that exists: the core built beside the desktop-GL frontend (`.so.opt`) is
# first because the packaged ParaLLEl/Vulkan build renders nothing without a
# Vulkan device, and the eMMC image carries a standalone mupen64plus that the
# kernel's missing Mali driver keeps from drawing.
our %RUNNERS = (
	n64 => [
		{ id => 'retroarch-opt', label => 'RetroArch (optimized build)', kind => 'retroarch', core => 'mupen64plus_next_libretro.so.opt' },
		{ id => 'retroarch', label => 'RetroArch (packaged core)', kind => 'retroarch', core => 'mupen64plus_next_libretro.so' },
		{
			id => 'stock', label => 'eMMC mupen64plus (needs Mali driver)', kind => 'standalone',
			command => '/opt/mupen64plus-stock/run.sh', args => [], blocked => 1,
			reason => 'The eMMC emulator renders through the Mali driver this kernel does not load.',
		},
	],
);


sub systems { return \%SYSTEM; }

sub system_label {
	my ($system) = @_;
	$system = '' unless defined $system;
	return $SYSTEM{$system}->{'label'} if $SYSTEM{$system};
	(my $label = $system) =~ s/_/ /g;
	$label =~ s/\b(\w)/\U$1/g;
	return length $label ? $label : 'Games';
}

# The system a dropped game belongs to, from its suffix. Only suffixes that
# name one system are here: a disc image or an archive is deliberately absent,
# since `.iso`, `.cue`, `.chd` and `.zip` can each be a PlayStation, a Saturn or
# a Dreamcast game. A folder named after a system is the person's own answer
# and wins over every suffix.
our %EXTENSION_SYSTEM = (
	nes => 'nes',
	smc => 'snes', sfc => 'snes', fig => 'snes', swc => 'snes',
	gb => 'gb', gbc => 'gbc', gba => 'gba',
	z64 => 'n64', n64 => 'n64', v64 => 'n64', ndd => 'n64',
	'32x' => 'sega32x', sms => 'mastersystem', gg => 'gamegear',
	md => 'megadrive', gen => 'megadrive', smd => 'megadrive',
	pce => 'pcengine', sgx => 'pcengine',
	ngp => 'ngp', ngc => 'ngpc', col => 'coleco',
	a26 => 'atari2600', a52 => 'atari5200', a78 => 'atari7800', lnx => 'atarilynx',
	exe => 'dos', com => 'dos', bat => 'dos', conf => 'dos',
	gdi => 'dreamcast', rvz => 'gc', gcm => 'gc', cso => 'psp', pbp => 'psp',
);

# What one dropped game is. A folder that names a system is a system folder
# and its files belong directly under it; otherwise every recognised suffix is
# a vote, and a tie (or no vote at all) is "cannot tell", never a guess.
sub system_for_paths {
	my ($folder, $paths) = @_;
	$folder = '' unless defined $folder;
	$paths = [] unless ref $paths eq 'ARRAY';
	return $folder if length $folder && $SYSTEM{$folder};
	my %vote;
	foreach my $path (@{$paths}) {
		next unless defined $path && length $path;
		my ($base) = $path =~ m{([^/]+)$};
		next unless defined $base;
		my ($suffix) = $base =~ /\.([^.]+)$/;
		next unless defined $suffix;
		my $system = $EXTENSION_SYSTEM{lc $suffix};
		next unless defined $system && $SYSTEM{$system};
		$vote{$system}++;
	}
	return undef unless keys %vote;
	my @ranked = sort { $vote{$b} <=> $vote{$a} || $a cmp $b } keys %vote;
	return undef if @ranked > 1 && $vote{$ranked[0]} == $vote{$ranked[1]};
	return $ranked[0];
}

# A cheap "has the shelf changed" answer: the root and every system folder's
# mtime. Adding or removing a game touches its system folder, so an open Games
# page can poll this without walking the ROMs.
sub revision {
	my ($root) = @_;
	$root = '' unless defined $root;
	my @root_stat = stat($root);
	return '0' unless @root_stat;
	my @parts = ($root_stat[9] // 0);
	if (opendir(my $dh, $root)) {
		foreach my $dir (sort grep { !/^\./ && -d "$root/$_" } readdir $dh) {
			my @stat = stat("$root/$dir");
			push @parts, $dir, ($stat[9] // 0);
		}
		closedir $dh;
	}
	return join(':', @parts);
}

sub core_for {
	my ($system) = @_;
	return undef unless defined $system && $SYSTEM{$system} && $SYSTEM{$system}->{'core'};
	return $SYSTEM{$system};
}

sub core_path_for {
	my ($file) = @_;
	return undef unless defined $file && length $file;
	foreach my $dir (@CORE_DIR) {
		my $path = "$dir/$file";
		return $path if -f $path;
	}
	return undef;
}

sub core_path {
	my ($system) = @_;
	my $entry = core_for($system);
	return undef unless $entry;
	return core_path_for($entry->{'core'});
}

# `standalone` in %SYSTEM may name a bare programme; a runner's `command` may be
# a path. Either way the answer is the executable itself, or undef.
sub _command_path {
	my ($command) = @_;
	return undef unless defined $command && length $command;
	return $command if $command =~ m{/} && -x $command;
	return undef if $command =~ m{/};
	foreach my $dir (split /:/, ($ENV{'PATH'} || '/usr/bin:/bin')) {
		next unless length $dir;
		return "$dir/$command" if -x "$dir/$command";
	}
	return undef;
}

# The descriptors before the filesystem is asked: every system has at least one,
# so one table row is enough for the page and the launcher to agree on an id.
sub _runner_specs {
	my ($system) = @_;
	return [] unless defined $system && $SYSTEM{$system};
	return [ map { { %{$_} } } @{ $RUNNERS{$system} } ] if $RUNNERS{$system};
	if ($SYSTEM{$system}->{'standalone'}) {
		return [ {
			id => 'standalone', label => 'Standalone', kind => 'standalone',
			command => $SYSTEM{$system}->{'standalone'}, args => ['-b', '-e'],
		} ];
	}
	return [ {
		id => 'retroarch', label => 'RetroArch', kind => 'retroarch',
		core => $SYSTEM{$system}->{'core'},
	} ];
}

# Availability is a filesystem fact, so it is computed on every call: a core
# installed while the panel is open becomes usable without a restart.
sub _resolve_runner {
	my ($spec, $system) = @_;
	my %runner = (
		id => $spec->{'id'},
		label => $spec->{'label'},
		kind => $spec->{'kind'},
		args => [ @{ $spec->{'args'} || [] } ],
	);
	if ($runner{'kind'} eq 'retroarch') {
		$runner{'core_name'} = $spec->{'core'};
		my $path = core_path_for($spec->{'core'});
		if (defined $path) {
			$runner{'core'} = $path;
			$runner{'available'} = 1;
		}
		else {
			$runner{'available'} = 0;
			$runner{'reason'} = 'The ' . $spec->{'core'} . ' core is not installed.';
		}
	}
	else {
		my $path = _command_path($spec->{'command'});
		$runner{'command'} = defined $path ? $path : $spec->{'command'};
		if ($spec->{'blocked'}) {
			$runner{'available'} = 0;
			$runner{'reason'} = $spec->{'reason'} || 'This emulator cannot run on this machine.';
		}
		elsif (defined $path) {
			$runner{'available'} = 1;
		}
		else {
			$runner{'available'} = 0;
			$runner{'reason'} = 'The emulator is not installed.';
		}
	}
	return \%runner;
}

sub runners_for {
	my ($system) = @_;
	return [ map { _resolve_runner($_, $system) } @{ _runner_specs($system) } ];
}

sub default_runner {
	my ($system) = @_;
	foreach my $spec (@{ _runner_specs($system) }) {
		my $runner = _resolve_runner($spec, $system);
		return $runner if $runner->{'available'};
	}
	return undef;
}

sub runner_by_id {
	my ($system, $id) = @_;
	my $specs = _runner_specs($system);
	return undef unless @{ $specs };
	if (defined $id && length $id) {
		my ($picked) = grep { $_->{'id'} eq $id } @{ $specs };
		return _resolve_runner($picked, $system) if $picked;
	}
	my $default = default_runner($system);
	return $default if $default;
	return _resolve_runner($specs->[0], $system);
}

# The launcher's install button exists because this machine has no RetroArch
# yet. The returned shape is the one the routes and helpers already read; a
# runner id narrows it to the emulator the person chose.
sub runner_for {
	my ($system, $id) = @_;
	my $resolved = runner_by_id($system, $id);
	return undef unless ref $resolved eq 'HASH';
	my $entry = $SYSTEM{defined $system ? $system : ''} || {};
	my %runner = (
		kind => $resolved->{'kind'},
		package => $entry->{'package'} || '',
		id => $resolved->{'id'},
		label => $resolved->{'label'},
		args => $resolved->{'args'},
	);
	if ($resolved->{'kind'} eq 'retroarch') {
		return undef unless defined $resolved->{'core'} && length $resolved->{'core'};
		$runner{'core'} = $resolved->{'core'};
		$runner{'core_name'} = $resolved->{'core_name'};
	}
	else {
		$runner{'command'} = $resolved->{'command'};
		$runner{'missing'} = 1 unless $resolved->{'available'};
	}
	return \%runner;
}

# The frontend is not a system: it is the programme every RetroArch core runs
# inside, so the installer asks for it first and only once.
our $FRONTEND_PACKAGE = 'retroarch';

# The frontend the games run on. /opt/retroarch-gl is the build with desktop
# OpenGL: the packaged binary offers a GLES hardware context only, and every
# core that renders in 3D (mupen64plus-next, flycast, yabause, dolphin) asks
# for a desktop context and refuses to load without one. It is first so the
# build, once installed, is what games use; the packaged binary stays as the
# fallback for a machine that has not been through the build.
our @RETROARCH_BINARY = (
	'/opt/retroarch-gl/bin/retroarch',
	'/usr/bin/retroarch',
	'/usr/local/bin/retroarch',
);

# Whichever of those is installed, the first one wins; undef when none is.
sub retroarch_binary {
	foreach my $path (@RETROARCH_BINARY) {
		return $path if -x $path;
	}
	return undef;
}

sub packages {
	my %seen = ($FRONTEND_PACKAGE => 1);
	my @out = ($FRONTEND_PACKAGE);
	foreach my $system (sort keys %SYSTEM) {
		my $package = $SYSTEM{$system}->{'package'} || '';
		next unless length $package && !$seen{$package}++;
		push @out, $package;
	}
	return @out;
}

sub clean_title {
	my ($name) = @_;
	$name = '' unless defined $name;
	$name =~ s/\.[^.]+$//;
	$name =~ s/\[[^\]]*\]//g;
	$name =~ s/\([^)]*\)//g;
	$name =~ s/_/ /g;
	$name =~ s/\s+/ /g;
	$name =~ s/^\s+|\s+$//g;
	return length $name ? $name : 'Untitled';
}

sub id_for {
	my ($system, $relative) = @_;
	return sha1_hex((defined $system ? $system : '') . '/' . (defined $relative ? $relative : ''));
}

sub _collect {
	my ($dir, $prefix, $out, $depth) = @_;
	return if $depth < 0;
	opendir(my $dh, $dir) or return;
	foreach my $name (sort readdir $dh) {
		next if $name =~ /^\./;
		my $path = "$dir/$name";
		my $relative = length $prefix ? "$prefix/$name" : $name;
		next if -l $path;
		if (-d $path) {
			next if $name =~ /^(?:media|images|boxart|gamelists|downloaded_images|_info|manuals|videos)$/i;
			_collect($path, $relative, $out, $depth - 1);
			next;
		}
		push @{$out}, $relative if -f $path;
	}
	closedir $dh;
}

sub art_for {
	my ($root, $system, $relative) = @_;
	my ($base) = $relative =~ m{([^/]+)$};
	$base = '' unless defined $base;
	$base =~ s/\.[^.]+$//;
	(my $clean = $base) =~ s/\[[^\]]*\]//g;
	$clean =~ s/\([^)]*\)//g;
	$clean =~ s/_/ /g;
	$clean =~ s/\s+/ /g;
	$clean =~ s/^\s+|\s+$//g;
	my @names = ($base);
	push @names, $clean if length $clean && $clean ne $base;
	foreach my $dir ("$root/$system/media", "$root/$system/images", "$root/$system/boxart", "$root/$system") {
		foreach my $name (@names) {
			foreach my $suffix ('-image', '-thumb', '') {
				foreach my $ext (qw(png jpg jpeg webp)) {
					my $path = "$dir/$name$suffix.$ext";
					return $path if -f $path;
				}
			}
		}
	}
	return undef;
}

# Looking up a card's picture must never walk the whole library. Every card on
# the shelf asks for one image, and a full scan behind each request pinned the
# manager's single request loop while a page of cards loaded, which is what a
# person saw as "the games will not start". A scan writes the id -> picture map
# beside the ROMs (a dot file the scan itself ignores), and the art route reads
# it: one small file instead of a tree walk. The person owns that folder, so the
# manager can keep the file current without asking root.
our $ART_INDEX_NAME = '.jawnos-art.json';

sub art_index_file {
	my ($root) = @_;
	$root = '' unless defined $root;
	my $forced = $ENV{'JAWNOS_GAMES_ART_INDEX'};
	return $forced if defined $forced && length $forced;
	return undef unless length $root;
	return "$root/$ART_INDEX_NAME";
}

sub art_index_read {
	my ($root) = @_;
	my $file = art_index_file($root);
	return {} unless defined $file && -f $file;
	open(my $fh, '<', $file) or return {};
	local $/;
	my $raw = <$fh> // '';
	close $fh;
	my $parsed = eval { JSON::PP->new->decode($raw) };
	return ref $parsed eq 'HASH' ? $parsed : {};
}

sub _art_index_write {
	my ($root, $art) = @_;
	my $file = art_index_file($root);
	return 0 unless defined $file;
	my $json = eval { JSON::PP->new->canonical(1)->encode($art) };
	return 0 unless defined $json;
	my $tmp = "$file.tmp.$$";
	open(my $fh, '>', $tmp) or return 0;
	print $fh $json;
	unless (close $fh) { unlink $tmp; return 0; }
	unless (rename $tmp, $file) { unlink $tmp; return 0; }
	return 1;
}

# Remember the id -> picture map. The file is written only when a path changed,
# so a shelf nobody touched costs no write on every visit. A read-only library
# keeps working: the write fails, and art_path falls back to the scan.
sub art_index_store {
	my ($root, $art) = @_;
	$art = {} unless ref $art eq 'HASH';
	my $current = art_index_read($root);
	my $same = scalar(keys %{$current}) == scalar(keys %{$art});
	if ($same) {
		foreach my $id (keys %{$art}) {
			if (!defined $current->{$id} || $current->{$id} ne $art->{$id}) { $same = 0; last; }
		}
	}
	return 0 if $same;
	return _art_index_write($root, $art);
}

# The picture beside one card, from the index. A cover fetched since the last
# scan (or an index lost to a reboot) is looked up once and remembered; the
# shelf's next scan rewrites the whole map.
sub art_path {
	my ($root, $id) = @_;
	return undef unless defined $id && $id =~ /^[0-9a-f]{40}$/;
	$root = '' unless defined $root;
	my $entry = art_index_read($root);
	my $path = $entry->{$id};
	return $path if defined $path && length $path && -f $path;
	my $game = find($root, $id);
	return undef unless ref $game eq 'HASH' && defined $game->{'art'} && length $game->{'art'};
	$entry->{$id} = $game->{'art'};
	_art_index_write($root, $entry);
	return $game->{'art'};
}

sub scan {
	my ($root, $opts) = @_;
	$opts = {} unless ref $opts eq 'HASH';
	$root = '' unless defined $root;
	my $answer = { ok => 0, root => $root, systems => [], games => [] };
	return $answer unless length $root && -d $root;
	opendir(my $dh, $root) or return $answer;
	my @dirs = sort grep { !/^\./ && -d "$root/$_" } readdir $dh;
	closedir $dh;
	my %extension = map { $_ => 1 } @EXTENSION;
	my (@games, %count);
	foreach my $system (@dirs) {
		my @files;
		_collect("$root/$system", '', \@files, 2);
		foreach my $relative (@files) {
			my ($base) = $relative =~ m{([^/]+)$};
			my ($suffix) = $base =~ /\.([^.]+)$/;
			next unless defined $suffix && $extension{lc $suffix};
			# A .cue names the tracks beside it: the image of a disc is part
			# of that disc, not a second game on the shelf.
			if (lc($suffix) =~ /^(?:bin|img|raw)$/) {
				(my $stem = $relative) =~ s/\.[^.]+$//;
				next if -e "$root/$system/$stem.cue";
			}
			$count{$system}++;
			push @games, {
				id => id_for($system, $relative),
				system => $system,
				system_label => system_label($system),
				title => clean_title($base),
				file => "$root/$system/$relative",
				art => art_for($root, $system, $relative),
			};
		}
	}
	@games = sort {
		$a->{'system_label'} cmp $b->{'system_label'}
			|| lc($a->{'title'}) cmp lc($b->{'title'})
	} @games;
	$answer->{'ok'} = 1;
	$answer->{'games'} = \@games;
	if ($opts->{'art_index'}) {
		my %art;
		foreach my $game (@games) {
			next unless defined $game->{'art'} && length $game->{'art'};
			$art{ $game->{'id'} } = $game->{'art'};
		}
		art_index_store($root, \%art);
	}
	my $requested = ref $opts->{'chosen'} eq 'HASH' ? $opts->{'chosen'} : {};
	$answer->{'systems'} = [
		map {
			my $system = $_;
			my $runners = runners_for($system);
			my $chosen;
			if (@{ $runners }) {
				if (defined $requested->{$system} && length $requested->{$system}) {
					my ($picked) = grep { $_->{'id'} eq $requested->{$system} && $_->{'available'} } @{ $runners };
					$chosen = $picked->{'id'} if $picked;
				}
				unless (defined $chosen) {
					my $default = default_runner($system);
					$chosen = $default->{'id'} if $default;
				}
			}
			my $row = {
				id => $system,
				label => system_label($system),
				count => $count{$system},
				core => ($SYSTEM{$system}->{'core'} || ''),
				label_for => system_label($system),
				chosen => $chosen,
			};
			# One runner draws no picker: the page shows the list only when
			# there is a choice to make. The page-facing copy carries no
			# command, core or path. A single-runner system still reports
			# `chosen` so the launch route and the page agree on the id.
			if (scalar @{ $runners } > 1) {
				$row->{'runners'} = [
					map {
						my %page = (
							id => $_->{'id'},
							label => $_->{'label'},
							available => $_->{'available'} ? 1 : 0,
						);
						$page{'reason'} = $_->{'reason'} if defined $_->{'reason'} && length $_->{'reason'};
						\%page;
					} @{ $runners }
				];
			}
			$row;
		} sort keys %count
	];
	return $answer;
}

sub find {
	my ($root, $id) = @_;
	return undef unless defined $id && $id =~ /^[0-9a-f]{40}$/;
	my $library = scan($root);
	foreach my $game (@{ $library->{'games'} }) {
		return $game if $game->{'id'} eq $id;
	}
	return undef;
}

# ---- the browser player -----------------------------------------------------
#
# The handheld runs a DOS game in the real DOSBox (the `dos` system above). A
# desk or a phone has no DOSBox installed, so the same card runs in js-dos:
# DOSBox compiled to WebAssembly, kept in public/js/dos. It is handed the
# game's own folder as a js-dos bundle - a zip with .jsdos/dosbox.conf and the
# files - so the browser sees the same programme the handheld mounts.

# A .exe, .com or .bat can be started by name; a .conf carries its own autoexec
# and is the way a game with arguments or a CD image is filed. Everything else
# the scan accepts (a .zip, a disc image on its own) names no programme to run,
# so it has no browser entry.
our @BROWSER_EXTENSION = qw(conf exe com bat);

sub browser_runnable {
	my ($game) = @_;
	return 0 unless ref $game eq 'HASH';
	return 0 unless defined $game->{'system'} && $game->{'system'} eq 'dos';
	my ($base) = ($game->{'file'} // '') =~ m{([^/]+)$};
	my ($suffix) = (defined $base ? $base : '') =~ /\.([^.]+)$/;
	return 0 unless defined $suffix;
	my %accept = map { $_ => 1 } @BROWSER_EXTENSION;
	return $accept{lc $suffix} ? 1 : 0;
}

# The bundle is built once and read many times: a page of cards may be opened
# again and again, and re-zipping a game folder per press is wasted work. The
# cache file's name carries a hash of every member's name, size and mtime, so a
# changed file is a new bundle and the old one is removed.
our $BUNDLE_VERSION = 1;
our $BUNDLE_MAX_BYTES = 128 * 1024 * 1024;

sub bundle_cache_dir {
	my ($dir) = @_;
	return $dir if defined $dir && length $dir;
	my $forced = $ENV{'JAWNOS_DOS_BUNDLE_DIR'};
	return $forced if defined $forced && length $forced;
	my $home = $ENV{'HOME'};
	$home = '/home/jawn' unless defined $home && length $home;
	return "$home/.cache/jawnos/dos-bundles";
}

my %BUNDLE_SKIP_DIR = map { $_ => 1 } qw(
	media images boxart gamelists downloaded_images _info manuals videos
);

# Everything in the game's own folder, relative to it, because DOSBox mounts
# that folder as C:. A symlink is not followed: a bundle must not reach out of
# the ROM tree, and a DOS game has no use for one.
sub _bundle_collect {
	my ($dir, $prefix, $out, $bytes) = @_;
	opendir(my $dh, $dir) or return;
	foreach my $name (sort readdir $dh) {
		next if $name eq '.' || $name eq '..';
		# The scan ignores dot entries, and .jsdos is ours to generate.
		next if $name =~ /^\./;
		my $path = "$dir/$name";
		my $relative = length $prefix ? "$prefix/$name" : $name;
		next if -l $path;
		if (-d $path) {
			next if $BUNDLE_SKIP_DIR{$name};
			_bundle_collect($path, $relative, $out, $bytes);
			next;
		}
		next unless -f $path;
		my @stat = stat($path);
		next unless @stat;
		$$bytes += $stat[7];
		push @{$out}, { name => $relative, path => $path, size => $stat[7], mtime => $stat[9] };
	}
	closedir $dh;
	return $out;
}

sub _bundle_signature {
	my ($members) = @_;
	return join ';', map { $_->{'name'} . ':' . $_->{'size'} . ':' . $_->{'mtime'} } @{$members};
}

# The DOSBox configuration the browser bundle starts from. A .conf is itself a
# DOSBox configuration, and it is what the handheld's -conf launch uses, so it
# is passed through untouched; a loose programme gets a small config whose
# autoexec mounts the folder and runs the file.
sub bundle_config {
	my ($game) = @_;
	my $file = $game->{'file'} // '';
	my ($base) = $file =~ m{([^/]+)$};
	$base = '' unless defined $base;
	my ($suffix) = $base =~ /\.([^.]+)$/;
	$suffix = lc($suffix // '');
	if ($suffix eq 'conf') {
		return undef unless -f $file;
		open(my $fh, '<', $file) or return undef;
		binmode $fh;
		local $/;
		my $text = <$fh>;
		close $fh;
		return (defined $text && length $text) ? $text : undef;
	}
	# A name with a space is quoted so DOSBox reads it as one argument, and a
	# batch file is CALLed so an exit at its end does not leave the autoexec.
	my $run = ($base =~ /\s/) ? '"' . $base . '"' : $base;
	$run = 'CALL ' . $run if $suffix eq 'bat';
	return "[sdl]\n"
		. "autolock=false\n"
		. "fullscreen=false\n"
		. "output=surface\n"
		. "\n[dosbox]\n"
		. "machine=svga_s3\n"
		. "memsize=16\n"
		. "\n[cpu]\n"
		. "core=auto\n"
		. "cputype=auto\n"
		. "cycles=auto\n"
		. "\n[mixer]\n"
		. "nosound=false\n"
		. "rate=44100\n"
		. "blocksize=1024\n"
		. "\n[render]\n"
		. "aspect=true\n"
		. "scaler=none\n"
		. "\n[autoexec]\n"
		. "\@echo off\n"
		. "mount c .\n"
		. "c:\n"
		. "$run\n";
}

# A zip with one member per file. IO::Compress::Zip is core Perl, so a device
# needs no extra module to make a bundle.
sub _bundle_write {
	my ($path, $config, $members) = @_;
	require IO::Compress::Zip;
	my $zip = IO::Compress::Zip->new($path, Name => '.jsdos/dosbox.conf', AutoClose => 1)
		or return 0;
	$zip->print($config) or return 0;
	foreach my $member (@{$members}) {
		$zip->newStream(Name => $member->{'name'}) or return 0;
		open(my $fh, '<', $member->{'path'}) or return 0;
		binmode $fh;
		my $buffer;
		while (read($fh, $buffer, 65536)) {
			$zip->print($buffer) or do { close $fh; return 0 };
		}
		close $fh;
	}
	$zip->close() or return 0;
	return 1;
}

# Build (or reuse) the js-dos bundle for one card. The answer names the file on
# disk, never a request value; the route serves that file and nothing else.
sub browser_bundle {
	my ($game, $cache_dir) = @_;
	return { ok => 0, error => 'That game cannot run in the browser.' }
		unless browser_runnable($game);
	my $file = $game->{'file'} // '';
	return { ok => 0, error => 'The game file is missing.' } unless -f $file;
	my ($dir) = $file =~ m{^(.*)/[^/]+$};
	$dir = $file unless defined $dir;
	return { ok => 0, error => 'The game folder is missing.' } unless -d $dir;
	my @members;
	my $bytes = 0;
	_bundle_collect($dir, '', \@members, \$bytes);
	return { ok => 0, error => 'The game folder is empty.' } unless @members;
	return { ok => 0, error => 'This game is too large for the browser player.' }
		if $bytes > $BUNDLE_MAX_BYTES;
	my $config = bundle_config($game);
	return { ok => 0, error => 'The game config could not be read.' } unless defined $config;
	my $key = sha1_hex(join "\n", $BUNDLE_VERSION, $game->{'id'} // '', $config, _bundle_signature(\@members));
	my $cache = bundle_cache_dir($cache_dir);
	make_path($cache) unless -d $cache;
	my $path = "$cache/" . ($game->{'id'} // 'unknown') . "-$key.jsdos";
	return { ok => 1, path => $path, size => (-s $path) } if -f $path && -s $path;
	my $tmp = "$path.tmp.$$";
	unless (_bundle_write($tmp, $config, \@members)) {
		unlink $tmp;
		return { ok => 0, error => 'The browser bundle could not be written.' };
	}
	unless (rename $tmp, $path) {
		unlink $tmp;
		return { ok => 0, error => 'The browser bundle could not be saved.' };
	}
	# One bundle per card: a replaced game leaves its old bundle behind only
	# until the next play, and a game deleted from the shelf stops being built.
	# A month-old bundle is dropped on the next build, so a removed game's
	# folder does not sit in the cache forever.
	my $prefix = $cache . '/' . ($game->{'id'} // 'unknown') . '-';
	foreach my $old (glob("$cache/*.jsdos")) {
		next if $old eq $path;
		my @stat = stat($old);
		next unless index($old, $prefix) == 0 || (@stat && time - $stat[9] > 30 * 24 * 60 * 60);
		unlink $old;
	}
	return { ok => 1, path => $path, size => (-s $path) };
}

1;
