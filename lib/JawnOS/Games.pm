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

our @CORE_DIR = ('/usr/lib/libretro', '/usr/lib/retroarch/cores', '/usr/share/libretro/cores');

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

sub core_path {
	my ($system) = @_;
	my $entry = core_for($system);
	return undef unless $entry;
	foreach my $dir (@CORE_DIR) {
		my $path = "$dir/$entry->{'core'}";
		return $path if -f $path;
	}
	return undef;
}

sub runner_for {
	my ($system) = @_;
	my $entry = $SYSTEM{defined $system ? $system : ''};
	return undef unless $entry;
	if ($entry->{'standalone'}) {
		my $bin = $entry->{'standalone'};
		foreach my $dir (split /:/, ($ENV{'PATH'} || '/usr/bin:/bin')) {
			next unless length $dir;
			return { kind => 'standalone', command => "$dir/$bin", package => $entry->{'package'} }
				if -x "$dir/$bin";
		}
		return { kind => 'standalone', command => $bin, package => $entry->{'package'}, missing => 1 };
	}
	my $core = core_path($system);
	return undef unless $core;
	return { kind => 'retroarch', core => $core, core_name => $entry->{'core'} };
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

sub scan {
	my ($root) = @_;
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
	$answer->{'systems'} = [
		map {
			{
				id => $_,
				label => system_label($_),
				count => $count{$_},
				core => ($SYSTEM{$_}->{'core'} || ''),
				label_for => system_label($_),
			}
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
