use strict;
use warnings;

use FindBin;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname);

# verify_change.pl's --manifest cache: the restart guard asks "does the whole
# tree parse" on every restart, and a full sweep is 744 compiler spawns plus a
# git show each (~90s here) sitting on the restart's critical path. The manifest
# remembers the files that passed by content hash so a later run re-checks only
# what moved. These subtests pin the safety properties that make that sound:
# unchanged files are not re-checked, a changed file still is, and a failing run
# never writes a manifest.

my $repo = tempdir(CLEANUP => 1);
my $script = "$FindBin::Bin/../scripts/verify_change.pl";
make_path("$repo/scripts");
open(my $in, '<', $script) or die "$script: $!";
open(my $script_out, '>', "$repo/scripts/verify_change.pl") or die $!;
print $script_out do { local $/; <$in> };
close $script_out;
close $in;

my $manifest = "$repo/verify.manifest";

sub git {
	my @cmd = @_;
	my $out = `cd "$repo" && @cmd 2>&1`;
	die "git @cmd: $out" if $? != 0;
	return $out;
}

&git('git init -q');
&git('git config user.email test@example.invalid');
&git('git config user.name Test');
&git('git config commit.gpgsign false');

sub write_text {
	my ($rel, $text) = @_;
	make_path(dirname("$repo/$rel"));
	open(my $fh, '>', "$repo/$rel") or die "$repo/$rel: $!";
	print $fh $text;
	close $fh;
}

write_text('alpha.pl', "use strict;\nprint \"alpha\\n\";\n1;\n");
write_text('beta.pl',  "use strict;\nprint \"beta\\n\";\n1;\n");
&git('git add -A');
&git('git commit -qm base');

sub verify {
	my $out = `cd "$repo" && perl scripts/verify_change.pl --all --quiet --manifest "$manifest" 2>&1`;
	return ($? >> 8, $out);
}

sub unchanged_count {
	my $text = shift;
	return $text =~ /(\d+) unchanged from the last verified run/ ? $1 : 0;
}

sub manifest_bytes {
	return -f $manifest ? do { open(my $fh, '<', $manifest) or return ''; local $/; <$fh> } : undef;
}

# 1. the first run judges everything and records it
my ($code, $out) = verify();
is($code, 0, 'a clean tree passes') or diag($out);
is(unchanged_count($out), 0, 'the first run re-checks every file (nothing cached yet)');
ok(-f $manifest, 'and leaves a manifest behind');
like(manifest_bytes(), qr{^# jawnos verify manifest 1$}m, 'the manifest names its version');

# 2. the second run re-checks nothing, and is a real pass (not a silent skip)
($code, $out) = verify();
is($code, 0, 'an unchanged tree still passes') or diag($out);
my ($passing) = $out =~ /(\d+) file\(s\) pass/;
is(unchanged_count($out), $passing, 'every file is served from the manifest, none re-checked');

# 3. content that moves is judged again - even to a file the cache knew
write_text('beta.pl', "use strict;\nprint \"beta\\n\";\n1;\n");
($code, $out) = verify();
is($code, 0, 'a rewritten-but-identical file is a hit, not a failure') or diag($out);
is(unchanged_count($out), $passing, 'and its bytes are what the cache keys on');

write_text('beta.pl', "use strict;\nprint \"beta changed\\n\";\n1;\n");
($code, $out) = verify();
is($code, 0, 'a valid edit passes') or diag($out);
is(unchanged_count($out), $passing - 1, 'and exactly the edited file is re-checked');

# 4. a broken edit is caught...
my $good = manifest_bytes();
write_text('beta.pl', "use strict;\nthis is not perl(;\n1;\n");
($code, $out) = verify();
isnt($code, 0, 'a broken edit is still rejected');
like($out, qr/\Qbeta.pl\E/, 'and the report names it');

# ...and the failure is never cached: the manifest is left as the last good one,
# so the next restart re-examines the file instead of trusting a stale verdict.
is(manifest_bytes(), $good, 'a failing run leaves the previous manifest untouched');

# 5. fixing it passes and refreshes the manifest
write_text('beta.pl', "use strict;\nprint \"beta fixed\\n\";\n1;\n");
($code, $out) = verify();
is($code, 0, 'the fix passes') or diag($out);
isnt(manifest_bytes(), $good, 'and the manifest records the new content');

# 6. a manifest from another format version is discarded, not trusted
my $stale = manifest_bytes();
$stale =~ s/verify manifest 1/verify manifest 0/;
open(my $fh, '>', $manifest) or die $!;
print $fh $stale;
close $fh;
($code, $out) = verify();
is($code, 0, 'a stale-version manifest still verifies the tree') or diag($out);
is(unchanged_count($out), 0, 'but is not used as evidence: everything is re-checked');

# 7. --range (pushing git blobs, not the working tree) ignores the cache
my $range_out = `cd "$repo" && perl scripts/verify_change.pl --quiet --range HEAD..HEAD --manifest "$manifest" 2>&1`;
is($? >> 8, 0, 'a --range run still behaves') or diag($range_out);
unlike($range_out, qr/unchanged from the last verified run/, 'and never consults the manifest');

done_testing();
