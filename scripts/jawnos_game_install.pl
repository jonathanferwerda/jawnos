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

# One child's stdout, so a helper's JSON does not land in the status channel.
sub run_capture {
	my (@command) = @_;
	open(my $pipe, '-|', @command) or return (127, '');
	local $/;
	my $out = <$pipe>;
	$out = '' unless defined $out;
	close $pipe;
	my $code = $?;
	return ($code == -1 ? 127 : $code >> 8, $out);
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
	# The packaged RetroArch is linked against OpenSSL 4 while this image's
	# openssl package provides 3.6, so the frontend refuses to start until the
	# newer sonames are visible. The helper stages only those two libraries
	# under /opt and leaves the system's OpenSSL alone; whatever it reports,
	# the rest of the install carries on.
	$STATUS{'note'} = 'Checking the OpenSSL RetroArch needs.';
	write_status();
	my $compat = { ok => 0, error => 'The OpenSSL helper is missing.' };
	my $openssl_script = "$FindBin::Bin/jawnos_game_openssl.pl";
	if (-f $openssl_script) {
		my ($compat_rc, $compat_out) = run_capture($^X, $openssl_script);
		my $parsed = eval { $JSON->decode($compat_out) };
		$compat = $parsed if ref $parsed eq 'HASH';
		$compat->{'ok'} = 0 if $compat_rc != 0 && $compat->{'ok'};
	}
	$STATUS{'openssl'} = $compat;
	if (!$compat->{'ok'}) {
		push @{ $STATUS{'failed'} }, 'openssl-compat';
	}
	elsif (($compat->{'state'} // '') eq 'staged') {
		push @{ $STATUS{'done'} }, 'openssl' . ($compat->{'major'} // '');
	}
	write_status();
	# RetroArch's default output is a "default" device this image never
	# configured; pin it to the panel's card once.
	my $config_dir = '/home/jawn/.config/retroarch';
	make_path($config_dir);
	my $config = "$config_dir/gou.cfg";
	if (!-e $config) {
		if (open(my $cfg, '>', $config)) {
			print $cfg "audio_driver = \"alsa\"\n"
				. "audio_device = \"hw:0,0\"\n"
				. "audio_enable = \"true\"\n"
				. "video_fullscreen = \"true\"\n"
				. "input_player1_joypad_index = \"1\"\n";
			close $cfg;
		}
	}
	# The virtual pad has no upstream profile, and RetroArch's fallback reads
	# its buttons by position: Start landed on nothing. This profile names every
	# button by the position it has in the pad's own key bitmap.
	my $autoconfig = "$config_dir/autoconfig/udev";
	make_path($autoconfig);
	my $profile = "$autoconfig/JawnOS Gamepad.cfg";
	if (!-e $profile) {
		my @lines = (
			'input_driver = "udev"',
			'input_device = "JawnOS Gamepad"',
			'input_vendor_id = "4617"',
			'input_product_id = "2"',
			'input_b_btn = "0"',
			'input_a_btn = "1"',
			'input_x_btn = "2"',
			'input_y_btn = "3"',
			'input_select_btn = "4"',
			'input_start_btn = "5"',
			'input_up_btn = "6"',
			'input_down_btn = "7"',
			'input_left_btn = "8"',
			'input_right_btn = "9"',
		);
		if (open(my $fh, '>', $profile)) {
			print $fh "$_\n" for @lines;
			close $fh;
		}
	}
	system('chown', '-R', 'jawn:jawn', $config_dir);

	# DOS games run in DOSBox, which reads the person's own config. A game
	# folder the launcher hands it is mounted as C: by DOSBox itself; this
	# config only pins the panel: full screen, the built-in mixer, no prompt.
	my $dosbox_dir = '/home/jawn/.config/dosbox';
	make_path($dosbox_dir);
	my $dosbox_config = "$dosbox_dir/gou.conf";
	if (!-e $dosbox_config) {
		if (open(my $cfg, '>', $dosbox_config)) {
			print $cfg "[sdl]\n"
				. "fullscreen=true\n"
				. "output=surface\n"
				. "autolock=false\n"
				. "\n"
				. "[mixer]\n"
				. "nosound=false\n"
				. "rate=44100\n"
				. "blocksize=1024\n";
			close $cfg;
		}
	}
	system('chown', '-R', 'jawn:jawn', $dosbox_dir);
	# The launch helper hands a standalone emulator `-b -e <file>` (Dolphin's
	# shape). DOSBox ignores those switches and runs the file itself, except a
	# .conf, which has to be `-conf`. The wrapper makes that one translation.
	my $dosbox_wrapper = "$FindBin::Bin/jawnos_dosbox.pl";
	if (-f $dosbox_wrapper) {
		make_path('/usr/local/bin');
		if (system('cp', '-f', $dosbox_wrapper, '/usr/local/bin/jawnos-dosbox') == 0) {
			chmod 0755, '/usr/local/bin/jawnos-dosbox';
		}
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
	if (!$compat->{'ok'}) {
		$note .= ' RetroArch still needs an OpenSSL this image does not carry.';
	}
	elsif (($compat->{'state'} // '') eq 'staged') {
		$note .= ' The OpenSSL ' . $compat->{'major'} . ' RetroArch needs was staged.';
	}
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
