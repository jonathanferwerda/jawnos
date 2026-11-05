#!/usr/bin/perl

# Bump the JawnOS patch version in ./VERSION (e.g. 0.1.1 -> 0.1.2).
# Run this before each commit until 0.2, when the minor bump becomes manual.

use strict;
use warnings;
use Cwd qw(abs_path);
use Fcntl qw(:flock);
use File::Slurp qw(read_file write_file);

# Concurrent agents bump this same counter from their own worktrees, which share
# one .git, and an unlocked read-modify-write is a lost update: two of them read
# 0.1.9 and both write 0.1.10, so two commits claim one version and a number is
# skipped. The lock lives in the git common dir precisely so it spans every
# worktree of this repo; outside a repo there is nobody to race with.
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
	if (open(my $fh, '>>', "$common/jawnos-version.lock")) {
		flock($fh, LOCK_EX) or undef $fh;
		$lock = $fh;
	}
}

my $file = './VERSION';
my $v = eval { read_file($file) } || '0.1.0';
$v =~ s/\s+$//;
$v = '0.1.0' unless $v =~ /^\d+\.\d+\.\d+$/;

my ($major, $minor, $patch) = split /\./, $v;
$v = "$major.$minor." . ($patch + 1);
write_file($file, "$v\n");

if ($lock) {
	flock($lock, LOCK_UN);
	close($lock);
}

print "$v\n";
