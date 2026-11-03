#!/usr/bin/perl
# Rotate a log that is being appended to by a running process.
#
# The manager's log is opened by Mojo::Log with '>>' and the supervisor's
# jawn-stdout.log by systemd with StandardOutput=append:, so both descriptors
# write at the current end of the file. Truncating the file therefore does not
# fight the writer and needs no restart: the next line lands at offset 0.
#
# The last --keep lines stay in the live file; everything before them is
# streamed into a gzipped archive beside it. A file below --min-bytes, or one
# that does not have more than --keep lines, is left alone.
#
# Dry-run by default.
#
#   perl scripts/log_rotate.pl ~/manager.log
#   perl scripts/log_rotate.pl --apply --keep 5000 ~/manager.log
#   perl scripts/log_rotate.pl --apply --level 6 ~/manager.log ~/jawn-stdout.log
#
# The scan is one forward pass; the tail is copied through a temp file, so a
# multi-gigabyte log does not have to fit in memory.

use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use IO::Compress::Gzip qw(gzip $GzipError);
use POSIX qw(strftime);

my ($apply, $keep, $min_bytes, $level, $archive_dir) = (0, 5000, 5_000_000, 1, '');
my $ok = GetOptions(
	'apply'        => \$apply,
	'keep=i'       => \$keep,
	'min-bytes=i'  => \$min_bytes,
	'level=i'      => \$level,
	'archive-dir=s'=> \$archive_dir,
	'help|h'       => sub {
		print "usage: $0 [--apply] [--keep N] [--min-bytes N] [--level N] [--archive-dir DIR] FILE...\n";
		exit 0;
	},
);
die "usage: $0 [--apply] [--keep N] [--min-bytes N] [--level N] [--archive-dir DIR] FILE...\n" unless $ok;
$keep = 10 if !defined $keep || $keep < 1;
$level = 1 if !defined $level || $level < 1 || $level > 9;
die "no log files given\n" unless @ARGV;

umask 077;
my $stamp = strftime('%Y%m%d-%H%M%S', localtime);
my ($rotated, $skipped, $archived_bytes, $kept_bytes) = (0, 0, 0, 0);

for my $file (@ARGV) {
	unless (-f $file) {
		print "skip $file: not a file\n";
		$skipped++;
		next;
	}
	my $size = -s $file;
	if ($size < $min_bytes) {
		printf "skip %s: %d bytes (under %d)\n", $file, $size, $min_bytes;
		$skipped++;
		next;
	}
	my $tail_start = &tail_offset($file, $size, $keep);
	if (!defined $tail_start || $tail_start <= 0) {
		printf "skip %s: %d bytes is at most %d lines\n", $file, $size, $keep;
		$skipped++;
		next;
	}

	my $dir = $archive_dir;
	unless (length $dir) {
		$dir = $file =~ m{^(.*)/[^/]+$} ? $1 : '.';
	}
	my ($name) = $file =~ m{([^/]+)$};
	my $archive = "$dir/$name.$stamp.gz";
	my $n = 2;
	$archive = "$dir/$name.$stamp-$n.gz" while -e $archive && $n++ < 100;

	printf "%s: %d bytes -> archive %d bytes, keep last %d lines (%d bytes) in %s\n",
		$file, $size, $tail_start, $keep, $size - $tail_start, $archive;
	next unless $apply;

	# The archive is written first. If it fails, the live log is untouched.
	open(my $in, '<', $file) or die "cannot read $file: $!\n";
	binmode $in;
	my $gz = IO::Compress::Gzip->new($archive, -Level => $level)
		or die "cannot write $archive: $GzipError\n";
	my $left = $tail_start;
	while ($left > 0) {
		my $want = $left > 1_048_576 ? 1_048_576 : $left;
		my $buf = '';
		my $got = read($in, $buf, $want);
		die "short read on $file: $!\n" unless defined $got && $got > 0;
		$gz->write($buf) or die "cannot write $archive: $GzipError\n";
		$left -= $got;
	}
	$gz->close or die "cannot close $archive: $GzipError\n";
	close $in;
	die "archive $archive is empty\n" unless -s $archive;
	chmod 0600, $archive;

	# Copy the tail through a temp file (it may be large), then truncate and
	# write it back. Bytes the app appends after this point are kept by its own
	# O_APPEND descriptor; bytes appended between the copy and the truncate may
	# be lost, which is the one acceptable gap in a log.
	my $tmp = "$file.rotate.$$";
	open(my $tin, '<', $file) or die "cannot read $file: $!\n";
	binmode $tin;
	seek($tin, $tail_start, 0) or die "cannot seek $file: $!\n";
	open(my $tout, '>', $tmp) or die "cannot write $tmp: $!\n";
	binmode $tout;
	my $buf = '';
	while (read($tin, $buf, 1_048_576)) { print $tout $buf }
	close $tout;
	close $tin;

	truncate($file, 0) or die "cannot truncate $file: $!\n";
	open(my $out, '>>', $file) or die "cannot append $file: $!\n";
	binmode $out;
	open(my $rin, '<', $tmp) or die "cannot read $tmp: $!\n";
	binmode $rin;
	while (read($rin, $buf, 1_048_576)) { print $out $buf }
	close $rin;
	close $out;
	unlink $tmp;

	$rotated++;
	$archived_bytes += $tail_start;
	$kept_bytes += $size - $tail_start;
	printf "  wrote %s (%d bytes); live %s now %d bytes\n", $archive, -s $archive, $file, -s $file;
}

printf "\n%d rotated, %d skipped; archived %d bytes, kept %d bytes%s\n",
	$rotated, $skipped, $archived_bytes, $kept_bytes, ($apply ? '' : ' (dry run)');
exit 0;

# The byte offset at which the last $keep lines begin, or undef when the file
# has no more than $keep lines. A ring of line starts keeps memory flat.
sub tail_offset {
	my ($file, $size, $keep) = @_;
	open(my $fh, '<', $file) or return undef;
	binmode $fh;
	my @ring;
	my $ring_i = 0;
	my $line_start = 0;
	my $lines = 0;
	my $read = 0;
	while ($read < $size) {
		my $want = $size - $read > 1_048_576 ? 1_048_576 : $size - $read;
		my $buf = '';
		my $got = read($fh, $buf, $want);
		last unless defined $got && $got > 0;
		my $chunk_start = $read;
		$read += $got;
		my $at = -1;
		while (($at = index($buf, "\n", $at + 1)) >= 0) {
			$ring[$ring_i % $keep] = $line_start;
			$ring_i++;
			$lines++;
			$line_start = $chunk_start + $at + 1;
		}
	}
	close $fh;
	# a final partial line counts as a line
	if ($line_start < $size) {
		$ring[$ring_i % $keep] = $line_start;
		$ring_i++;
		$lines++;
	}
	return undef if $lines <= $keep;
	return $ring[$ring_i % $keep];
}
