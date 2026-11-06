#!/usr/bin/perl
# Bump one board's firmware version.
#
# The house has its own counter (scripts/version_bump.pl, ./VERSION). A board's
# number is its own: jt/VERSION for the deck, jw/VERSION for the watch,
# jp/alarmclock/VERSION for the Pico. It moves when that board's firmware
# changes, and nothing else moves it - which is what lets the panel say "the
# watch is two builds behind" without the deck's number drifting with the house.
#
#   perl scripts/fw_bump.pl deck           # 0.1.2274 -> 0.1.2275
#   perl scripts/fw_bump.pl watch
#   perl scripts/fw_bump.pl alarmclock
#   perl scripts/fw_bump.pl --list         # what each board is on now
#   perl scripts/fw_bump.pl --root DIR     # another tree (a test)
#
# Run it in the same commit as the firmware change, then rebuild and stage:
# scripts/fw_version.py stamps the file into the build, and
# scripts/stage_firmware.pl writes it into the sidecar the manager reads.
use strict;
use warnings;
use FindBin qw($RealBin);
use Cwd qw(abs_path);
use Fcntl qw(:flock);
use File::Slurp qw(read_file write_file);

my %BOARD = (
	alarmclock => 'jp/alarmclock',
	deck       => 'jt',
	watch      => 'jw',
);

my $root = abs_path("$RealBin/..");
my $list = 0;
my @rest;
while (defined(my $arg = shift @ARGV)) {
	if ($arg eq '--list') { $list = 1; next }
	if ($arg eq '--root') {
		my $dir = shift @ARGV;
		$root = abs_path($dir) || $dir if defined $dir;
		next;
	}
	push @rest, $arg;
}

if ($list) {
	foreach my $board (sort keys %BOARD) {
		my $file = "$root/$BOARD{$board}/VERSION";
		my $version = -f $file ? (eval { read_file($file) } || '') : '';
		$version =~ s/\s+$//;
		printf "%-11s %s\n", $board, length $version ? $version : '(no VERSION)';
	}
	exit 0;
}

my $board = shift @rest;
unless (defined $board && length $board) {
	print STDERR "usage: perl scripts/fw_bump.pl <" . join('|', sort keys %BOARD) . ">\n";
	exit 2;
}
my $project = $BOARD{$board};
unless ($project) {
	print STDERR "unknown board '$board' (one of: " . join(', ', sort keys %BOARD) . ")\n";
	exit 2;
}

# Concurrent agents bump from their own worktrees, which share one .git, and an
# unlocked read-modify-write is a lost update - the same reason version_bump.pl
# takes this lock. A tree with no git (a test) has nobody to race with.
sub common_dir {
	for my $args ('--path-format=absolute --git-common-dir', '--git-common-dir') {
		my $out = qx{git rev-parse $args 2>/dev/null};
		next unless defined $out && $out =~ /\S/;
		$out =~ s/\s+$//;
		return $out if $out =~ m{^/};
		my $abs = abs_path($out);
		return $abs if defined $abs && length $abs;
	}
	return '';
}

my $lock;
my $common = common_dir();
if (length $common) {
	if (open(my $fh, '>>', "$common/jawnos-fw-version.lock")) {
		flock($fh, LOCK_EX) or undef $fh;
		$lock = $fh;
	}
}

my $file = "$root/$project/VERSION";
my $version = eval { read_file($file) } || '0.1.0';
$version =~ s/\s+$//;
$version = '0.1.0' unless $version =~ /^\d+\.\d+\.\d+$/;

my ($major, $minor, $patch) = split /\./, $version;
my $next = "$major.$minor." . ($patch + 1);
write_file($file, "$next\n");
print "$board $version -> $next ($project/VERSION)\n";
exit 0;
