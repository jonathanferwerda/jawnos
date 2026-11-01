#!/usr/bin/env perl
# js_parts_check.pl - verify a big script was split without changing a byte.
#
# A split script keeps its old path as the index (the first part) and puts the
# rest in a folder of the same name, in numeric name order. The only text allowed
# to change is the [[js-split]] manifest block at the top of the index.
#
#   perl scripts/js_parts_check.pl /tmp/manager.orig.js public/js/manager/manager.js
#
# Prints OK and exits 0 when the reconstructed script is byte-identical, or the
# first differing line and exits 1. Also runs `node --check` on every piece when
# node is installed.
use strict;
use warnings;
use File::Basename qw(basename);
use File::Slurp qw(read_file);
use FindBin;

my ($original, $index) = @ARGV;
die "usage: $0 <original.js> <index.js>\n" unless defined $original && defined $index;
die "$original: $!\n" unless -f $original;
die "$index: $!\n" unless -f $index;

my $want = read_file($original);
my $index_text = read_file($index);

# The manifest is a block comment at the very top; strip it (and the newline
# that follows) so the comparison sees only the original first segment.
(my $head = $index_text) =~ s{^/\* \[\[js-split\]\].*?\[\[/js-split\]\] \*/\n}{}s;
if ($head eq $index_text) {
	print "NO MANIFEST: $index has no [[js-split]] block at the top\n";
	exit 1;
}

(my $dir = $index) =~ s{\.js$}{};
my @parts = sort grep { -f } glob("$dir/*.js");
die "no parts under $dir/\n" unless @parts;

my $got = $head;
$got .= read_file($_) for @parts;

if ($got ne $want) {
	my @a = split /\n/, $want, -1;
	my @b = split /\n/, $got, -1;
	my $line = 0;
	$line++ while $line < @a && $line < @b && $a[$line] eq $b[$line];
	print "MISMATCH at reconstructed line ", $line + 1, "\n";
	print "  original:  ", ($a[$line] // '<end>'), "\n";
	print "  rebuilt:   ", ($b[$line] // '<end>'), "\n";
	exit 1;
}

my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
if ($node && -x $node) {
	for my $file ($index, @parts) {
		my $err = `$node --check "$file" 2>&1`;
		if ($? != 0) {
			print "SYNTAX: $file\n$err";
			exit 1;
		}
	}
}

printf "OK %s: %d lines in the index + %d part(s), %s bytes\n",
	basename($index), scalar(split /\n/, $head), scalar(@parts), length($got);
exit 0;
