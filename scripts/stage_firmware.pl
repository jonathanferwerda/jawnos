#!/usr/bin/perl
# Stage firmware builds at the paths the manager's OTA serves.
#
# The manager does not read a device's .pio/build directory: each OTA path is
# hardwired (see AGENTS.md). After any firmware build, run this so an OTA sends
# the newest code instead of whatever was last copied there.
#
#   perl scripts/stage_firmware.pl            # copy the current build
#   perl scripts/stage_firmware.pl --build    # run pio run -j 4 first
#
# Add an entry to @targets when another device gains a hardwired OTA path.
use strict;
use warnings;
use FindBin qw($RealBin);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Cwd qw(abs_path);

my $root  = abs_path("$RealBin/..");
my $build = grep { $_ eq '--build' } @ARGV;

my @targets = (
	{
		name    => 'alarmclock (Pico 2 W)',
		project => 'jp/alarmclock',
		source  => 'jp/alarmclock/.pio/build/pico2w/firmware.bin',
		dest    => 'jp/alarmclock/build/rp2040.rp2040.rpipico2w/alarmclock.ino.bin',
	},
);

if ($build) {
	my $pio = $ENV{'PIO'};
	unless ($pio) {
		my $home = $ENV{'HOME'} || '';
		$pio = "$home/.platformio/penv/bin/pio" if $home && -x "$home/.platformio/penv/bin/pio";
	}
	$pio ||= 'pio';
	foreach my $t (@targets) {
		my $dir = "$root/$t->{'project'}";
		chdir $dir or die "cannot chdir to $dir: $!\n";
		print "Building $t->{'name'}...\n";
		system($pio, 'run', '-j', '4') == 0 or die "build failed for $t->{'name'}\n";
	}
	chdir $root or die "cannot chdir back to $root: $!\n";
}

my $staged = 0;
foreach my $t (@targets) {
	my $src = "$root/$t->{'source'}";
	my $dst = "$root/$t->{'dest'}";
	unless (-s $src) {
		warn "$t->{'name'}: no build at $t->{'source'} (run pio run first, or --build)\n";
		next;
	}
	make_path(dirname($dst));
	copy($src, $dst) or die "$t->{'name'}: copy failed: $!\n";
	printf "%s: %s -> %s (%d bytes)\n", $t->{'name'}, $t->{'source'}, $t->{'dest'}, -s $dst;
	$staged++;
}

print "\n$staged firmware target(s) staged for OTA.\n";
exit($staged ? 0 : 1);
