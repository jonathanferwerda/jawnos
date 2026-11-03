# tests-for: AGENTS.md docs/
# covers:    the per-request map stays a map - a hard size budget, and every
#           reference doc it points at exists, so detail can live outside the
#           context instead of riding in every request.

use strict;
use warnings;

use FindBin;
use Test::More;

my $root = "$FindBin::Bin/..";
my $map  = "$root/AGENTS.md";

ok(-f $map, 'AGENTS.md exists');

my $size = -s $map;
cmp_ok($size, '<=', 17_000, "the map stays within its budget ($size bytes)");

open my $fh, '<', $map or die "AGENTS.md: $!";
my $text = do { local $/; <$fh> };
close $fh;

my @docs = sort keys %{ { map { $_ => 1 } $text =~ m{(docs/[A-Za-z0-9_./-]+\.md)}g } };
ok(scalar @docs, 'the map points at reference docs');

my @missing = grep { !-f "$root/$_" } @docs;
is_deeply(\@missing, [], 'every referenced doc exists')
	or diag("missing: @missing");

for my $doc (qw(AGENTS-translation AGENTS-agent-work AGENTS-web AGENTS-records)) {
	like($text, qr{\Qdocs/$doc.md\E}, "$doc is referenced from the map");
}

done_testing();
