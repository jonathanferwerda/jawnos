# tests-for: t/ scripts/tests_for.pl
# covers:    the test map - every test declares what it covers, and the mapper selects it

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use Cwd qw(abs_path);

# Each t/*.t opens with a header naming the source it pins:
#
#   # tests-for: perl/subroutines.pl lib/JawnOS/Domain/*.pm
#   # covers:    name formatting and path safety
#
# scripts/tests_for.pl maps a diff to those globs, and falls back to the full
# suite for a path no test claims. This file keeps the map honest: a test with
# no header, or a glob that matches nothing, is a failure here rather than a
# silent under-test at push time.

my $root = abs_path("$FindBin::Bin/..");

sub rel {
	my $path = shift;
	$path =~ s{^\Q$root\E/+}{};
	return $path;
}

sub header_globs {
	my $file = shift;
	open(my $fh, '<', $file) or return;
	my (@globs, $seen);
	my $n = 0;
	while (my $line = <$fh>) {
		last if ++$n > 40;
		next unless $line =~ /^#\s*tests-for:\s*(.*?)\s*$/;
		$seen = 1;
		push @globs, split ' ', $1;
	}
	close $fh;
	return $seen ? \@globs : undef;
}

sub glob_to_re {
	my $glob = shift;
	$glob =~ s{^\./}{};
	my $prefix = $glob =~ s{/$}{} ? 1 : 0;
	my $re = quotemeta $glob;
	$re =~ s/\\\*\\\*/.*/g;
	$re =~ s/\\\*/[^\/]*/g;
	$re =~ s/\\\?/[^\/]/g;
	$re .= '(?:/.*)?' if $prefix;
	return qr/^$re$/;
}

sub run_tests_for {
	my @args = @_;
	open(my $fh, '-|', $^X, "$root/scripts/tests_for.pl", @args)
		or return ('', -1);
	local $/;
	my $out = <$fh>;
	close $fh;
	return (defined $out ? $out : '', $? >> 8);
}

my @tracked_tests = map { chomp; $_ } grep { /\S/ } `git -C $root ls-files t/*.t 2>/dev/null`;
my %tracked_test = map { $_ => 1 } @tracked_tests;
# a just-written file (scripts/tests_for.pl itself, early on) is not in the
# index yet, so the resolution check reads the working tree too
my @tracked = map { chomp; $_ } grep { /\S/ }
	`git -C $root ls-files --cached --others --exclude-standard 2>/dev/null`;
my %tracked = map { $_ => 1 } @tracked;

# --- every test declares its surface -----------------------------------------

my %declared;
my @tests = sort glob("$root/t/*.t");
for my $file (@tests) {
	my $test = rel($file);
	my $globs = header_globs($file);
	if (!$globs) {
		if ($tracked_test{$test}) {
			fail("$test has no `# tests-for:` header in its first 40 lines");
		}
		else {
			diag("$test is untracked and has no header yet; skipped until it is committed");
		}
		next;
	}
	ok(@$globs, "$test declares at least one glob");
	$declared{$test} = $globs;
}

# --- every glob names something real -----------------------------------------

subtest 'every glob resolves' => sub {
	plan skip_all => 'no git file list available' unless @tracked;
	for my $test (sort keys %declared) {
		for my $glob (@{ $declared{$test} }) {
			my $re = glob_to_re($glob);
			my @hit = grep { $_ =~ $re } @tracked;
			ok(@hit, "$test: `$glob` matches " . scalar(@hit) . ' tracked path(s)')
				or diag("$test: `$glob` matches nothing; fix the header");
		}
	}
};

# --- the mapper agrees -------------------------------------------------------

subtest 'the mapper selects the test that declares a path' => sub {
	my ($out, $rc) = run_tests_for('--list-for', 'lib/JawnOS/Domain/Format.pm');
	is($rc, 0, '--list-for exits 0 for a claimed path');
	like($out, qr{^t/01-names\.t\b}m, 'Format.pm selects t/01-names.t');

	($out, $rc) = run_tests_for('--list-for', 'perl/language.pl');
	is($rc, 0, '--list-for exits 0 for language.pl');
	like($out, qr{^t/10-language\.t\b}m, 'language.pl selects t/10-language.t');

	# built at runtime: a literal here would be found in this test's own body
	my $ghost = join('/', 'unmapped', 'ghost' . '.pm');
	($out, $rc) = run_tests_for('--list-for', $ghost);
	is($rc, 1, '--list-for exits 1 for an unclaimed path');
	is($out, '', 'and prints nothing');
};

subtest 'an unclaimed change fails safe' => sub {
	my $ghost = join('/', 'unmapped', 'ghost' . '.pm');
	my ($out, $rc) = run_tests_for('--files', $ghost, '--json');
	is($rc, 0, 'the default is to run, not to refuse');
	like($out, qr/"full":1/, 'the whole suite is selected');
	like($out, qr/"unmapped":\["$ghost"\]/, 'the unmapped path is named');

	($out, $rc) = run_tests_for('--files', $ghost, '--strict');
	is($rc, 2, '--strict exits 2 instead of guessing');

	($out, $rc) = run_tests_for('--files', 't/10-language.t', '--json');
	like($out, qr/"t\/10-language\.t"/, "a changed test selects itself");
	like($out, qr/"tests":\["t\/10-language\.t"\]/, 'the run list names the test file, not a bare name');
	unlike($out, qr/"full":1/, 'and that is not the full suite');
};

subtest 'every test is reachable' => sub {
	my ($out, $rc) = run_tests_for('--all', '--json');
	is($rc, 0, '--all runs');
	my @names = $out =~ /"(t\/[^"]+\.t)"/g;
	is(scalar(@names), scalar(keys %declared), '--all lists every test with a header');
	is_deeply([sort @names], [sort keys %declared], 'and they are the same set');
};

subtest 'an unclaimed app file is matched through agent_help' => sub {
	# The Gallery app's script is claimed by no header; agent_help derives the
	# app from the tree, so the change runs Gallery's tests instead of all of
	# them. The match itself is still tests_for_path's.
	#
	# The paths are built, not written: a literal in this body would claim them
	# for this test (that is the mention tier), and the case would vanish.
	my $gallery = join('/', 'public', 'js', 'images' . '.js');
	my $vendor  = join('/', 'public', 'js', 'jquery-ui' . '.js');

	my ($out, $rc) = run_tests_for('--files', $gallery, '--json');
	is($rc, 0, 'the derived tier runs');
	like($out, qr/"derived":\["\Q$gallery\E"\]/,
		'the path is reported as derived, not guessed');
	unlike($out, qr/"full":1/, 'the whole suite is not selected');

	# A file no app owns still fails safe: the derived tier narrows, never guesses.
	my ($vendor_out, $vrc) = run_tests_for('--files', $vendor, '--json');
	is($vrc, 0, 'a vendor script still runs');
	like($vendor_out, qr/"full":1/, 'and runs the full suite');
	like($vendor_out, qr/"unmapped":\["\Q$vendor\E"\]/,
		'because it belongs to no app');
};

done_testing();
