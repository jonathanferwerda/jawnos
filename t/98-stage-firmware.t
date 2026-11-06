# tests-for: scripts/stage_firmware.pl
# covers:    staging a firmware build at the path the manager's OTA actually serves

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use Digest::SHA qw(sha256_hex);
use JSON::PP ();
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

# --- the sidecar is what makes "stale" provable -----------------------------
{
	my $tree = tempdir(CLEANUP => 1);
	make_path("$tree/jp/alarmclock/.pio/build/pico2w");
	make_path("$tree/jt/.pio/build/deck");
	make_path("$tree/jw/.pio/build/watch");
	write_file("$tree/VERSION", "9.9.9\n");
	write_file("$tree/jp/alarmclock/.pio/build/pico2w/firmware.bin", "v999 firmware\n");
	write_file("$tree/jt/.pio/build/deck/firmware.bin", "deck v999\n");
	write_file("$tree/jw/.pio/build/watch/firmware.bin", "watch v999\n");

	my ($rc, $out) = stage('--root', $tree);
	is($rc, 0, 'the build stages');
	like($out, qr/v9\.9\.9/, 'and the run names the version it staged');

	my $ota = "$tree/jp/alarmclock/build/rp2040.rp2040.rpipico2w/alarmclock.ino.bin";
	ok(-f "$ota.json", 'a sidecar lands beside the image');
	my $meta = JSON::PP->new->decode(scalar read_file("$ota.json"));
	is($meta->{'version'}, '9.9.9', 'the sidecar names the checkout\'s version');
	is($meta->{'size'}, -s $ota, 'and the staged size');
	is($meta->{'sha256'}, sha256_hex(scalar read_file($ota, binmode => ':raw')), 'and the sha256 of the bytes');

	# --- --verify passes on exactly this ------------------------------------
	my ($vrc, $vout) = stage('--root', $tree, '--verify');
	is($vrc, 0, '--verify is happy with a fresh stage');
	like($vout, qr/OK\s+alarmclock.*v9\.9\.9/, 'and says which build it would serve');

	# --- a missing sidecar is stale -----------------------------------------
	unlink "$ota.json";
	my ($nrc, $nout) = stage('--root', $tree, '--verify');
	is($nrc, 1, 'an image with no sidecar is stale');
	like($nout, qr/no sidecar/, 'and says so');

	# --- a sidecar for another version is stale -----------------------------
	write_file("$ota.json", JSON::PP->new->encode($meta));
	write_file("$tree/VERSION", "9.9.10\n");
	my ($mrc, $mout) = stage('--root', $tree, '--verify');
	is($mrc, 1, 'an image staged for another version is stale');
	like($mout, qr/staged for v9\.9\.9, this checkout is v9\.9\.10/, 'and names both versions');
	write_file("$tree/VERSION", "9.9.9\n");

	# --- bytes that do not match the sidecar are stale ----------------------
	write_file($ota, "tampered\n");
	my ($trc, $tout) = stage('--root', $tree, '--verify');
	is($trc, 1, 'an image whose bytes moved is stale');
	like($tout, qr/do not match their sidecar/, 'and says the bytes moved');

	# --- a differing local build is a note, not a refusal -------------------
	# Most machines never build firmware; one that built at an earlier version
	# keeps .pio on disk, and its build must not make the machine report itself
	# stale. The sidecar is what proves the image.
	stage('--root', $tree);
	write_file("$tree/jp/alarmclock/.pio/build/pico2w/firmware.bin", "v999 firmware rebuilt\n");
	my ($brc, $bout) = stage('--root', $tree, '--verify');
	is($brc, 0, 'a differing local build is still current');
	like($bout, qr/NOTE\s+alarmclock.*build differs from the staged image/, 'and says the build differs');
}

# --- a re-stage refreshes the sidecar with it -------------------------------
{
	my $tree = tempdir(CLEANUP => 1);
	make_path("$tree/jp/alarmclock/.pio/build/pico2w");
	write_file("$tree/VERSION", "1.0.0\n");
	write_file("$tree/jp/alarmclock/.pio/build/pico2w/firmware.bin", "one\n");
	stage('--root', $tree);
	write_file("$tree/VERSION", "1.0.1\n");
	write_file("$tree/jp/alarmclock/.pio/build/pico2w/firmware.bin", "two\n");
	stage('--root', $tree);
	my $ota = "$tree/jp/alarmclock/build/rp2040.rp2040.rpipico2w/alarmclock.ino.bin";
	my $meta = JSON::PP->new->decode(scalar read_file("$ota.json"));
	is($meta->{'version'}, '1.0.1', 'the sidecar follows the version');
	is($meta->{'sha256'}, sha256_hex(scalar read_file($ota, binmode => ':raw')), 'and the bytes it names');
	is(read_file($ota), "two\n", 'as does the image itself');
}

done_testing();
