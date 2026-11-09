#!/usr/bin/perl
# Install what the emulated shelf needs, or bring ROMs in from a mounted source.
#
#   perl scripts/jawnos_game_install.pl emulators
#   perl scripts/jawnos_game_install.pl roms
#
# It runs as root (the manager calls it through `sudo -n`) and writes one JSON
# status row to /run/jawnos-games/install.json, which the launcher polls. The
# package list is fixed in JawnOS::Games - no request value reaches pacman - and
# the ROM import copies from the emmc or a USB stick into the person's ~/roms,
# never over a file that is already there.
#
# A package the repositories do not carry is reported in `failed` and does not
# stop the rest: a handheld can still play what it has.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Path qw(make_path);
use JSON::PP ();
use JawnOS::Games ();

my $WHAT = shift @ARGV // '';
my $STATE = '/run/jawnos-games';
my $FILE = "$STATE/install.json";
my $ROMS = '/home/jawn/roms';
my $JSON = JSON::PP->new->canonical(1);

my %STATUS = (
	state => 'running',
	what => $WHAT,
	at => time,
	done => [],
	failed => [],
	note => '',
);

sub write_status {
	make_path($STATE);
	open my $fh, '>', "$FILE.tmp" or return;
	print $fh $JSON->encode(\%STATUS);
	close $fh;
	rename "$FILE.tmp", $FILE;
	chmod 0644, $FILE;
}

sub finish {
	my ($state, $note) = @_;
	$STATUS{'state'} = $state;
	$STATUS{'note'} = $note if defined $note;
	$STATUS{'finished'} = time;
	write_status();
	exit($state eq 'done' ? 0 : 1);
}

write_status();

if ($WHAT eq 'emulators') {
	finish('failed', 'There is no package manager on this machine.') unless -x '/usr/bin/pacman';
	# A helper killed mid-run leaves pacman's lock behind; only a running
	# pacman may keep it.
	if (-e '/var/lib/pacman/db.lck') {
		my $running = system('pgrep', '-x', 'pacman');
		unlink '/var/lib/pacman/db.lck' if $running != 0;
	}
	$STATUS{'note'} = 'Refreshing the package list.';
	write_status();
	system('pacman', '-Sy', '--noconfirm');
	foreach my $package (JawnOS::Games::packages()) {
		$STATUS{'package'} = $package;
		$STATUS{'note'} = 'Installing ' . $package . '.';
		write_status();
		my $rc = system('pacman', '-S', '--needed', '--noconfirm', $package);
		$STATUS{'package'} = '';
		if ($rc == 0) {
			push @{ $STATUS{'done'} }, $package;
		}
		else {
			push @{ $STATUS{'failed'} }, $package;
		}
		write_status();
	}
	# The repositories do not carry every core the shelf names. The emmc image
	# has a full set built for this board; copy the ones still missing, never
	# over one pacman installed.
	if (!-d '/media/emmc/opt/libretro' && -b '/dev/mmcblk1p2') {
		make_path('/media/emmc');
		system('mount', '-o', 'ro', '/dev/mmcblk1p2', '/media/emmc');
	}
	my @copied;
	if (-d '/media/emmc/opt/libretro') {
		make_path('/usr/lib/libretro');
		foreach my $core (glob('/media/emmc/opt/libretro/*/*_libretro.so')) {
			my ($name) = $core =~ m{([^/]+)$};
			my $dest = '/usr/lib/libretro/' . $name;
			next if -e $dest;
			push @copied, $name if system('cp', '-n', $core, $dest) == 0;
		}
	}
	$STATUS{'copied'} = \@copied;
	my $note = 'All emulators are installed.';
	$note = 'Installed ' . scalar(@{ $STATUS{'done'} }) . '; the repositories did not have: '
		. join(', ', @{ $STATUS{'failed'} }) . '.'
		if @{ $STATUS{'failed'} };
	$note .= ' ' . scalar(@copied) . ' cores copied from the emmc.' if @copied;
	finish('done', $note);
}

if ($WHAT eq 'roms') {
	my @sources;
	# The emmc's retro image is the usual first home, and it may not be mounted.
	if (!-d '/media/emmc/roms' && -b '/dev/mmcblk1p2') {
		make_path('/media/emmc');
		system('mount', '-o', 'ro', '/dev/mmcblk1p2', '/media/emmc');
	}
	push @sources, '/media/emmc/roms' if -d '/media/emmc/roms';
	foreach my $dir (glob('/media/*/roms'), glob('/media/*/*/roms'), glob('/run/media/*/roms'),
		glob('/run/media/*/*/roms'), glob('/mnt/*/roms')) {
		next unless -d $dir;
		next if grep { $_ eq $dir } @sources;
		push @sources, $dir;
	}
	make_path($ROMS);
	my $before = scalar(@{ JawnOS::Games::scan($ROMS)->{'games'} });
	if (!@sources) {
		finish('done', 'No ROM folder found. Put ROMs on a USB stick in a roms/ folder, '
			. 'or on the emmc at /media/emmc/roms.');
	}
	$STATUS{'sources'} = [ @sources ];
	write_status();
	foreach my $source (@sources) {
		$STATUS{'note'} = 'Copying from ' . $source . '.';
		write_status();
		system('cp', '-a', '-n', "$source/.", "$ROMS/");
	}
	system('chown', '-R', 'jawn:jawn', $ROMS);
	my $after = scalar(@{ JawnOS::Games::scan($ROMS)->{'games'} });
	my $added = $after - $before;
	$added = 0 if $added < 0;
	finish('done', $added . ' game' . ($added == 1 ? '' : 's') . ' added from '
		. scalar(@sources) . ' source' . (scalar(@sources) == 1 ? '' : 's') . '.');
}

finish('failed', 'The request was not emulators or roms.');

1;
