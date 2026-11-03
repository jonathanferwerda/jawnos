# tests-for: AGENTS.md docs/ lib/JawnOS/Domain/Records.pm lib/JawnOS/Controller/manager_configure5.pm scripts/records_audit.pl scripts/records_recover.pl
# covers:    the per-request map stays a map - a hard size budget, every
#           reference doc it points at exists, and the two safety rules keep
#           their command and pointer. The records rationale also sits at the
#           point of use, so an agent editing the repair path meets it without
#           the map.

use strict;
use warnings;

use FindBin;
use Test::More;

my $root = "$FindBin::Bin/..";
my $map  = "$root/AGENTS.md";

ok(-f $map, 'AGENTS.md exists');

my $size = -s $map;
cmp_ok($size, '<=', 17_000,
	"the map stays within its budget ($size bytes; move rationale to docs/AGENTS-*.md)");

open my $fh, '<', $map or die "AGENTS.md: $!";
my $text = do { local $/; <$fh> };
close $fh;

my @docs = sort keys %{ { map { $_ => 1 } $text =~ m{(docs/[A-Za-z0-9_./-]+\.md)}g } };
ok(scalar @docs, 'the map points at reference docs');

# The map names its own deep notes deliberately, and .gitignore keeps that file
# out of the repo (it carries fixtures and a login token): a fresh clone has no
# copy, so its absence is correct. t/89 skips on the same condition.
my @missing = grep { $_ ne 'docs/AGENTS-notes.md' && !-f "$root/$_" } @docs;
is_deeply(\@missing, [], 'every referenced doc exists')
	or diag("missing: @missing");
like($text, qr{The notes are \*\*gitignored[^*]*\*\*}, 'the map says the deep notes are not tracked');

for my $doc (qw(AGENTS-translation AGENTS-agent-work AGENTS-web AGENTS-records AGENTS-facts)) {
	like($text, qr{\Qdocs/$doc.md\E}, "$doc is referenced from the map");
}

# --- the two rules whose rationale moved keep their command and pointer -----
like($text, qr/Restore only\s+onto the same machine/, 'the per-device rule keeps its instruction');
like($text, qr/records_audit\.pl/, 'the appointments rule keeps its command');
like($text, qr{The incident and the exact\s+repair: `docs/AGENTS-records\.md`},
	'and names the doc that carries the rationale');

# --- the pointers sit where the work happens, not only in the map -----------
for my $file (qw(
	lib/JawnOS/Domain/Records.pm
	lib/JawnOS/Controller/manager_configure5.pm
	scripts/records_audit.pl
	scripts/records_recover.pl
)) {
	open my $src, '<', "$root/$file" or die "$file: $!";
	my $code = do { local $/; <$src> };
	close $src;
	like($code, qr{docs/AGENTS-records\.md}, "$file carries the records pointer");
}

done_testing();
