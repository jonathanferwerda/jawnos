# tests-for: scripts/stage_firmware.pl
# covers:    staging a firmware build at the path the manager's OTA actually serves

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Test::More;

# The manager serves firmware from a hardwired path, not from a device's
# .pio/build directory: an unstaged build means an OTA sends the previous
# firmware. That path is the whole contract, so it is what this pins - along with
# the two ways the run can end (staged, or nothing to stage).

my $root   = "$FindBin::Bin/..";
my $script = "$root/scripts/stage_firmware.pl";

sub stage {
	my @args = @_;
	my $err  = gensym;
	my $pid  = open3(my $in, my $out, $err, $^X, $script, @args);
	close $in;
	local $/;
	my $stdout = <$out> // '';
	my $stderr = <$err> // '';
	waitpid($pid, 0);
	return ($? >> 8, $stdout, $stderr);
}

# --- a build is staged at the OTA path --------------------------------------
{
	my $tree = tempdir(CLEANUP => 1);
	make_path("$tree/jp/alarmclock/.pio/build/pico2w");
	my $firmware = "firmware-bytes-for-the-ota\n";
	write_file("$tree/jp/alarmclock/.pio/build/pico2w/firmware.bin", $firmware);

	my ($rc, $out) = stage('--root', $tree);
	is($rc, 0, 'a build is staged');
	like($out, qr/1 firmware target\(s\) staged for OTA/, 'and counted');

	my $ota = "$tree/jp/alarmclock/build/rp2040.rp2040.rpipico2w/alarmclock.ino.bin";
	ok(-f $ota, 'the manager\'s hardwired OTA path now has the build')
		or diag('looked for ' . $ota);
	is(read_file($ota), $firmware, 'byte for byte, not a copy of something else');
}

# --- no build, no lie -------------------------------------------------------
{
	my $tree = tempdir(CLEANUP => 1);
	make_path("$tree/jp/alarmclock");
	my ($rc, $out, $err) = stage('--root', $tree);
	is($rc, 1, 'nothing to stage is exit 1');
	like($err, qr/no build at jp\/alarmclock\/\.pio\/build\/pico2w\/firmware\.bin/,
		'and names the build it wanted');
	like($err, qr/run pio run first, or --build/, 'with the fix in the message');
	ok(!-e "$tree/jp/alarmclock/build/rp2040.rp2040.rpipico2w/alarmclock.ino.bin",
		'and stages nothing');
}

# --- restaging replaces the previous firmware -------------------------------
{
	my $tree = tempdir(CLEANUP => 1);
	make_path("$tree/jp/alarmclock/.pio/build/pico2w");
	write_file("$tree/jp/alarmclock/.pio/build/pico2w/firmware.bin", "old\n");
	stage('--root', $tree);

	my $ota = "$tree/jp/alarmclock/build/rp2040.rp2040.rpipico2w/alarmclock.ino.bin";
	is(read_file($ota), "old\n", 'the first build is staged');

	write_file("$tree/jp/alarmclock/.pio/build/pico2w/firmware.bin", "new\n");
	my ($rc) = stage('--root', $tree);
	is($rc, 0, 'the second run stages');
	is(read_file($ota), "new\n", 'and replaces what OTA would send');
}

done_testing();
