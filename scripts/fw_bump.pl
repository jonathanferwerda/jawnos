#!/usr/bin/perl
# Bump one board's firmware version, or sync every board to the house's scheme.
#
# The house has its own counter (scripts/version_bump.pl, ./VERSION). A board's
# number is its own: jt/VERSION for the deck, jw/VERSION for the watch,
# jp/alarmclock/VERSION for the Pico. Its *patch* moves when that board's
# firmware changes, and nothing else moves it - which is what lets the panel say
# "the watch is two builds behind" without the deck's number drifting with the
# house. Its *major.minor* follows the house: when the house goes 0.1.x -> 0.2.x
# (or 1.0.0), every board goes to <that>.0, so the scheme stays recognisable.
#
#   perl scripts/fw_bump.pl deck           # 0.1.2274 -> 0.1.2275
#   perl scripts/fw_bump.pl watch
#   perl scripts/fw_bump.pl alarmclock
#   perl scripts/fw_bump.pl --list         # what each board is on now
#   perl scripts/fw_bump.pl --sync         # as agent_land.pl runs it (see below)
#   perl scripts/fw_bump.pl --root DIR     # another tree (a test)
#
# --sync is the lander's call, and it is safe to run at any time:
#   * a board whose firmware sources changed between --from and HEAD keeps its
#     patch number only if the branch already bumped it; otherwise the patch
#     moves, so a new image never ships under the old number;
#   * a board whose major.minor differs from --house (default: this checkout's
#     VERSION) is set to <house major>.<house minor>.0 - the scheme follows the
#     house even when the board's own sources did not change.
#
# After a bump, rebuild and stage: scripts/fw_version.py stamps the file into
# the build, and scripts/stage_firmware.pl writes it into the sidecar.
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

# The same set scripts/stage_firmware.pl treats as a board's firmware (its
# @targets `files` pattern): what a change to means a new image.
my $FIRMWARE_SOURCE = qr/\.(?:ino|h|hpp|c|cpp|csv|ini)$/;

my $root = abs_path("$RealBin/..");
my $list = 0;
my $sync = 0;
my $from;
my $house;
my @rest;
while (defined(my $arg = shift @ARGV)) {
	if ($arg eq '--list') { $list = 1; next }
	if ($arg eq '--sync') { $sync = 1; next }
	if ($arg eq '--root') {
		my $dir = shift @ARGV;
		$root = abs_path($dir) || $dir if defined $dir;
		next;
	}
	if ($arg eq '--from') {
		my $ref = shift @ARGV;
		$from = $ref if defined $ref && length $ref;
		next;
	}
	if ($arg eq '--house') {
		my $version = shift @ARGV;
		$house = $version if defined $version && length $version;
		next;
	}
	push @rest, $arg;
}

sub read_version {
	my ($file) = @_;
	my $version = -f $file ? (eval { read_file($file) } || '') : '';
	$version =~ s/\s+//g;
	return $version;
}

if ($list) {
	foreach my $board (sort keys %BOARD) {
		my $version = read_version("$root/$BOARD{$board}/VERSION");
		printf "%-11s %s\n", $board, length $version ? $version : '(no VERSION)';
	}
	exit 0;
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

# What the landing touched under a board's project, as repo-relative paths. A
# missing ref (a fixture, or a tree with no git) is not an error: nobody can say
# what changed, so only the scheme is reconciled.
sub changed_paths {
	my ($project) = @_;
	return () unless defined $from && length $from;
	open(my $fh, '-|', 'git', '-C', $root, 'diff', '--name-only', $from, 'HEAD', '--', $project)
		or return ();
	my @paths = <$fh>;
	close $fh;
	return () if $? != 0;
	chomp @paths;
	return @paths;
}

sub sync_boards {
	my $changed_any = 0;
	my $scheme = (defined $house && length $house) ? $house : read_version("$root/VERSION");
	my ($house_major, $house_minor) = $scheme =~ /^(\d+)\.(\d+)\.\d+$/;
	unless (defined $house_minor) {
		print STDERR "cannot read the house version (got '$scheme')\n";
		return -1;
	}
	foreach my $board (sort keys %BOARD) {
		my $project = $BOARD{$board};
		my $file = "$root/$project/VERSION";
		# A tree without this board's VERSION is not ours to invent one for.
		next unless -f $file;
		my $current = read_version($file);
		my ($major, $minor, $patch) = split /\./, $current;
		unless (defined $patch) {
			print STDERR "$project/VERSION is not a version ('$current'); left alone\n";
			next;
		}
		my @paths = changed_paths($project);
		my $bumped  = grep { $_ eq "$project/VERSION" } @paths;
		my $changed = grep { /$FIRMWARE_SOURCE/ && $_ ne "$project/VERSION" } @paths;
		if ("$major.$minor" ne "$house_major.$house_minor") {
			my $next = "$house_major.$house_minor.0";
			write_file($file, "$next\n");
			print "$board $current -> $next (follows house $house_major.$house_minor)\n";
			$changed_any++;
		}
		elsif ($changed && !$bumped) {
			my $next = "$major.$minor." . ($patch + 1);
			write_file($file, "$next\n");
			print "$board $current -> $next ($project firmware changed)\n";
			$changed_any++;
		}
	}
	return $changed_any;
}

if ($sync) {
	my $count = sync_boards();
	exit 1 if $count < 0;
	exit 0;
}

my $board = shift @rest;
unless (defined $board && length $board) {
	print STDERR "usage: perl scripts/fw_bump.pl <" . join('|', sort keys %BOARD)
		. "|--list|--sync>\n";
	exit 2;
}
my $project = $BOARD{$board};
unless ($project) {
	print STDERR "unknown board '$board' (one of: " . join(', ', sort keys %BOARD) . ")\n";
	exit 2;
}

my $file = "$root/$project/VERSION";
my $version = read_version($file) || '0.1.0';
$version = '0.1.0' unless $version =~ /^\d+\.\d+\.\d+$/;

my ($major, $minor, $patch) = split /\./, $version;
my $next = "$major.$minor." . ($patch + 1);
write_file($file, "$next\n");
print "$board $version -> $next ($project/VERSION)\n";
exit 0;
