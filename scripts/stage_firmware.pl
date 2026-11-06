#!/usr/bin/perl
# Stage firmware builds at the paths the manager's OTA serves.
#
# The manager does not read a device's .pio/build directory: each OTA path is
# hardwired (see AGENTS.md). After any firmware build, run this so an OTA sends
# the newest code instead of whatever was last copied there.
#
#   perl scripts/stage_firmware.pl            # copy the current build
#   perl scripts/stage_firmware.pl --build    # run pio run -j 4 first
#   perl scripts/stage_firmware.pl --verify   # change nothing; exit 1 if the
#                                            # staged image is not this version
#   perl scripts/stage_firmware.pl --root DIR # stage into another tree (a test,
#                                             # or a copy of the checkout)
#
# Each copy is accompanied by <dest>.json: the VERSION it was built from, the
# sha256 of the bytes, the size and when it was staged. A machine that serves an
# OTA with no sidecar, a sidecar that does not match the file, or a sidecar
# naming another version is serving stale firmware - which is how the Table
# shipped v0.1.2224 through two later versions. The manager refuses that now
# (lib/JawnOS/Domain/Firmware.pm), and --verify lets a person see it before any
# device does.
#
# Add an entry to @targets when another device gains a hardwired OTA path.
use strict;
use warnings;
use FindBin qw($RealBin);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use File::Slurp qw(read_file);
use JSON::PP ();

my $root   = abs_path("$RealBin/..");
my $build  = grep { $_ eq '--build' } @ARGV;
my $verify = grep { $_ eq '--verify' } @ARGV;

# --root stages into another checkout. It exists so this can be tested (and so a
# release tree can be staged without cd-ing into it); the default is the repo the
# script lives in.
for my $i (0 .. $#ARGV) {
	next unless $ARGV[$i] eq '--root' && defined $ARGV[ $i + 1 ] && length $ARGV[ $i + 1 ];
	$root = abs_path($ARGV[ $i + 1 ]) || $ARGV[ $i + 1 ];
	last;
}

my @targets = (
	{
		name    => 'alarmclock (Pico 2 W)',
		project => 'jp/alarmclock',
		source  => 'jp/alarmclock/.pio/build/pico2w/firmware.bin',
		dest    => 'jp/alarmclock/build/rp2040.rp2040.rpipico2w/alarmclock.ino.bin',
	},
	{
		name    => 'deck (ESP32-S3)',
		project => 'jt',
		source  => 'jt/.pio/build/deck/firmware.bin',
		dest    => 'jt/build/deck/firmware.bin',
	},
	{
		name    => 'watch (ESP32-S3)',
		project => 'jw',
		source  => 'jw/.pio/build/watch/firmware.bin',
		dest    => 'jw/build/watch/firmware.bin',
	},
);

my $version = eval { read_file("$root/VERSION") } || '';
$version =~ s/\s+//g;
$version ||= 'unknown';

sub staged_meta {
	my $dst = shift;
	my $sidecar = eval { read_file("$dst.json") } || '';
	return undef unless length $sidecar;
	my $meta = eval { JSON::PP->new->decode($sidecar) };
	return (ref $meta eq 'HASH') ? $meta : undef;
}

sub written_meta {
	my $dst = shift;
	my $target = shift;
	return {
		version   => $version,
		sha256    => sha256_hex(scalar read_file($dst, binmode => ':raw')),
		size      => -s $dst,
		source    => $target->{'source'},
		staged_at => time,
	};
}

sub write_sidecar {
	my ($dst, $meta) = @_;
	my $json = JSON::PP->new->canonical->pretty->encode($meta);
	open my $fh, '>', "$dst.json" or die "cannot write $dst.json: $!\n";
	print {$fh} $json;
	close $fh;
}

# --- verify: say what this machine would serve, change nothing --------------
if ($verify) {
	my $bad = 0;
	foreach my $t (@targets) {
		my $dst = "$root/$t->{'dest'}";
		my $label = "$t->{'name'} ($t->{'dest'})";
		unless (-s $dst) {
			print "STALE  $label: no image staged\n";
			$bad++;
			next;
		}
		my $meta = staged_meta($dst);
		unless ($meta && $meta->{'sha256'} && $meta->{'version'}) {
			print "STALE  $label: no sidecar - cannot prove which build this is\n";
			$bad++;
			next;
		}
		my $sha = sha256_hex(scalar read_file($dst, binmode => ':raw'));
		if ($sha ne $meta->{'sha256'}) {
			print "STALE  $label: the bytes do not match their sidecar\n";
			$bad++;
			next;
		}
		if (($meta->{'version'} || '') ne $version) {
			print "STALE  $label: staged for v$meta->{'version'}, this checkout is v$version\n";
			$bad++;
			next;
		}
		my $src = "$root/$t->{'source'}";
		if (-s $src) {
			my $build_sha = sha256_hex(scalar read_file($src, binmode => ':raw'));
			if ($build_sha ne $sha) {
				print "STALE  $label: the staged image is not the current build - run this again without --verify\n";
				$bad++;
				next;
			}
		}
		print "OK     $label: v$meta->{'version'} sha256 " . substr($sha, 0, 12) . "\n";
	}
	print "\n", ($bad ? "$bad firmware target(s) stale" : 'every firmware target is current'), "\n";
	exit($bad ? 1 : 0);
}

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
	my $meta = written_meta($dst, $t);
	write_sidecar($dst, $meta);
	printf "%s: %s -> %s (%d bytes, v%s)\n", $t->{'name'}, $t->{'source'}, $t->{'dest'}, -s $dst, $meta->{'version'};
	$staged++;
}

print "\n$staged firmware target(s) staged for OTA.\n";
exit($staged ? 0 : 1);
