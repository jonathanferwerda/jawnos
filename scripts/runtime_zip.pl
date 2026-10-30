#!/usr/bin/perl
# Write a runtime archive (M3, docs/leaving-termux.md).
#
#   perl scripts/runtime_zip.pl <stage dir> <out.zip>
#
# A zip, not a tar: the Android app unpacks it with ZipInputStream, so there is
# no tar binary to depend on and no decompressor to ship. IO::Compress::Zip is
# core Perl, so this runs wherever the tree runs (a device included).
#
# Entries are written in sorted order. Unix modes and symlinks survive: the
# mode rides the zip's external attributes and a symlink stores its target as
# the entry's data with S_IFLNK set, which is what `unzip` and Android's
# ZipInputStream both expect. Each entry keeps the file's own mtime (a fixed
# 1980 timestamp is read as a DOS value by IO::Compress::Zip and lands in 2107).
use strict;
use warnings;
use IO::Compress::Zip qw($ZipError);
use File::Find ();

my ($stage, $out) = @ARGV;
die "usage: runtime_zip.pl <stage dir> <out.zip>\n" unless defined $stage && defined $out;
die "runtime_zip: no such directory: $stage\n" unless -d $stage;

my @entries;
File::Find::find({
	no_chdir => 1,
	wanted   => sub {
		my $path = $File::Find::name;
		return unless -f $path || -l $path;
		my $rel = $path;
		$rel =~ s{^\Q$stage\E/}{};
		push @entries, $rel;
	},
}, $stage);
@entries = sort @entries;
die "runtime_zip: nothing to pack in $stage\n" unless @entries;

# A DOS timestamp cannot express anything before 1980, and IO::Compress::Zip
# reads a small integer as a DOS value rather than an epoch, so an entry with a
# pre-1980 mtime gets this floor instead.
my $FLOOR = 315532800;

sub mode_of {
	my ($path) = @_;
	my @st = lstat $path;
	return 0 unless @st;
	return $st[2] & 07777;
}

my $zip;
my $count = 0;
foreach my $rel (@entries) {
	my $path = "$stage/$rel";
	my $mode = mode_of($path);
	my $time = (lstat $path)[9] || $FLOOR;
	$time = $FLOOR if $time < $FLOOR;
	my $is_link = -l $path;
	my $data;
	if ($is_link) {
		$data = readlink $path;
		$data = '' unless defined $data;
		$mode |= 0120000;   # S_IFLNK
	}
	else {
		open(my $fh, '<', $path) or die "runtime_zip: $rel: $!\n";
		binmode $fh;
		local $/;
		$data = <$fh>;
		$data = '' unless defined $data;
		close $fh;
		$mode |= 0100000;   # S_IFREG
	}
	my $attr = ($mode << 16) & 0xFFFFFFFF;

	if (!$zip) {
		$zip = IO::Compress::Zip->new($out,
			Name     => $rel,
			Time     => $time,
			ExtAttr  => $attr,
		) or die "runtime_zip: $out: $ZipError\n";
	}
	else {
		$zip->newStream(
			Name     => $rel,
			Time     => $time,
			ExtAttr  => $attr,
		) or die "runtime_zip: $rel: " . ($IO::Compress::Zip::ZipError || $ZipError) . "\n";
	}
	print {$zip} $data;
	$count++;
}
$zip->close or die "runtime_zip: close: " . ($ZipError // 'unknown error') . "\n";

print "runtime_zip: $count entries -> $out\n";
