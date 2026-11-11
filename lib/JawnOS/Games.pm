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

1;
