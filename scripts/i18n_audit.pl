#!/usr/bin/perl
#
# i18n_audit.pl - how complete is each language?
#
#   perl scripts/i18n_audit.pl
#   perl scripts/i18n_audit.pl --missing     # list every untranslated string
#   perl scripts/i18n_audit.pl --strict      # exit 1 when a language is short
#
# Compares i18n/strings.json (the extractor's snapshot) with every
# i18n/ui-<code>.json. A stale snapshot is called out too, so a UI change that
# was not followed by i18n_extract.pl is visible before a push.

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use Cwd ();
use Getopt::Long qw(GetOptions);
use Mojo::JSON qw(decode_json);
use JSON::PP ();
use File::Slurp qw(read_file);
use File::Find;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

my $root = Cwd::abs_path("$Bin/..");
chdir $root or die "cannot chdir to $root: $!\n";
require "./language.pl";

my $missing_all = 0;
my $strict = 0;
GetOptions( 'missing' => \$missing_all, 'strict' => \$strict ) or die "bad options\n";

my $catalog_file = 'i18n/strings.json';
unless ( -e $catalog_file ) {
	print STDERR "i18n_audit: missing $catalog_file - run perl scripts/i18n_extract.pl\n";
	exit( $strict ? 1 : 0 );
}
my $raw = read_file($catalog_file);
my $data = eval { decode_json($raw) };
my @strings = ref $data eq 'HASH' ? map { $_->{'text'} } @{ $data->{'strings'} || [] } : ();
unless (@strings) {
	print STDERR "i18n_audit: $catalog_file has no strings\n";
	exit( $strict ? 1 : 0 );
}

# Is the snapshot older than the sources it was taken from?
my $snapshot_at = ( stat($catalog_file) )[9] || 0;
my $newest      = 0;
my $newest_file = '';
my @sources = ('help.pl');
find( { no_chdir => 1, wanted => sub { push @sources, $_ if /\.(?:ep|js)$/ } }, 'templates', 'public/js' );
foreach my $f ( @sources ) {
	next unless defined $f && -e $f;
	next if $f =~ m{/(?:jquery|moment|numeral|touch-threshold)};    # vendored
	my $m = ( stat($f) )[9] || 0;
	if ( $m > $newest ) { $newest = $m; $newest_file = $f }
}
if ( $newest > $snapshot_at ) {
	print "STALE snapshot: $newest_file changed after $catalog_file\n";
	print "  run perl scripts/i18n_extract.pl\n";
}

my $total = scalar @strings;
my $short = 0;
foreach my $lang ( grep { $_->{'code'} ne 'en' } @language::languages ) {
	my $code = $lang->{'code'};
	my $file = "i18n/ui-$code.json";
	my $done = {};
	if ( -e $file ) {
		my $r = read_file($file);
		my $d = eval { decode_json($r) };
		$done = $d if ref $d eq 'HASH';
	}
	my @missing = grep { !( defined $done->{$_} && length $done->{$_} ) } @strings;
	my %known = map { $_ => 1 } @strings;
	my @extra = grep { !$known{$_} } keys %{$done};
	my $have = $total - scalar(@missing);
	printf( "%-3s %-18s %5d/%-5d %6.1f%%  missing %d%s\n",
		$code, $lang->{'native'}, $have, $total,
		$total ? ( 100 * $have / $total ) : 0,
		scalar(@missing),
		@extra ? "  stale " . scalar(@extra) : '' );
	$short++ if @missing;
	if ( $missing_all && @missing ) {
		foreach my $s (@missing) {
			print "    - " . substr( $s, 0, 160 ) . "\n";
		}
	}
}

if ($short) {
	print "\n$short language(s) short. Run perl scripts/i18n_translate.pl after i18n_extract.pl.\n";
}
else {
	print "\nAll listed languages are complete.\n";
}
exit( $strict && $short ? 1 : 0 );
1;
