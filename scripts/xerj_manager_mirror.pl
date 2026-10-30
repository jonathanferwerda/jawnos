#!/usr/bin/env perl
# xerj silently drops any single code file over 2 MiB (xerj-org/xerj#2745), so
# Manager.pl - the biggest file in this tree - is missing from the index while
# nothing in the output says so. This writes xerj-mirror/: Manager.pl cut into
# chunks small enough to be indexed.
#
# Each chunk is padded with blank lines so ITS line numbers equal Manager.pl's.
# A hit at xerj-mirror/manager-03.pl:20473 is Manager.pl:20473.
#
# Re-run after changing Manager.pl: the chunks are a copy, and a stale copy
# cites the wrong lines. xerj-mirror/ is gitignored, so it is local only.
use strict;
use warnings;

use FindBin;
use File::Path qw(make_path remove_tree);
use File::Spec;

my $src  = File::Spec->catfile( $FindBin::Bin, '..', 'Manager.pl' );
my $out  = File::Spec->catfile( $FindBin::Bin, '..', 'xerj-mirror' );
my $CHUNK = 2000;

open my $fh, '<', $src or die "cannot read $src: $!";
my @lines = <$fh>;
close $fh;

remove_tree($out) if -d $out;
make_path($out);

my $written = 0;
for ( my $start = 1; $start <= scalar @lines; $start += $CHUNK ) {
	my $end = $start + $CHUNK - 1;
	$end = scalar @lines if $end > scalar @lines;
	my $name = sprintf( 'manager-%02d.pl', ( ( $start - 1 ) / $CHUNK ) + 1 );
	my $path = File::Spec->catfile( $out, $name );
	open my $chunk, '>', $path or die "cannot write $path: $!";
	# the padding is what makes a cited line number mean Manager.pl's line number
	print $chunk "\n" x ( $start - 1 );
	print $chunk @lines[ $start - 1 .. $end - 1 ];
	close $chunk;
	$written++;
	print "$name  Manager.pl lines $start-$end\n";
}

printf "wrote %d chunk(s) of %d lines into %s\n", $written, $CHUNK, $out;
print "next: perl scripts/xerj_manager_mirror.pl && xerj autoindex . --prefix jawnos --no-semantic --max-file-mb 6\n";
