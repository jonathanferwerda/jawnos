# tests-for: scripts/i18n_extract.pl
# covers:    the extractor - every source string, deduplicated, with the files it
#           came from, and counts that match the payload

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use JSON::PP ();
use File::Slurp qw(read_file);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Test::More;

# The extractor is what every translation starts from: a stale or lossy snapshot
# means a UI string is never offered for translation. The counts and the source
# attribution are its contract, so they are checked here against the real tree -
# it writes only to the file --out names.

my $root   = "$FindBin::Bin/..";
my $script = "$root/scripts/i18n_extract.pl";
my $dir    = tempdir(CLEANUP => 1);
my $out    = "$dir/strings.json";

my $err = gensym;
my $pid = open3(my $in, my $stdout, $err, $^X, $script, '--out', $out);
close $in;
my $log = do { local $/; <$stdout> // '' };
my $errout = do { local $/; <$err> // '' };
waitpid($pid, 0);
is($? >> 8, 0, 'the extractor runs against the real tree') or diag($errout);

ok(-s $out, 'it writes the snapshot where --out says');
# read_file is a list in argument position (File::Slurp), so assign it first.
my $raw  = read_file($out);
my $data = eval { JSON::PP::decode_json($raw) };
is(ref $data, 'HASH', 'the snapshot is JSON') or BAIL_OUT('no usable snapshot');

# --- counts agree with the payload ------------------------------------------
my @strings = @{ $data->{'strings'} || [] };
cmp_ok(scalar @strings, '>', 1000, 'the tree has a real number of strings (' . scalar(@strings) . ')');
is($data->{'count'}, scalar @strings, 'the declared count matches the entries');

# --- every entry is usable for translation ----------------------------------
my @empty = grep { !defined $_->{'text'} || !length $_->{'text'} } @strings;
is_deeply(\@empty, [], 'no empty string is offered for translation');

my @unsourced = grep { ref $_->{'sources'} ne 'ARRAY' || !@{ $_->{'sources'} } } @strings;
is_deeply(\@unsourced, [], 'every string says which file it came from');

my %seen;
my @dupes = grep { $seen{ $_->{'text'} }++ } @strings;
is_deeply(\@dupes, [], 'the same text is listed once, not once per use');

# --- and the sources that are files are real paths in this tree --------------
# Help topics contribute synthetic origins (help:<id>:<part>) and scripts add a
# suffix (:jquery, :attr, :dialog); only the ones that name a file are checked.
my %missing;
for my $entry (@strings) {
	for my $source ( @{ $entry->{'sources'} } ) {
		(my $path = $source) =~ s/:(?:jquery|attr|dialog)$//;
		next unless $path =~ /\.(?:ep|js)$/;
		$missing{$path}++ unless -e "$root/$path";
	}
}
is_deeply([ sort keys %missing ], [], 'every attributed source file exists in the tree');

# --- the language list is the interface catalogue ---------------------------
my @langs = @{ $data->{'languages'} || [] };
is(scalar @langs, 16, 'sixteen interface languages are listed');
is($langs[0], 'en', 'English leads it');

# --- a rerun is stable -------------------------------------------------------
{
	my $again = "$dir/again.json";
	system($^X, $script, '--out', $again);
	is($? >> 8, 0, 'a second run succeeds');
	my $second = do { my $text = read_file($again); eval { JSON::PP::decode_json($text) } };
	is_deeply([ map { $_->{'text'} } @{ $second->{'strings'} } ],
		[ map { $_->{'text'} } @strings ], 'and extracts the same strings in the same order');
}

done_testing();
